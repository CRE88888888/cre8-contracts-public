#!/usr/bin/env bash
# cre8-contracts#30：在本機 chain 97 fork 上起 alto（bundler），跑 kernel-smoke.ts，結束後關掉 alto。
#
# 前置：fork 已跑過 scripts/testnet/deploy-97.sh fork、TWAP 暖機 30 分鐘、keeper 推過價（見 docs/testnet-97.zh-TW.md）。
# alto 用 @pimlico/alto@0.0.18（與 A3 同版本，理由見 docs A3_INTEGRATION §1）；ALTO_DIR 指向裝好它的目錄：
#   mkdir -p "$ALTO_DIR" && cd "$ALTO_DIR" && npm init -y && npm i @pimlico/alto@0.0.18 --ignore-scripts
# 執行者金鑰與 utility 金鑰取自 ~/.cre8-testnet（bundler-executor／bundler-utility），只傳給本機 alto，不印出。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FORK_RPC="${FORK_RPC:-http://127.0.0.1:8547}"
ALTO_PORT="${ALTO_PORT:-3047}"
ALTO_DIR="${ALTO_DIR:?ALTO_DIR = directory with @pimlico/alto@0.0.18 installed}"
KEYS="${CRE8_TESTNET_KEYS:-$HOME/.cre8-testnet}"
LOG="${ALTO_LOG:-$(mktemp -t cre8-alto-97.XXXXXX)}"

cast rpc anvil_nodeInfo --rpc-url "$FORK_RPC" >/dev/null 2>&1 || { echo "$FORK_RPC is not an anvil fork"; exit 1; }
[ "$(cast chain-id --rpc-url "$FORK_RPC")" = "97" ] || { echo "fork is not chain 97"; exit 1; }
# alto finds receipts with eth_getLogs over the last 100 blocks; keep that range local to the fork.
cast rpc anvil_mine 120 --rpc-url "$FORK_RPC" >/dev/null

EK="$(jq -r '.data[0].private_key' "$KEYS/bundler-executor.json")"
UK="$(jq -r '.data[0].private_key' "$KEYS/bundler-utility.json")"
node "$ALTO_DIR/node_modules/@pimlico/alto/esm/cli/alto.js" \
  --rpc-url "$FORK_RPC" --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  --executor-private-keys "$EK" --utility-private-key "$UK" \
  --port "$ALTO_PORT" --deploy-simulations-contract --timeout 120000 \
  --min-entity-stake 1 --min-entity-unstake-delay 1 --min-executor-balance 10000000000000000 \
  --max-block-range 100 --safe-mode true >"$LOG" 2>&1 &
ALTO_PID=$!
unset EK UK
trap 'kill "$ALTO_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -s -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_supportedEntryPoints","params":[]}' \
    "http://127.0.0.1:$ALTO_PORT" | grep -q result && break
  kill -0 "$ALTO_PID" 2>/dev/null || { echo "alto exited, log: $LOG"; tail -20 "$LOG"; exit 1; }
  sleep 2
done
echo "alto ready on $ALTO_PORT (log $LOG)"

cd "$HERE"
[ -d node_modules ] || bun install --frozen-lockfile
FORK_RPC="$FORK_RPC" BUNDLER_URL="http://127.0.0.1:$ALTO_PORT" bun run kernel-smoke.ts
