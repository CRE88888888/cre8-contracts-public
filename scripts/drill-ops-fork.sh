#!/usr/bin/env bash
# 在 BSC 主網 fork 上演一次合約側的營運動作（ROADMAP A6）：
#   1. 緊急暫停單一帳戶，與三種暫停來源（Safe、operator、帳戶本人）
#   2. 撤銷並更換 operator（relayer 私鑰外洩）
#   3. Safe 交接（換 Safe／換簽署人）
#   4. 全域暫停（Safe 一筆停全部、一筆恢復）；備案：逐資產 clearOracle
# 每一步都讀鏈上的值驗證，全部 ✓ 才算過。步驟與注意事項見 docs/ops-drill.zh-TW.md。
#
# 不送任何主網交易，也不需要私鑰：所有角色都是 anvil 預設測試地址，用 impersonate 代簽；
# 「Safe 送出」等同 Safe 多簽湊滿門檻後執行。先在另一個終端機起全新的 fork：
#   anvil --fork-url https://bsc-dataseed.bnbchain.org --chain-id 56 --port 8547 --hardfork cancun
# 起來後立刻執行（dataseed 不是 archive，歷史窗口只有一兩分鐘）：
#   scripts/drill-ops-fork.sh
set -euo pipefail

export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
cd "$(dirname "$0")/.."

[ "$(cast chain-id)" = "56" ] || { echo "fork at $ETH_RPC_URL is not chain 56"; exit 1; }
# 主網也是 chain 56：只有 anvil 會回 anvil_nodeInfo，真節點在這裡就停。
cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "$ETH_RPC_URL is not an anvil fork"; exit 1; }

ZERO=0x0000000000000000000000000000000000000000
SAFE_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67     # SafeProxyFactory v1.4.1
SAFE_SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762   # SafeL2 v1.4.1
SAFE_FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99    # CompatibilityFallbackHandler v1.4.1
USDT=0x55d398326f99059fF775485246999027B3197955
WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
WBNB_POOL=0x36696169C63e42cd08ce11f5deeBbCeBae652050          # 與 DeployAtpMainnet 相同

# 角色：全部是 anvil 預設測試地址（只存在 fork 上）
S1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # #1 Safe 簽署人
S2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # #2 Safe 簽署人
S3=0x90F79bf6EB2c4f870365E785982E1f101E93b906   # #3 舊 Safe 簽署人（交接時換掉）
S4=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955   # #7 新 Safe 簽署人
OP1=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65  # #4 operator（外洩的那把）
OP2=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f  # #8 新 operator
DEPLOYER=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc  # #5 部署者
PROVIDER=0x976EA74026E726554dB657fA54763abd0C3a0aa9  # #6 策略提供者
ACCOUNT=0x00000000000000000000000000000000A77ACC01   # 被暫停的使用者 smart account（fork 上放一段 code）
USER2=0x00000000000000000000000000000000A77ACC02     # 新 operator 幫忙 enroll 的另一個帳戶

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; exit 1; }
# 讓某個地址可以在 fork 上送交易（impersonate + 給 gas）
actor() { cast rpc anvil_impersonateAccount "$1" >/dev/null; cast rpc anvil_setBalance "$1" 0x16345785D8A0000 >/dev/null; }
# $1 = 誰送，其餘 = cast send 參數；失敗就整份停
send() { local from="$1"; shift; cast send -q "$@" --unlocked --from "$from" >/dev/null || fail "send $*"; }
# 驗證某個呼叫會 revert 而且是指定的 error，不是別的原因（沒解鎖、沒錢、參數錯）
# $1 = 說明, $2 = error 名稱（如 "Unauthorized()"）, $3 = 誰送, 其餘 = 目標與函式參數
expect_err() {
  local label="$1" err="$2" from="$3"; shift 3
  local out sel
  if out=$(cast call "$@" --from "$from" 2>&1); then fail "$label 應該 revert 卻成功了"; fi
  sel=$(cast sig "$err")
  if grep -qiE "${sel#0x}|${err%%(*}" <<<"$out"; then ok "$label → revert $err"; else fail "$label revert 原因不是 $err：$out"; fi
}
eq() { [ "$(tr '[:upper:]' '[:lower:]' <<<"$2")" = "$(tr '[:upper:]' '[:lower:]' <<<"$3")" ] && ok "$1" || fail "$1：得到 $2，預期 $3"; }
flags_of() { cast call $REG 'pauseFlags(address)(uint8)' "$1"; }   # 1 = Safe、2 = operator、4 = 帳戶本人
paused_of() { cast call $REG "enrollments(address)((uint256,uint16,bool))" "$1" | tr -d '()' | awk -F', ' '{print $3}'; }
rebalance_noop() { cast call $EX "executeRebalance(address,(address,address,uint256,uint256,bytes,bytes[])[],uint256)" \
  "$ACCOUNT" "[]" 99999999999 --from "$ACCOUNT" >/dev/null 2>&1; }
