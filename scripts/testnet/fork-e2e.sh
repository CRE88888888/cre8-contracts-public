#!/usr/bin/env bash
# cre8-contracts#30 本機 chain 97 fork 整套驗收（不碰公開鏈）：
#   1. deploy-97.sh fork 兩次：第一次全部部署，第二次必須「No transactions to broadcast」、manifest 不變
#   2. TWAP 暖機：fork 時間往前推 30 分鐘；keeper 推一次價（PushFeedsTestnet）
#   3. SmokeTestnet：38 個資產各經 executor 用 100 USDT 買入、全部賣回，每一步過 oracle 地板
#   4. kernel-smoke：Kernel 帳戶 enroll → session key → rebalance，自有 paymaster 代付、本機 alto 打包
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

echo "== 3. 38-asset smoke through the executor =="
SK="$(cast wallet new --json | jq -r '.data[0].private_key // .[0].private_key')"
cast rpc anvil_setBalance "$(cast wallet address --private-key "$SK")" 0x8AC7230489E80000 >/dev/null
TESTNET_EXECUTOR="$(jq -r .contracts.executor deployments/testnet-97.json)" \
  forge script script/testnet/SmokeTestnet.s.sol --tc SmokeTestnet --rpc-url "$ETH_RPC_URL" --broadcast --slow \
  --private-key "$SK" | grep -E "SMOKE|ONCHAIN" | sed -E 's/^ +//'
unset SK

echo "== 4. Kernel + session key + own paymaster + alto =="
bash scripts/testnet/kernel-smoke/run-fork.sh
