#!/usr/bin/env bash
# 部署（或重跑）CRE8 測試網整套合約到 chain 97，並產生、核對 deployments/testnet-97.json（cre8-contracts#30）。
#
#   scripts/testnet/deploy-97.sh fork     # 本機 chain 97 fork（anvil，預設 http://127.0.0.1:8547），impersonate，不用私鑰
#   scripts/testnet/deploy-97.sh public   # 公開 chain 97：用 ~/.cre8-testnet/ 的 deployer 與 owner 金鑰（只在本機讀，不印出）
#                                         # 金鑰只放在 forge 的環境變數（TESTNET_DEPLOYER_KEY／TESTNET_OWNER_KEY），
#                                         # 不出現在任何命令列參數，`ps` 看不到；地址由 DeployTestnet 自己核對（#47）
#
# 先起 fork（要保留較長歷史的上游；data-seed 節點的歷史只有幾分鐘，部署跑到一半就 missing trie node）：
#   anvil --fork-url https://bsc-testnet.publicnode.com --chain-id 97 --port 8547 --hardfork cancun \
#     --retries 15 --fork-retry-backoff 1500 --timeout 90000
#
# 腳本是冪等的：第二次跑應該印「No transactions to broadcast」。manifest 裡每個合約地址都用 eth_getCode 核對。
#
# 地址只在「乾淨的 origin/main」上可重現：地址是 CREATE2，由 init code 決定，而 init code 含每個原始檔內容的
# hash。工作目錄有任何未 commit 的改動（包括別的 session 留在同一個 clone 的半成品），或 HEAD 不是
# origin/main，部署出來的地址都會和 deployments/testnet-97.json 不同（backend#69）。所以兩者都先擋下。
# 要部署別的版本，請另開 worktree：git worktree add <目錄> origin/main。
# 只有 fork 模式可以用 TESTNET_ALLOW_UNMERGED=1 跳過「HEAD 必須是 origin/main」（測未合併的分支用；
# 這時地址可能和 manifest 不同）；工作目錄必須乾淨這一條任何模式都不能跳過。
set -euo pipefail

MODE="${1:?usage: deploy-97.sh fork|public}"
cd "$(dirname "$0")/../.."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "refusing: not a git checkout. Addresses are only reproducible from a clean origin/main checkout."; exit 1; }
# The manifest is this script's own output (a rerun rewrites its timestamp), so it is the one file excluded.
DIRTY="$(git status --porcelain -- . ':(exclude)deployments/testnet-97.json')"
if [ -n "$DIRTY" ]; then
  echo "refusing: the working tree has uncommitted changes, which change the CREATE2 addresses:"
  echo "$DIRTY"
  echo "Addresses are only reproducible from a clean origin/main checkout (git worktree add <dir> origin/main)."
  exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  if [ "$MODE" = fork ] && [ "${TESTNET_ALLOW_UNMERGED:-0}" = 1 ]; then
    echo "warning: HEAD $(git rev-parse --short HEAD) is not origin/main; addresses may differ from $(git rev-parse --short origin/main)'s manifest"
  else
    echo "refusing: HEAD $(git rev-parse --short HEAD) is not origin/main ($(git rev-parse --short origin/main))."
    echo "Addresses are only reproducible from a clean origin/main checkout (git worktree add <dir> origin/main)."
    echo "On a fork only, TESTNET_ALLOW_UNMERGED=1 runs an unmerged branch anyway."
    exit 1
  fi
fi
KEYS="${CRE8_TESTNET_KEYS:-$HOME/.cre8-testnet}"
DEPLOYER=0x55662B4183fcA1230694D5D57F56E4F2E0e3008a
OWNER=0x09BBB9A06a0C49Ad24bddB18808944041783054e
MANIFEST=deployments/testnet-97.json
LOG="$(mktemp -t cre8-deploy-97.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