new_safe() { # $@ = 簽署人；門檻固定 2
  local signers; signers=$(IFS=,; echo "$*")
  local init salt addr
  init=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
    "[$signers]" 2 $ZERO 0x $SAFE_FALLBACK $ZERO 0 $ZERO)
  salt=$RANDOM$RANDOM
  addr=$(cast call $SAFE_FACTORY "createProxyWithNonce(address,bytes,uint256)(address)" $SAFE_SINGLETON "$init" "$salt" --from "$1")
  send "$1" $SAFE_FACTORY "createProxyWithNonce(address,bytes,uint256)" $SAFE_SINGLETON "$init" "$salt"
  [ "$(cast call "$addr" 'getThreshold()(uint256)')" = "2" ] || fail "Safe threshold"
  echo "$addr"
}

for a in $S1 $S2 $S3 $S4 $OP1 $OP2 $DEPLOYER $PROVIDER; do actor "$a"; done

echo "== 準備：部署 v2 並交給 Safe A（與主網同一支 DeployAtpMainnet）"
SAFE_A=$(new_safe $S1 $S2 $S3)
ok "Safe A $SAFE_A（2-of-3：#1 #2 #3）"
ATP_SAFE=$SAFE_A ATP_TREASURY=$SAFE_A ATP_OPERATOR=$OP1 EXPECTED_DEPLOYER_NONCE=$(cast nonce $DEPLOYER) \
  forge script script/DeployAtpMainnet.s.sol --rpc-url "$ETH_RPC_URL" --unlocked --sender $DEPLOYER \
  --broadcast --slow > /tmp/atp-drill-deploy.log 2>&1 || { tail -30 /tmp/atp-drill-deploy.log; fail "deploy"; }
RUN=broadcast/DeployAtpMainnet.s.sol/56/run-latest.json
REG=$(jq -r '[.transactions[]|select(.contractName=="AtpRegistry")][0].contractAddress' $RUN)
RT=$(jq -r '[.transactions[]|select(.contractName=="AtpMultiPoolOracle")][0].contractAddress' $RUN)
EX=$(jq -r '[.transactions[]|select(.contractName=="AtpExecutor")][0].contractAddress' $RUN)
ok "registry $REG / router $RT / executor $EX"
actor "$SAFE_A"
send "$SAFE_A" $REG 0x79ba5097
send "$SAFE_A" $RT 0x79ba5097
eq "registry owner = Safe A" "$(cast call $REG 'owner()(address)')" "$SAFE_A"
eq "router owner = Safe A" "$(cast call $RT 'owner()(address)')" "$SAFE_A"
eq "operator = OP1" "$(cast call $REG 'operator()(address)')" "$OP1"
send $PROVIDER $REG "registerStrategy(string,string,bool)" "Drill" "ops drill" true
send $PROVIDER $REG "publishVersion(uint256,address[],uint16[],bytes32,uint64)" 1 "[$WBNB]" "[10000]" \
  0x0000000000000000000000000000000000000000000000000000000000000001 0
cast rpc anvil_setCode $ACCOUNT 0x00 >/dev/null   # smart account 必須有 code，executor 才接受
actor $ACCOUNT
send $OP1 $REG "enroll(address,uint256)" $ACCOUNT 1
eq "帳戶已 enroll、未暫停" "$(paused_of $ACCOUNT)" "false"
rebalance_noop && ok "帳戶可以呼叫 executeRebalance（空步驟）" || fail "未暫停時 executeRebalance 不該 revert"

echo
echo "== 情境 1：緊急暫停單一帳戶（建議順序：先撤 operator，再暫停）"
send "$SAFE_A" $REG "setOperator(address)" $ZERO
eq "1-1 Safe A setOperator(0) → operator = 0" "$(cast call $REG 'operator()(address)')" "$ZERO"
send "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT true
eq "1-2 Safe A setPaused(帳戶, true) → paused = true" "$(paused_of $ACCOUNT)" "true"
expect_err "1-3 舊 operator 解除暫停" "Unauthorized()" $OP1 $REG "setPaused(address,bool)" $ACCOUNT false
expect_err "1-4 舊 operator 重新 enroll" "Unauthorized()" $OP1 $REG "enroll(address,uint256)" $ACCOUNT 1
expect_err "1-5 帳戶 executeRebalance" "Paused()" $ACCOUNT $EX \
  "executeRebalance(address,(address,address,uint256,uint256,bytes,bytes[])[],uint256)" $ACCOUNT "[]" 99999999999
