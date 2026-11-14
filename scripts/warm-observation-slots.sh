#!/usr/bin/env bash
# fork 專用的快取預熱（cre8-contracts#25）：讓 IncreaseObservationCardinality 在 anvil fork 上幾分鐘內跑完。
#
# 為什麼要：那支腳本要替池子預先配置約一萬五千個 observation slot。fork 上每寫一個新 slot，anvil 都要先向上游
# RPC 讀一次原值；能在 anvil 上正常出交易 receipt 的 RPC（Blast）每次讀約 1 秒，整步要四小時以上。
#
# 做法：從 AtpMainnetSpecs 讀出 38 個池子，找出 observationCardinalityNext < 2400 的池子會被寫到的 slot
# （PancakeV3Pool 的 observations 陣列從 storage slot 9 開始，每筆一個 slot；先對每個池子用最新一筆 observation
# 驗證這個位置，不符就停），用回應快的 RPC（預設 publicnode）以 batch 讀出它們在 fork 區塊的**真實值**，
# 再用 anvil_setStorageAt 寫進 anvil。寫進去的值就是 anvil 自己去讀會拿到的值，只是先讀好；之後腳本照常執行。
# 只能對 anvil 用（會先檢查 anvil_nodeInfo）。
#   FORK_RPC=http://127.0.0.1:8547 READ_RPC=https://bsc-rpc.publicnode.com scripts/warm-observation-slots.sh
set -euo pipefail

export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
READ_RPC="${READ_RPC:-https://bsc-rpc.publicnode.com}"
cd "$(dirname "$0")/.."

INFO=$(cast rpc anvil_nodeInfo 2>/dev/null) || { echo "$ETH_RPC_URL is not an anvil fork"; exit 1; }
[ "$(cast chain-id)" = "56" ] || { echo "fork at $ETH_RPC_URL is not chain 56"; exit 1; }
FORK_BLOCK=$(jq -r '.forkConfig.forkBlockNumber' <<<"$INFO")
[ "$FORK_BLOCK" != "null" ] || { echo "anvil is not forking"; exit 1; }
BLOCK_HEX=$(printf '0x%x' "$FORK_BLOCK")
TARGET=$(grep -o 'MIN_OBSERVATION_CARDINALITY = [0-9_]*' script/AtpMainnetSpecs.sol | grep -o '[0-9_]*$' | tr -d _)
OBS_BASE=9

# 每個 OracleSpec(...) 的第三個欄位是池子地址
POOLS=$(awk '/= OracleSpec\(/{n=0; f=1; next} f && /0x[0-9a-fA-F]{40}/{n++; if(n==2){gsub(/[ ,]/,""); print; f=0}}' script/AtpMainnetSpecs.sol)
[ "$(wc -l <<<"$POOLS" | tr -d ' ')" = "38" ] || { echo "expected 38 pools in AtpMainnetSpecs"; exit 1; }

rpc_batch() { # $1 = url, stdin = JSON array of requests; stdout = results ordered by id
  local body out try
  body=$(cat)
  for try in $(seq 1 30); do
    # 上游限流（429）時等一下再送同一批；body 存在變數裡，重送的內容不變
    if out=$(curl -sS --fail-with-body -H 'content-type: application/json' -d "$body" "$1" 2>&1); then
      jq -c 'if type == "array" then sort_by(.id) else error("batch not supported: \(.)") end' <<<"$out"
      return
    fi
    sleep 3
  done
  echo "rpc batch to $1 failed 30 times: $(head -c 300 <<<"$out")" >&2
  return 1
}

TOTAL=0
for P in $POOLS; do
  S0=$(cast call "$P" 'slot0()(uint160,int24,uint16,uint16,uint16,uint32,bool)')
  IDX=$(sed -n 3p <<<"$S0" | awk '{print $1}'); NEXT=$(sed -n 5p <<<"$S0" | awk '{print $1}')
  [ "$NEXT" -lt "$TARGET" ] || continue
  # layout 檢查：slot OBS_BASE+IDX 的低 32 位元就是最新一筆 observation 的時間
  TS=$(cast call "$P" 'observations(uint256)(uint32,int56,uint160,bool)' "$IDX" | head -1 | awk '{print $1}')
  RAW=$(cast storage "$P" $(( OBS_BASE + IDX )))
  [ "$(( 16#${RAW: -8} ))" = "$TS" ] || { echo "observations layout mismatch on $P"; exit 1; }
  for (( start = NEXT; start < TARGET; start += 50 )); do
    end=$(( start + 50 < TARGET ? start + 50 : TARGET ))
    # slot 編號用 printf 轉成十六進位（jq 沒有內建）
    REQ=$(for (( i = start; i < end; i++ )); do printf '{"jsonrpc":"2.0","id":%d,"method":"eth_getStorageAt","params":["%s","0x%x","%s"]}\n' "$i" "$P" $(( OBS_BASE + i )) "$BLOCK_HEX"; done | jq -sc .)
    VALS=$(rpc_batch "$READ_RPC" <<<"$REQ")
    [ "$(jq 'length' <<<"$VALS")" = "$(( end - start ))" ] || { echo "short batch from $READ_RPC"; exit 1; }
    jq -e 'all(.[]; .result != null)' <<<"$VALS" >/dev/null || { echo "read error: $(jq -c '[.[] | select(.result == null)][0]' <<<"$VALS")"; exit 1; }
    SET=$(jq -r '.[] | "\(.id) \(.result)"' <<<"$VALS" | while read -r i v; do
      printf '{"jsonrpc":"2.0","id":%d,"method":"anvil_setStorageAt","params":["%s","0x%x","%s"]}\n' "$i" "$P" $(( OBS_BASE + i )) "$v"
    done | jq -sc .)
    OUT=$(rpc_batch "$ETH_RPC_URL" <<<"$SET")
    jq -e 'all(.[]; .result == true)' <<<"$OUT" >/dev/null || { echo "anvil_setStorageAt failed: $OUT"; exit 1; }
  done
  TOTAL=$(( TOTAL + TARGET - NEXT ))
  echo "  · ${P}：slot $NEXT..$(( TARGET - 1 )) 已從 fork 區塊 $FORK_BLOCK 讀入"
done
echo "  ✓ 預熱 ${TOTAL} 個 observation slot（fork 區塊 ${FORK_BLOCK}）"
