#!/usr/bin/env bash
# cre8-contracts#30 本機 chain 97 fork 整套驗收（不碰公開鏈）：
#   1. deploy-97.sh fork 兩次：第一次全部部署，第二次必須「No transactions to broadcast」、manifest 不變
#   2. TWAP 暖機：fork 時間往前推 30 分鐘；keeper 推一次價（PushFeedsTestnet）
#   3. SmokeTestnet：一個版本含 USDT＋全部資產（#39 起 92 個，#45 起不設上限），一個帳戶（#47 起由 operator
#      發迎新 10,000 USDT）經 executor 每個資產用
#      100 USDT 買入、全部賣回、領出 USDT；每批最多 16 步，每一步過 oracle 地板；印出發版本、每批、領出的 gas
#   4. PokePoolsTestnet 兩輪（#39）：keeper 每個池子一筆會動 tick 的 swap；第一輪備庫存與 approve，
#      第二輪在一小時後，是每小時的穩定成本（印出總 gas）
#   5. kernel-smoke：Kernel 帳戶 enroll → session key → rebalance，自有 paymaster 代付、本機 alto 打包
#
# 先起一個全新的 fork（見 deploy-97.sh 開頭），並設 ALTO_DIR（見 kernel-smoke/run-fork.sh）。
set -euo pipefail
cd "$(dirname "$0")/../.."
export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "$ETH_RPC_URL is not an anvil fork"; exit 1; }
KEEPER=0xa38dDFB9FDF0043Cf61B00E1a8d12FA1431f92d5

echo "== 1a. deploy (first run) =="
bash scripts/testnet/deploy-97.sh fork
# Link settings are part of every artifact's metadata, including the tokens/feeds that the keeper and
# smoke scripts locate through TestnetBook. Use the exact deployment settings for every later script.
export DAPP_LIBRARIES="src/atp/yield/YieldView.sol:YieldView:$(jq -er '.contracts.yieldView' deployments/testnet-97.json)"
cp deployments/testnet-97.json "$(mktemp -t cre8-manifest.XXXXXX)" && FIRST="$_"
echo "== 1b. deploy reruns: exact 2 tBNB and >signed-int64 balance must remain unchanged =="
RERUN_DEPLOYER="$(jq -r .roles.deployer deployments/testnet-97.json)"
for RERUN_BALANCE in 0x1bc16d674ec80000 0x98a7d9b8314c0000; do # 2 and 11 tBNB, local only
  cast rpc anvil_setBalance "$RERUN_DEPLOYER" "$RERUN_BALANCE" >/dev/null
  RERUN_BEFORE="$(cast balance "$RERUN_DEPLOYER")"
  OUT="$(bash scripts/testnet/deploy-97.sh fork)"; echo "$OUT"
  grep -q "No transactions to broadcast" <<<"$OUT" || { echo "rerun sent transactions: not idempotent"; exit 1; }
  [ "$(cast balance "$RERUN_DEPLOYER")" = "$RERUN_BEFORE" ] || { echo "rerun changed deployer balance"; exit 1; }
  diff <(jq 'del(.verifiedAtBlock, .generatedAt)' "$FIRST") <(jq 'del(.verifiedAtBlock, .generatedAt)' deployments/testnet-97.json) \
    || { echo "manifest changed on rerun"; exit 1; }
  echo "rerun idempotent, manifest and deployer balance unchanged ($RERUN_BEFORE wei)"
done

echo "== P11. prepare both smoke strategies, then observe the full notice period =="
# Version-only migration of the deployment acceptance caller: no oracle checks are weakened.
# Publish at the previous day's timestamp and return to the original price snapshot before warming TWAP.
VERSION_EOA="$(cast rpc eth_accounts | jq -r '.[8]')"
cast rpc anvil_impersonateAccount "$VERSION_EOA" >/dev/null
cast rpc anvil_setBalance "$VERSION_EOA" 0x8AC7230489E80000 >/dev/null
VERSION_NOW="$(cast block latest -f timestamp)"
cast rpc anvil_setBlockTimestampInterval 0 >/dev/null
trap 'cast rpc anvil_setTime $(( VERSION_NOW * 1000 )) >/dev/null; cast rpc anvil_mine 1 >/dev/null; cast rpc anvil_removeBlockTimestampInterval >/dev/null' EXIT
cast rpc anvil_setTime $(( (VERSION_NOW - 86400) * 1000 )) >/dev/null
cast rpc anvil_mine 1 >/dev/null
VERSION_LOG="$(mktemp -t cre8-version-smoke.XXXXXX)"
TESTNET_EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)" TESTNET_SMOKE_PREPARE=true \
  forge script script/testnet/SmokeTestnet.s.sol --tc SmokeTestnet --rpc-url "$ETH_RPC_URL" --broadcast --slow \
  --unlocked --sender "$VERSION_EOA" >"$VERSION_LOG" 2>&1 || { tail -60 "$VERSION_LOG"; exit 1; }