case "$MODE" in
  fork)
    export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
    cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "$ETH_RPC_URL is not an anvil fork"; exit 1; }
    for a in "$DEPLOYER" "$OWNER"; do cast rpc anvil_impersonateAccount "$a" >/dev/null; done
    # The fork inherits whatever the real DEPLOYER holds; give it enough for a full run (fork-only tBNB).
    DEPLOYER_BALANCE="$(cast balance "$DEPLOYER")"
    # Wei balances can exceed Bash's signed 64-bit range (e.g. the 10 tBNB fork grant).
    if ! python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= 2 * 10**18 else 1)' "$DEPLOYER_BALANCE"; then
      cast rpc anvil_setBalance "$DEPLOYER" 0x8AC7230489E80000 >/dev/null # 10 tBNB, fork only
    fi
    unset TESTNET_DEPLOYER_KEY TESTNET_OWNER_KEY
    SIGNERS=(--unlocked --sender "$DEPLOYER")
    KEY_ENV=()
    ;;
  public)
    export ETH_RPC_URL="${BSC_TESTNET_RPC_URL:-https://data-seed-prebsc-1-s1.bnbchain.org:8545}"
    if cast rpc anvil_nodeInfo >/dev/null 2>&1; then echo "$ETH_RPC_URL is an anvil node, use: fork"; exit 1; fi
    # Keys go to forge through its environment only (`env` puts them there, not on forge's command line);
    # DeployTestnet loads them with vm.rememberKey and stops unless they derive DEPLOYER and OWNER.
    KEY_ENV=(
      "TESTNET_DEPLOYER_KEY=$(jq -r '.data[0].private_key' "$KEYS/deployer.json")"
      "TESTNET_OWNER_KEY=$(jq -r '.data[0].private_key' "$KEYS/owner.json")"
    )
    SIGNERS=(--sender "$DEPLOYER")
    ;;
  *) echo "usage: deploy-97.sh fork|public"; exit 1 ;;
esac
[ "$(cast chain-id)" = "97" ] || { echo "$ETH_RPC_URL is not chain 97"; exit 1; }

# Deploy the stateless library once at a CREATE2 address, then pin that address when linking.
# Foundry's default nonce-based library deployment would otherwise change addresses on every rerun.
env -u DAPP_LIBRARIES ${KEY_ENV[@]+"${KEY_ENV[@]}"} forge script script/testnet/DeployYieldView.s.sol --rpc-url "$ETH_RPC_URL" \
  --broadcast --slow --gas-estimate-multiplier 300 "${SIGNERS[@]}" >"$LOG" 2>&1 \
  || { tail -40 "$LOG"; exit 1; }
YIELD_VIEW="$(awk '/^[[:space:]]*YIELD_VIEW / {print $2}' "$LOG")"
[ -n "$YIELD_VIEW" ] || { echo "missing yield view address"; exit 1; }
LIBRARY_TRANSACTIONS=0
LIBRARY_GAS=0
if ! grep -q "No transactions to broadcast" "$LOG"; then
  read -r LIBRARY_TRANSACTIONS LIBRARY_GAS < <(python3 -c 'import json; r=json.load(open("broadcast/DeployYieldView.s.sol/97/run-latest.json"))["receipts"]; assert all(int(x["status"],16)==1 for x in r); print(len(r),sum(int(x["gasUsed"],16) for x in r))')
fi
echo "DEPLOY_RECEIPTS library: $LIBRARY_TRANSACTIONS transactions, $LIBRARY_GAS gas ($YIELD_VIEW)"
export DAPP_LIBRARIES="src/atp/yield/YieldView.sol:YieldView:$YIELD_VIEW"

# Pools whose observationCardinality is still 1. The TWAP adapter needs >= 2, which only an observation written
# in a later second than the pool's initialization provides; when the first mints land in that same second the
# script's small "poke" mint has to run again one block later. forge's simulation cannot see this (it runs every
# transaction at one timestamp), so it is checked here on chain and fixed by rerunning.
thin_pools() {
  grep -E "^\s*MANIFEST asset\.[A-Za-z]+\.pool " "$LOG" | while read -r _ key pool; do
    c="$(cast call "$pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint32,bool)' --json | jq -r 'if type == "object" then .data[3] else .[3] end')"
    [ "${c:-0}" -ge 2 ] || echo "${key#asset.}"
  done
}