echo "  -- 注意：帳戶本人重新 enroll 會清掉暫停"
send $ACCOUNT $REG "enroll(address,uint256)" $ACCOUNT 1
eq "1-6 帳戶自己 enroll → paused = false（Safe 的暫停被帳戶本人解除）" "$(paused_of $ACCOUNT)" "false"
echo "  -- 帳戶本人的暫停：Safe 解除不了，只有帳戶本人能解除"
send $ACCOUNT $REG "setPaused(address,bool)" $ACCOUNT true
eq "1-7 帳戶自己暫停 → pauseFlags = 4" "$(flags_of $ACCOUNT)" "4"
send "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT true
eq "1-8 Safe A 也暫停 → pauseFlags = 5" "$(flags_of $ACCOUNT)" "5"
send "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT false
eq "1-9 Safe A 解除 → 只清自己的，仍被帳戶本人暫停（pauseFlags = 4）" "$(flags_of $ACCOUNT)" "4"
eq "    paused = true" "$(paused_of $ACCOUNT)" "true"
send $ACCOUNT $REG "setPaused(address,bool)" $ACCOUNT false
eq "1-10 帳戶自己解除 → pauseFlags = 0" "$(flags_of $ACCOUNT)" "0"
send "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT true
eq "1-11 Safe A 再暫停一次 → pauseFlags = 1" "$(flags_of $ACCOUNT)" "1"

echo
echo "== 情境 2：撤銷並更換 operator（OP1 私鑰外洩）"
send "$SAFE_A" $REG "setOperator(address)" $OP2
eq "2-1 Safe A setOperator(OP2) → operator = OP2" "$(cast call $REG 'operator()(address)')" "$OP2"
expect_err "2-2 舊 operator enroll" "Unauthorized()" $OP1 $REG "enroll(address,uint256)" $USER2 1
expect_err "2-3 舊 operator setPaused" "Unauthorized()" $OP1 $REG "setPaused(address,bool)" $ACCOUNT false
send $OP2 $REG "enroll(address,uint256)" $USER2 1
eq "2-4 新 operator enroll 另一個帳戶" "$(cast call $REG 'isEnrolled(address)(bool)' $USER2)" "true"
send $OP2 $REG "setPaused(address,bool)" $ACCOUNT false
eq "2-5 新 operator 解除 → 解除不了 Safe 的暫停（pauseFlags = 1）" "$(flags_of $ACCOUNT)" "1"
expect_err "2-6 新 operator 重新 enroll 已 enroll 的帳戶" "AlreadyEnrolled(address)" $OP2 $REG "enroll(address,uint256)" $ACCOUNT 1
send $OP2 $REG "setPaused(address,bool)" $ACCOUNT true
eq "2-7 新 operator 自己暫停 → pauseFlags = 3" "$(flags_of $ACCOUNT)" "3"
send $OP2 $REG "setPaused(address,bool)" $ACCOUNT false
eq "2-8 新 operator 解除自己的 → pauseFlags = 1" "$(flags_of $ACCOUNT)" "1"
send "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT false
eq "2-9 Safe A 解除 → paused = false" "$(paused_of $ACCOUNT)" "false"
rebalance_noop && ok "2-10 帳戶恢復，executeRebalance 不再 revert" || fail "解除暫停後 executeRebalance 仍 revert"

