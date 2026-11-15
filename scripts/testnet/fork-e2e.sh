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
cp deployments/testnet-97.json "$(mktemp -t cre8-manifest.XXXXXX)" && FIRST="$_"
echo "== 1b. deploy (rerun: must send nothing) =="
OUT="$(bash scripts/testnet/deploy-97.sh fork)"; echo "$OUT"
grep -q "No transactions to broadcast" <<<"$OUT" || { echo "rerun sent transactions: not idempotent"; exit 1; }
diff <(jq 'del(.verifiedAtBlock, .generatedAt)' "$FIRST") <(jq 'del(.verifiedAtBlock, .generatedAt)' deployments/testnet-97.json) \
  || { echo "manifest changed on rerun"; exit 1; }
echo "rerun idempotent, manifest unchanged"

echo "== 2. TWAP warm-up (+30 min) and keeper push =="
cast rpc evm_increaseTime 1800 >/dev/null && cast rpc anvil_mine 1 >/dev/null
cast rpc anvil_impersonateAccount "$KEEPER" >/dev/null
forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --unlocked --sender "$KEEPER" \
  | grep -E "push |ONCHAIN"

echo "== 3. every-asset smoke through the executor =="
# A fresh address (no key needed on the fork) runs the smoke; OPERATOR, the faucet, sends its welcome grant
# (cre8-contracts#47 removed the self-service claim). Both impersonated, so no key is on any command line.
SMOKE_EOA="$(cast wallet new --json | jq -r '.data[0].address // .[0].address')"
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