# A run deploys at most TESTNET_MARKETS_PER_RUN (default 40) unfinished markets and prints PENDING_MARKETS <n>
# while some are left (cre8-contracts#39: forge simulates a run as one call, which ran out of gas after ~56 of
# 134 markets in an earlier draft), so the script is rerun until nothing is pending; each rerun must leave fewer
# pending. Then up to 3 more runs poke thin pools and hand DEPLOYER's tokens, feeds and LP NFTs to OWNER
# (cre8-contracts#47): DeployTestnet only hands over in a run that minted into no pool and prints PENDING_HANDOVER
# otherwise, so a thin pool is always poked before DEPLOYER gives up its mint.
run=0
thin_runs=0
last_pending=""
last_phase=""
total_transactions="$LIBRARY_TRANSACTIONS"
total_gas="$LIBRARY_GAS"
while :; do
  run=$((run + 1))
  echo "== DeployTestnet ($MODE, $ETH_RPC_URL) run $run =="
  # `env` with an empty KEY_ENV (fork mode) adds nothing.
  # Simulation shares one timestamp; mining can enter an interest-mint branch absent in the estimate.
  # Keep the transaction budget generous without discounting any protocol minimum or actual gasUsed.
  env ${KEY_ENV[@]+"${KEY_ENV[@]}"} forge script script/DeployTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --slow --gas-estimate-multiplier 300 "${SIGNERS[@]}" >"$LOG" 2>&1 \
    || { tail -80 "$LOG"; echo "deploy failed (last 80 lines of the forge log above; the log is removed on exit)"; exit 1; }
  grep -E "NEW|TOPUP|No transactions to broadcast|ONCHAIN EXECUTION|Paid:|PENDING_MARKETS|PENDING_YIELD_MARKETS|PENDING_HANDOVER" "$LOG" | grep -vE "^\s*(pool|deploy) +NEW" || true
  if ! grep -q "No transactions to broadcast" "$LOG"; then
    read -r RUN_TX RUN_GAS < <(python3 -c 'import json; r=json.load(open("broadcast/DeployTestnet.s.sol/97/run-latest.json"))["receipts"]; print(len(r),sum(int(x["gasUsed"],16) for x in r))')
    total_transactions=$((total_transactions + RUN_TX))
    total_gas=$((total_gas + RUN_GAS))
    echo "DEPLOY_RECEIPTS run $run: $RUN_TX transactions, $RUN_GAS gas"
  fi
  echo "new contracts and pools this run: $(grep -cE "^\s*(pool|deploy) +NEW" "$LOG" || true)"
  # No PENDING_MARKETS line on the last run: grep exits 1, which pipefail + set -e must not turn into an abort.
  PENDING="$(grep -E "^\s*PENDING_(YIELD_)?MARKETS " "$LOG" | awk '{print $2}' | tail -1 || true)"
  PHASE="$(grep -E "^\s*PENDING_(YIELD_)?MARKETS " "$LOG" | awk '{print $1}' | tail -1 || true)"
  if [ -n "$PENDING" ]; then
    if [ "$PHASE" = "$last_phase" ] && [ -n "$last_pending" ] && [ "$PENDING" -ge "$last_pending" ]; then
      echo "no progress: still $PENDING markets pending after run $run"; exit 1
    fi
    last_pending="$PENDING"
    last_phase="$PHASE"
    echo "$PENDING markets pending -> next run"
    [ "$MODE" = fork ] && cast rpc anvil_mine 1 >/dev/null
    continue
  fi
  last_pending=""
  if grep -qE "^\s*PENDING_HANDOVER" "$LOG"; then
    # This run created or poked a pool; the next one (a few seconds later, so a poke lands in a new second)
    # either pokes a pool still thin on chain or, with nothing left to mint, hands over and verifies.
    thin_runs=$((thin_runs + 1))
    [ "$thin_runs" -gt 3 ] && { echo "pools still need a mint after 3 hand-over attempts"; exit 1; }
    echo "pools minted this run -> hand-over on the next run (attempt $thin_runs of 3)"
    sleep 4
    [ "$MODE" = fork ] && cast rpc anvil_mine 1 >/dev/null
    continue
  fi
  # The hand-over run read every pool from chain and minted nothing, so none can be thin; checked anyway,
  # since DEPLOYER can no longer poke one.
  THIN="$(thin_pools | tr '\n' ' ')"
  [ -z "$THIN" ] || { echo "observationCardinality < 2 after the hand-over: $THIN"; exit 1; }
  break