echo
echo "== 情境 3：Safe 交接（Safe A → Safe B，簽署人 #3 換成 #7）"
SAFE_B=$(new_safe $S1 $S2 $S4)
ok "3-1 Safe B $SAFE_B（2-of-3：#1 #2 #7）"
send "$SAFE_A" $REG "transferOwnership(address)" "$SAFE_B"
send "$SAFE_A" $RT "transferOwnership(address)" "$SAFE_B"
eq "3-2 registry pendingOwner = Safe B" "$(cast call $REG 'pendingOwner()(address)')" "$SAFE_B"
eq "    router pendingOwner = Safe B" "$(cast call $RT 'pendingOwner()(address)')" "$SAFE_B"
eq "    接受前 registry owner 仍是 Safe A" "$(cast call $REG 'owner()(address)')" "$SAFE_A"
expect_err "3-3 非 Safe B 呼叫 registry acceptOwnership" "NotPendingOwner()" $S4 $REG "acceptOwnership()"
expect_err "    非 Safe B 呼叫 router acceptOwnership" "NotPendingOwner()" $S4 $RT "acceptOwnership()"
actor "$SAFE_B"
send "$SAFE_B" $REG 0x79ba5097
send "$SAFE_B" $RT 0x79ba5097
eq "3-4 registry owner = Safe B" "$(cast call $REG 'owner()(address)')" "$SAFE_B"
eq "    router owner = Safe B" "$(cast call $RT 'owner()(address)')" "$SAFE_B"
eq "    registry pendingOwner 清空" "$(cast call $REG 'pendingOwner()(address)')" "$ZERO"
eq "    router pendingOwner 清空" "$(cast call $RT 'pendingOwner()(address)')" "$ZERO"
expect_err "3-5 Safe A setOperator" "NotOwner()" "$SAFE_A" $REG "setOperator(address)" $OP1
expect_err "    Safe A setPaused" "Unauthorized()" "$SAFE_A" $REG "setPaused(address,bool)" $ACCOUNT true
expect_err "    Safe A setDefaultFeeBps" "NotOwner()" "$SAFE_A" $REG "setDefaultFeeBps(uint16)" 100
expect_err "    Safe A executor setFeeRecipient" "NotOwner()" "$SAFE_A" $EX "setFeeRecipient(address)" "$SAFE_A"
expect_err "    Safe A router clearOracle" "NotOwner()" "$SAFE_A" $RT "clearOracle(address)" $WBNB
expect_err "    Safe A registry transferOwnership" "NotOwner()" "$SAFE_A" $REG "transferOwnership(address)" "$SAFE_A"
send "$SAFE_B" $EX "setFeeRecipient(address)" "$SAFE_B"
eq "3-6 Safe B setFeeRecipient（executor 跟著 registry owner，不用另外交接）" "$(cast call $EX 'feeRecipient()(address)')" "$SAFE_B"
send "$SAFE_B" $REG "setOperator(address)" $OP1
send "$SAFE_B" $REG "setOperator(address)" $OP2
eq "    Safe B setOperator" "$(cast call $REG 'operator()(address)')" "$OP2"

echo
echo "== 情境 4：全域暫停（Safe 一筆停全部、一筆恢復）"
eq "4-1 部署後 globalPaused = false" "$(cast call $EX 'globalPaused()(bool)')" "false"
expect_err "4-2 operator 啟動全域暫停" "NotOwner()" $OP2 $EX "setGlobalPaused(bool)" true
expect_err "    舊 Safe A 啟動全域暫停" "NotOwner()" "$SAFE_A" $EX "setGlobalPaused(bool)" true
send "$SAFE_B" $EX "setGlobalPaused(bool)" true
eq "4-3 Safe B setGlobalPaused(true) → globalPaused = true" "$(cast call $EX 'globalPaused()(bool)')" "true"
expect_err "4-4 帳戶 executeRebalance（未被逐帳戶暫停）" "ExecutorPaused()" $ACCOUNT $EX \
  "executeRebalance(address,(address,address,uint256,uint256,bytes,bytes[])[],uint256)" $ACCOUNT "[]" 99999999999
expect_err "4-5 operator 解除全域暫停" "NotOwner()" $OP2 $EX "setGlobalPaused(bool)" false
send "$SAFE_B" $EX "setGlobalPaused(bool)" false
eq "4-6 Safe B setGlobalPaused(false) → globalPaused = false" "$(cast call $EX 'globalPaused()(bool)')" "false"
rebalance_noop && ok "4-7 恢復後 executeRebalance 不再 revert" || fail "恢復後 executeRebalance 仍 revert"

echo
echo "== 情境 4 備案：逐資產拔價格來源（只停單一資產）"
send "$SAFE_B" $RT "clearOracle(address)" $WBNB
eq "4-8 Safe B clearOracle(WBNB) → oracleOf(WBNB) = 0" "$(cast call $RT 'oracleOf(address)(address)' $WBNB)" "$ZERO"
expect_err "4-9 USDT→WBNB 報價（所有帳戶的 WBNB swap 都停）" "OracleNotSet(address)" $S1 $RT \
  "previewSwap(address,address,uint256)" $USDT $WBNB 100000000000000000000
send "$SAFE_B" $RT "setOracle(address,address,uint32,uint16,uint32)" $WBNB $WBNB_POOL 1800 100 3600
NEW_ORACLE=$(cast call $RT 'oracleOf(address)(address)' $WBNB)
[ "$NEW_ORACLE" != "$ZERO" ] || fail "setOracle"
q=$(cast call $RT 'previewSwap(address,address,uint256)(uint256,uint256)' $USDT $WBNB 100000000000000000000 | head -1 | awk '{print $1}')
[ "$q" != "0" ] && ok "4-10 Safe B setOracle 恢復（新 oracle $NEW_ORACLE），報價 $q" || fail "恢復後報價為 0"

echo
echo "演練全部通過。"
