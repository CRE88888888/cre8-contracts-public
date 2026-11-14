#!/usr/bin/env bash
# 部署（或重跑）CRE8 測試網整套合約到 chain 97，並產生、核對 deployments/testnet-97.json（cre8-contracts#30）。
#
#   scripts/testnet/deploy-97.sh fork     # 本機 chain 97 fork（anvil，預設 http://127.0.0.1:8547），impersonate，不用私鑰
#   scripts/testnet/deploy-97.sh public   # 公開 chain 97：用 ~/.cre8-testnet/ 的 deployer 與 owner 金鑰（只在本機讀，不印出）
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

case "$MODE" in
  fork)
    export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
    cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "$ETH_RPC_URL is not an anvil fork"; exit 1; }
    for a in "$DEPLOYER" "$OWNER"; do cast rpc anvil_impersonateAccount "$a" >/dev/null; done
    # The fork inherits whatever the real DEPLOYER holds; give it enough for a full run (fork-only tBNB).
    [ "$(cast balance "$DEPLOYER")" -ge 2000000000000000000 ] || cast rpc anvil_setBalance "$DEPLOYER" 0x8AC7230489E80000 >/dev/null # 10 tBNB
    SIGNERS=(--unlocked --sender "$DEPLOYER")
    ;;
  public)
    export ETH_RPC_URL="${BSC_TESTNET_RPC_URL:-https://data-seed-prebsc-1-s1.bnbchain.org:8545}"
    if cast rpc anvil_nodeInfo >/dev/null 2>&1; then echo "$ETH_RPC_URL is an anvil node, use: fork"; exit 1; fi
    DK="$(jq -r '.data[0].private_key' "$KEYS/deployer.json")"
    OK="$(jq -r '.data[0].private_key' "$KEYS/owner.json")"
    [ "$(cast wallet address --private-key "$DK")" = "$DEPLOYER" ] || { echo "deployer key mismatch"; exit 1; }
    [ "$(cast wallet address --private-key "$OK")" = "$OWNER" ] || { echo "owner key mismatch"; exit 1; }
    SIGNERS=(--private-keys "$DK" --private-keys "$OK" --sender "$DEPLOYER")
    ;;
  *) echo "usage: deploy-97.sh fork|public"; exit 1 ;;
esac
[ "$(cast chain-id)" = "97" ] || { echo "$ETH_RPC_URL is not chain 97"; exit 1; }

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

for attempt in 1 2 3; do
  echo "== DeployTestnet ($MODE, $ETH_RPC_URL) run $attempt =="
  forge script script/DeployTestnet.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --slow "${SIGNERS[@]}" >"$LOG" 2>&1 \
    || { tail -40 "$LOG"; echo "deploy failed, full log: $LOG"; exit 1; }
  grep -E "NEW|TOPUP|No transactions to broadcast|ONCHAIN EXECUTION" "$LOG" || true
  THIN="$(thin_pools | tr '\n' ' ')"
  [ -z "$THIN" ] && break
  echo "observationCardinality < 2: $THIN-> rerun after a few seconds"
  [ "$attempt" = 3 ] && { echo "still thin after 3 runs"; exit 1; }
  sleep 4
  [ "$MODE" = fork ] && cast rpc anvil_mine 1 >/dev/null
done
unset DK OK SIGNERS

echo "== manifest + eth_getCode =="
BLOCK="$(cast block-number)"
python3 - "$LOG" "$MANIFEST" "$MODE" "$BLOCK" "$(git rev-parse HEAD)" "$ETH_RPC_URL" <<'EOF'
import json, subprocess, sys, datetime
log, path, mode, block, commit, rpc = sys.argv[1:]
entries = [l.split()[1:3] for l in open(log) if l.strip().startswith("MANIFEST ")]
if not entries:
    sys.exit("no MANIFEST lines in the deploy log")
roles, contracts, assets, bad = {}, {}, {}, []
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
    "roles": roles,
    "contracts": contracts,
    "assets": assets,
}
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"{len(entries) - len(roles)} addresses have code; wrote {path}")
EOF