done
unset KEY_ENV SIGNERS
echo "DEPLOY_TOTAL: $total_transactions transactions, $total_gas gas"

echo "== manifest + eth_getCode =="
BLOCK="$(cast block-number)"
python3 - "$LOG" "$MANIFEST" "$MODE" "$BLOCK" "$(git rev-parse HEAD)" "$ETH_RPC_URL" <<'EOF'
import json, subprocess, sys, datetime
log, path, mode, block, commit, rpc = sys.argv[1:]
entries = [l.split()[1:3] for l in open(log) if l.strip().startswith("MANIFEST ")]
if not entries:
    sys.exit("no MANIFEST lines in the deploy log")
roles, contracts, assets, bad = {}, {}, {}, []
yield_markets = []
for line in open(log):
    if not line.strip().startswith("YIELD_MARKET "): continue
    _, ident, protocol, symbol, apr, target, receipt, asset, seed = line.split()
    for addr in (target, receipt):
        code = subprocess.run(["cast", "code", addr, "--rpc-url", rpc], capture_output=True, text=True).stdout.strip()
        if code in ("", "0x"): bad.append(f"yield {ident} {addr}")
    yield_markets.append({"marketId": ident, "protocol": protocol, "symbol": symbol, "aprBps": int(apr),
        "target": target, "receipt": receipt, "asset": asset, "backgroundSupplyAssets": seed,
        "rateLabel": "模擬利率", "rateType": "fixed_simulated_APR", "ownerAdjustable": True})
if len(yield_markets) != 30 or len({m["marketId"] for m in yield_markets}) != 30:
    sys.exit("yield manifest must contain the 30 distinct rows in C3's final table")
for key, addr in entries:
    if key.startswith("role."):
        roles[key[5:]] = addr
        continue
    code = subprocess.run(["cast", "code", addr, "--rpc-url", rpc], capture_output=True, text=True).stdout.strip()
    if code in ("", "0x"):
        bad.append(f"{key} {addr}")
    if key.startswith("asset."):
        _, sym, field = key.split(".", 2)
        assets.setdefault(sym, {})[field] = addr
    else:
        contracts[key] = addr
if bad:
    sys.exit("no code at:\n  " + "\n  ".join(bad))
manifest = {
    "chainId": 97,
    "mode": mode,
    "note": "fork = verified on a local anvil fork of chain 97; the public deployment lands on the same CREATE2 addresses"
    if mode == "fork" else "deployed on public BSC testnet (chain 97)",
    "verifiedAtBlock": int(block),
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "gitCommit": commit,
    "versioning": {
        "enrollAbi": "enroll(address,uint256,uint16)",
        "publicationDelaySeconds": 86400,
        "publicationIntervalSeconds": 604800,
        "consent": "account sudo enroll, or account approveEnrollment(uint256,uint16) then operator first enroll",
        "settingsAbi": "publishSettingsVersion(uint256,address[],uint16[],bytes32,bytes32,uint16,uint64)",
        "performanceFeeBpsRange": [500, 2000],
    },
    "roles": roles,
    "contracts": contracts,
    "assets": assets,
    "yieldMarkets": yield_markets,
    "yieldMarketCountNote": "C3 table heading says 32, but has 30 rows (21 Venus, 4 Lista, 5 Aave); no unspecified markets added",
}
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"{len(entries) - len(roles)} addresses have code; wrote {path}")
EOF