export TESTNET_SMOKE_STRATEGY_ID="$(awk '/SMOKE_PENDING strategy/ {print $NF}' "$VERSION_LOG")"
TESTNET_EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)" \
  YIELD_SMOKE_OWNER="$VERSION_EOA" TESTNET_YIELD_PHASE=prepare \
  forge script script/testnet/SmokeYieldTestnet.s.sol --tc SmokeYieldTestnet --rpc-url "$ETH_RPC_URL" --broadcast --slow \
  --unlocked --sender "$VERSION_EOA" >"$VERSION_LOG" 2>&1 || { tail -60 "$VERSION_LOG"; exit 1; }
export TESTNET_YIELD_STRATEGY_ID="$(awk '/YIELD_PENDING strategy/ {print $NF}' "$VERSION_LOG")"
rm -f "$VERSION_LOG"
[ -n "$TESTNET_SMOKE_STRATEGY_ID" ] && [ -n "$TESTNET_YIELD_STRATEGY_ID" ] || { echo "missing prepared strategy ids"; exit 1; }
cast rpc anvil_setTime $(( VERSION_NOW * 1000 )) >/dev/null
cast rpc anvil_mine 1 >/dev/null
cast rpc anvil_removeBlockTimestampInterval >/dev/null
trap - EXIT
for version_id in "$TESTNET_SMOKE_STRATEGY_ID" "$TESTNET_YIELD_STRATEGY_ID"; do
  [ "$(cast call "$(jq -r .contracts.registry deployments/testnet-97.json)" 'activeVersion(uint256)(uint16)' "$version_id")" = "1" ] \
    || { echo "prepared version did not become active after 24h"; exit 1; }
done

echo "== 2. TWAP warm-up (+30 min) and keeper push =="
cast rpc evm_increaseTime 1800 >/dev/null && cast rpc anvil_mine 1 >/dev/null
cast rpc anvil_impersonateAccount "$KEEPER" >/dev/null
forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --unlocked --sender "$KEEPER" \
  | grep -E "push |ONCHAIN"

echo "== 3. every-asset smoke through the executor =="
# A fresh address (no key needed on the fork) runs the smoke; OPERATOR, the faucet, sends its welcome grant
# (cre8-contracts#47 removed the self-service claim). Both impersonated, so no key is on any command line.
SMOKE_EOA="$(cast rpc eth_accounts | jq -r '.[8]')"
OPERATOR="$(jq -r .roles.operator deployments/testnet-97.json)"
cast rpc anvil_setBalance "$SMOKE_EOA" 0x8AC7230489E80000 >/dev/null
for a in "$SMOKE_EOA" "$OPERATOR"; do cast rpc anvil_impersonateAccount "$a" >/dev/null; done
SMOKE_LOG="$(mktemp -t cre8-smoke.XXXXXX)"
TESTNET_EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)" \
  forge script script/testnet/SmokeTestnet.s.sol --tc SmokeTestnet --rpc-url "$ETH_RPC_URL" --broadcast --slow \
  --unlocked --sender "$SMOKE_EOA" | grep -E "SMOKE|ONCHAIN" | sed -E 's/^ +//' | tee "$SMOKE_LOG"
# Gas of the publish, every batch and the exit (#45), from the receipts of the transactions SmokeTestnet labelled.
python3 -I -c '
import json, sys
run = json.load(open(sys.argv[2]))
gas = {r["transactionHash"]: int(r["gasUsed"], 16) for r in run["receipts"]}
for line in open(sys.argv[1]):
    if line.startswith("SMOKE_TX "):
        _, label, idx = line.split()
        tx = run["transactions"][int(idx)]
        print("SMOKE gas", label + ":", gas[tx["hash"]])
' "$SMOKE_LOG" broadcast/SmokeTestnet.s.sol/97/run-latest.json
rm -f "$SMOKE_LOG"

