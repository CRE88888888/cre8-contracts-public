#!/bin/bash
# Return whatever BNB is left in the throwaway key to an address the user names. One plain transfer.
# Usage: PROBE_KEY_FILE=<key file> ETH_RPC_URL=<BSC RPC> ./sweep.sh <recipient>
set -euo pipefail
TO=${1:?recipient address}
RPC=${ETH_RPC_URL:?ETH_RPC_URL}
KEY=$(cat "${PROBE_KEY_FILE:?PROBE_KEY_FILE}")
FROM=$(cast wallet address --private-key "$KEY")
BAL=$(cast balance "$FROM" --rpc-url "$RPC")
PRICE=$(cast gas-price --rpc-url "$RPC")
FEE=$((21000 * PRICE))
[ "$BAL" -gt "$FEE" ] || { echo "nothing to sweep: balance $BAL wei"; exit 0; }
echo "sweeping $(cast from-wei $((BAL - FEE))) BNB from $FROM to $TO"
cast send "$TO" --value $((BAL - FEE)) --gas-limit 21000 --gas-price "$PRICE" --private-key "$KEY" --rpc-url "$RPC" >/dev/null
echo "left: $(cast balance "$FROM" --rpc-url "$RPC") wei"