echo "== yield. every configured market: supply -> interest -> partial risk exit -> retry =="
YIELD_OWNER="$(cast rpc eth_accounts | jq -r '.[8]')"
for phase in supply exit; do
  if [ "$phase" = exit ]; then
    cast rpc evm_increaseTime 31536000 >/dev/null
    cast rpc anvil_mine 1 >/dev/null
  fi
  YIELD_LOG="$(mktemp -t cre8-yield-smoke.XXXXXX)"
  TESTNET_EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)" \
    YIELD_SMOKE_OWNER="$YIELD_OWNER" TESTNET_YIELD_PHASE="$phase" \
    forge script script/testnet/SmokeYieldTestnet.s.sol --tc SmokeYieldTestnet --rpc-url "$ETH_RPC_URL" --broadcast --slow --gas-estimate-multiplier 200 \
    --unlocked --sender "$YIELD_OWNER" >"$YIELD_LOG" 2>&1 \
    || { tail -80 "$YIELD_LOG"; exit 1; }
  grep -E "YIELD_SMOKE|ONCHAIN" "$YIELD_LOG"
  python3 - "$YIELD_LOG" broadcast/SmokeYieldTestnet.s.sol/97/run-latest.json <<'EOF'
import json,sys,subprocess,os
run=json.load(open(sys.argv[2]))
gas={r["transactionHash"]:int(r["gasUsed"],16) for r in run["receipts"]}
for line in open(sys.argv[1]):
    if line.strip().startswith("YIELD_TX "):
        _,label,idx=line.split()
        print("YIELD gas",label,gas[run["transactions"][int(idx)]["hash"]])
assert all(int(r["status"],16)==1 for r in run["receipts"]), "failed yield receipt"
supply_topic="0xd30f59afff55471427c4668bbd5cab9e0666f49965c49db492ca2b39c92ad9ca"
withdraw_topic="0xbfb66e5add46d6a90eeafcf65c2843606d53425b80e9b29a0e6cc59c472703b2"
events={}
for r in run["receipts"]:
    for e in r["logs"]:
        if not e["topics"] or e["topics"][0].lower() not in (supply_topic,withdraw_topic): continue
        ident=e["topics"][2].lower()
        values=[int(e["data"][2+i*64:2+(i+1)*64],16) for i in range(3)]
        assert all(v>0 for v in values[:2]), "zero yield business output"
        events.setdefault(ident,[]).append((e["topics"][0].lower(),"0x"+e["topics"][1][-40:],values))
assert len(events)==30, "missing market business receipts"
manifest=json.load(open("deployments/testnet-97.json"))
markets={m["marketId"].lower():m for m in manifest["yieldMarkets"]}
assert set(events)==set(markets), "business receipt market mismatch"
for ident,ev in events.items():
    if ev[0][0]==supply_topic:
        assert len(ev)==1 and ev[0][2][2]>0, "supply receipt absent"
    else:
        assert len(ev)==2 and ev[0][2][2]>0 and ev[1][2][2]==0, "partial/retry receipt mismatch"
        account=ev[1][1]
        for target,signature,args in (
            (markets[ident]["receipt"],"balanceOf(address)(uint256)",[account]),
            (manifest["contracts"]["yieldRegistry"],"totalUnits(bytes32)(uint256)",[ident]),
            (manifest["contracts"]["yieldRegistry"],"exiting(address,bytes32)(bool)",[account,ident]),
        ):
            out=subprocess.check_output(["cast","call",target,signature,*args,"--rpc-url",os.environ["ETH_RPC_URL"]],text=True).strip().split()[0]
            assert out in ("0","false"), "actual onchain exit state remains"
print("YIELD actual business receipts verified",len(events))
print("YIELD phase",len(run["receipts"]),"transactions",sum(gas.values()),"gas")
EOF
  rm -f "$YIELD_LOG"
done

echo "== 4. keeper poke: one tick-moving swap per pool (round 1 stocks inventory, round 2 = hourly steady state) =="
EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)"
for round in 1 2; do
  # Round 2 an hour later, as the keeper would: every swap then also writes a new pool observation.
  [ "$round" = 2 ] && cast rpc evm_increaseTime 3600 >/dev/null && cast rpc anvil_mine 1 >/dev/null
  echo "-- round $round"
  TESTNET_EXECUTOR="$EXECUTOR" forge script script/testnet/PokePoolsTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast \
    --unlocked --sender "$KEEPER" | grep -E "POKE|ONCHAIN" | sed -E 's/^ +//'
  # Receipt gasUsed is a hex string ("0xd043"), which jq's tonumber cannot parse.
  python3 -I -c 'import json, sys; r = json.load(open(sys.argv[2]))["receipts"]; print(f"POKE round {sys.argv[1]}: {len(r)} transactions, {sum(int(x["gasUsed"], 16) for x in r)} gas")' \
    "$round" broadcast/PokePoolsTestnet.s.sol/97/run-latest.json
done
# The hour skipped for round 2 left the 1-hour mock feeds stale: push them again for the Kernel run.
forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --unlocked --sender "$KEEPER" \
  | grep -E "ONCHAIN"

echo "== 5. Kernel + session key + own paymaster + alto =="
bash scripts/testnet/kernel-smoke/run-fork.sh
