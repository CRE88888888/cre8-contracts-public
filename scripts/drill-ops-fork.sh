#!/usr/bin/env bash
# 在 BSC 主網 fork 上演一次合約側的營運動作（ROADMAP A6）：
#   1. 緊急暫停單一帳戶，與三種暫停來源（Safe、operator、帳戶本人）
#   2. 撤銷並更換 operator（relayer 私鑰外洩）
#   3. Safe 交接（換 Safe／換簽署人）
#   4. 全域暫停（Safe 一筆停全部、一筆恢復）；備案：逐資產 clearOracle
#   5. 買入額度與「只准賣出」模式（真的在 fork 上 swap）
#   6. venue 白名單：Safe 加入 KyberSwap、OpenOcean，用它們 API 現拿的 calldata 在 fork 上成交，移除後立刻停用
#      （需要網路連到兩家的公開 API；只送查詢，不送任何交易）
# 每一步都讀鏈上的值驗證，全部 ✓ 才算過。步驟與注意事項見 docs/ops-drill.zh-TW.md。
#
# 不送任何主網交易，也不需要私鑰：所有角色都是 anvil 預設測試地址，用 impersonate 代簽；
# 「Safe 送出」等同 Safe 多簽湊滿門檻後執行。先在另一個終端機起全新的 fork：
#   anvil --fork-url https://bsc-mainnet.public.blastapi.io --chain-id 56 --port 8547 --hardfork cancun
# 要用保留較長歷史的 RPC（Blast）：部署要讀 38 個池子，dataseed 只有一兩分鐘的歷史，會 missing trie node。
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
DOGE=0xbA2aE424d960c26247Dd6c32edC70B295c744C43   # 直接池淺，靠聚合器才買得到大單（docs#26、#29）
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
# 交易成功要看 receipt 的 status，不能只看 cast 的結束碼；失敗時用 cast call 重跑一次印出 revert 原因
send() {
  local from="$1"; shift
  local out
  # 固定 gas limit：cast 對 executeRebalance（UR 與聚合器路徑）的估算偶爾偏低，交易會 out of gas。
  # backend 送真的 UserOp 時也要對估算加餘裕。
  out=$(cast send --json --gas-limit 5000000 "$@" --unlocked --from "$from" 2>&1) || fail "send $1 $2：$(tail -c 300 <<<"$out")"
  [ "$(jq -r .status <<<"$out" 2>/dev/null)" = "0x1" ] \
    || fail "send $1 $2 reverted（gasUsed $(jq -r .gasUsed <<<"$out")／gas limit $(cast tx "$(jq -r .transactionHash <<<"$out")" gas)）：$(cast call "$@" --from "$from" 2>&1 | tail -c 300)"
}
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
rebalance_noop() { cast call $EX "executeRebalance(address,(address,address,uint256,uint256,address,bytes)[],uint256)" \
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
send $PROVIDER $REG "publishVersion(uint256,address[],uint16[],bytes32,uint64)" 1 "[$WBNB,$USDT,$DOGE]" "[4000,4000,2000]" \
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
  "executeRebalance(address,(address,address,uint256,uint256,address,bytes)[],uint256)" $ACCOUNT "[]" 99999999999
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
  "executeRebalance(address,(address,address,uint256,uint256,address,bytes)[],uint256)" $ACCOUNT "[]" 99999999999
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
eq "4-11 clearOracle 也一併拿掉 WBNB 的第二價格來源" "$(cast call $RT 'secondaryOf(address)(address,uint16)' $WBNB | head -1)" "$ZERO"
send "$SAFE_B" $RT "setSecondary(address,address,address,uint32,uint16)" $WBNB 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE \
  0xB97Ad0E74fa7d920791E90258A6E2085088b4320 3600 200
[ "$(cast call $RT 'secondaryOf(address)(address,uint16)' $WBNB | head -1)" != "$ZERO" ] \
  && ok "4-12 Safe B setSecondary(WBNB, Chainlink BNB/USD, USDT/USD, 1h, 200 bps) 恢復" || fail "setSecondary"
expect_err "    operator 拿掉第二價格來源" "NotOwner()" $OP2 $RT "clearSecondary(address)" $WBNB

echo
echo "== 情境 5：買入額度與只准賣出模式（真的在 fork 上 swap）"
REB="executeRebalance(address,(address,address,uint256,uint256,address,bytes)[],uint256)"
UR=$(cast call $EX 'universalRouter()(address)')   # 建構時就登錄的 PANCAKE_UR venue
POOL_FEE=$(printf '0x%06x' "$(cast call $WBNB_POOL 'fee()(uint24)' | awk '{print $1}')")
# 一個 V3 exact-in step（收款人釘在 executor），amountOutMin = oracle 地板（swap fee 為 0）
steps_of() { # tokenIn tokenOut amountIn
  local min path input
  min=$(cast call $RT 'previewSwap(address,address,uint256)(uint256,uint256)' "$1" "$2" "$3" | sed -n 2p | awk '{print $1}')
  path=$(cast concat-hex "$1" "$POOL_FEE" "$2")
  input=$(cast abi-encode "f(address,uint256,uint256,bytes,bool)" $EX "$3" "$min" "$path" true)
  echo "[($1,$2,$3,$min,$UR,$(cast abi-encode "f(bytes,bytes[])" 0x00 "[$input]"))]"
}
bal() { cast call "$1" 'balanceOf(address)(uint256)' "$2" | awk '{print $1}'; }
eq "5-1 部署後 maxBuyBps = 10000、numeraire = USDT" "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')/$(cast call $EX 'numeraire()(address)')" "10000/$USDT"
expect_err "5-2 operator 改買入額度" "NotOwner()" $OP2 $EX "setMaxBuyBps(uint16)" 20000
send $ACCOUNT $WBNB "deposit()" --value 0.01ether
send $ACCOUNT $WBNB "approve(address,uint256)" $EX 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
send $ACCOUNT $USDT "approve(address,uint256)" $EX 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
eq "5-3 帳戶持有 0.01 WBNB" "$(bal $WBNB $ACCOUNT)" "10000000000000000"
send "$SAFE_B" $EX "setMaxBuyBps(uint16)" 0
eq "5-4 Safe B setMaxBuyBps(0) → 只准賣出" "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')" "0"
expect_err "5-5 買入 USDT→WBNB" "BuyLimitExceeded(uint256,uint256)" $ACCOUNT $EX "$REB" $ACCOUNT "$(steps_of $USDT $WBNB 1000000000000000000)" 99999999999
send $ACCOUNT $EX "$REB" $ACCOUNT "$(steps_of $WBNB $USDT 10000000000000000)" 99999999999
USDT_GOT=$(bal $USDT $ACCOUNT)
[ "$USDT_GOT" != "0" ] && [ "$(bal $WBNB $ACCOUNT)" = "0" ] && ok "5-6 賣出 WBNB→USDT 照常成交（得到 $(cast from-wei $USDT_GOT) USDT）" || fail "賣出（USDT $USDT_GOT、WBNB $(bal $WBNB $ACCOUNT)）"
eq "    賣出不計入額度（買入窗沒有打開）" "$(cast call $EX 'buyWindowOf(address)(uint64,uint192)' $ACCOUNT | head -1)" "0"
send "$SAFE_B" $EX "setMaxBuyBps(uint16)" 10000
eq "5-7 Safe B setMaxBuyBps(10000) → 恢復" "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')" "10000"
HALF=$(echo "$USDT_GOT / 2" | bc)   # bc：USDT 有 18 位小數，bash 的 64 位整數可能溢位
send $ACCOUNT $EX "$REB" $ACCOUNT "$(steps_of $USDT $WBNB $HALF)" 99999999999
ALLOW=$(cast call $EX 'buyAllowance(address)(uint256,uint256,uint64)' $ACCOUNT)
CAP=$(sed -n 1p <<<"$ALLOW" | awk '{print $1}')
eq "5-8 買入一半 USDT → 成交，buyAllowance 已用 = 買入金額" "$(sed -n 2p <<<"$ALLOW" | awk '{print $1}')" "$HALF"
ok "    額度 = 帳戶總值 $(cast from-wei $CAP) USDT，窗口到 $(sed -n 3p <<<"$ALLOW" | awk '{print $1}')"
expect_err "5-9 再買入一整個額度（超過）" "BuyLimitExceeded(uint256,uint256)" $ACCOUNT $EX "$REB" $ACCOUNT "$(steps_of $USDT $WBNB $CAP)" 99999999999

echo
echo "== 情境 6：venue 白名單（聚合器，用 API 現拿的 calldata 在 fork 上成交）"
KYBER=0x6131B5fae19EA4f9D964eAc0408E4408b66337b5      # KyberSwap MetaAggregationRouterV2（官方文件，所有鏈同址）
OPENOCEAN=0x6352a56caadC4F1E25CD6c75970Fa768A3304e64  # OpenOcean exchange proxy（官方 API 回傳的 to）
venue_kind() { cast call $EX 'venues(address)(uint8,address)' "$1" | head -1; }
floor_of() { cast call $RT 'previewSwap(address,address,uint256)(uint256,uint256)' "$1" "$2" "$3" | sed -n 2p | awk '{print $1}'; }
eq "6-1 Universal Router 是建構時登錄的 PANCAKE_UR venue（kind 1）" "$(venue_kind $UR)" "1"
eq "    KyberSwap 尚未加入（kind 0）" "$(venue_kind $KYBER)" "0"
expect_err "6-2 operator 加 venue" "NotOwner()" $OP2 $EX "setVenue(address,uint8,address)" $KYBER 2 $KYBER
SELL=$(( $(bal $WBNB $ACCOUNT) / 2 ))
MIN=$(floor_of $WBNB $USDT $SELL)
KQ=$(curl -sS --fail-with-body --retry 5 --retry-all-errors --retry-delay 5 -H "x-client-id: cre8-fork-drill" \
  "https://aggregator-api.kyberswap.com/bsc/api/v1/routes?tokenIn=$WBNB&tokenOut=$USDT&amountIn=$SELL") || fail "KyberSwap API 無法連線"
KB=$(jq -c --arg ex "$EX" '{routeSummary: .data.routeSummary, sender: $ex, recipient: $ex, slippageTolerance: 50}' <<<"$KQ" \
  | curl -sS --fail-with-body --retry 5 --retry-all-errors --retry-delay 5 -H "x-client-id: cre8-fork-drill" -H "content-type: application/json" -d @- \
  "https://aggregator-api.kyberswap.com/bsc/api/v1/route/build") || fail "KyberSwap build 失敗"
[ "$(jq -r .data.routerAddress <<<"$KB")" = "$KYBER" ] || fail "KyberSwap 回傳的 router 不是 $KYBER：$(head -c 300 <<<"$KB")"
KDATA=$(jq -r .data.data <<<"$KB")
expect_err "6-3 KyberSwap 還沒加入就成交" "VenueNotAllowed(address)" $ACCOUNT $EX "$REB" $ACCOUNT "[($WBNB,$USDT,$SELL,$MIN,$KYBER,$KDATA)]" 99999999999
send "$SAFE_B" $EX "setVenue(address,uint8,address)" $KYBER 2 $KYBER
eq "6-4 Safe B setVenue(KyberSwap, ERC20_APPROVE) → kind 2" "$(venue_kind $KYBER)" "2"
U0=$(bal $USDT $ACCOUNT)
send $ACCOUNT $EX "$REB" $ACCOUNT "[($WBNB,$USDT,$SELL,$MIN,$KYBER,$KDATA)]" 99999999999
GOT=$(echo "$(bal $USDT $ACCOUNT) - $U0" | bc)
[ "$(echo "$GOT >= $MIN" | bc)" = "1" ] && ok "6-5 經 KyberSwap 賣 $(cast from-wei $SELL) WBNB → $(cast from-wei $GOT) USDT（地板 $(cast from-wei $MIN)）" || fail "KyberSwap 成交低於地板"
eq "    executor 對 KyberSwap 的 allowance 歸零" "$(cast call $WBNB 'allowance(address,address)(uint256)' $EX $KYBER | awk '{print $1}')" "0"
eq "    executor 沒有留下任何 WBNB／USDT" "$(bal $WBNB $EX)/$(bal $USDT $EX)" "0/0"
echo "  -- DOGE：1,000 USDT 經 KyberSwap（docs#26 量到直接池過不了地板）"
cast rpc anvil_setBalance $ACCOUNT 0xA688906BD8B00000 >/dev/null   # 12 BNB（fork 上的假錢）
send $ACCOUNT $WBNB "deposit()" --value 10ether
send $ACCOUNT $EX "$REB" $ACCOUNT "$(steps_of $WBNB $USDT 10000000000000000000)" 99999999999
ok "6-6 帳戶包 10 BNB 並經 Pancake 賣成 $(cast from-wei $(bal $USDT $ACCOUNT)) USDT（準備買 DOGE）"
DIN_AMT=1000000000000000000000   # 1,000 USDT
DMIN=$(floor_of $USDT $DOGE $DIN_AMT)
DINPUT=$(cast abi-encode "f(address,uint256,uint256,bytes,bool)" $EX $DIN_AMT 0 "$(cast concat-hex $USDT 0x002710 $DOGE)" true)
# 直接池能不能過地板取決於當下深度（docs#26 量的是某個區塊），所以只模擬、照實印出，不當成驗收條件。
DOUT=$(cast call $EX "$REB" $ACCOUNT "[($USDT,$DOGE,$DIN_AMT,$DMIN,$UR,$(cast abi-encode "f(bytes,bytes[])" 0x00 "[$DINPUT]"))]" 99999999999 --from $ACCOUNT 2>&1 || true)
if grep -qiE "BelowFloor|$(cast sig 'BelowFloor(uint256,uint256)' | cut -c3-)" <<<"$DOUT"; then
  echo "  · 6-7 對照：同一筆走 DOGE/USDT 1% 直接池 → BelowFloor（這個區塊直接池過不了地板）"
else
  echo "  · 6-7 對照：同一筆走 DOGE/USDT 1% 直接池，這個區塊模擬可以成交（池子深度隨時間變）"
fi
DQ=$(curl -sS --fail-with-body --retry 5 --retry-all-errors --retry-delay 5 -H "x-client-id: cre8-fork-drill" \
  "https://aggregator-api.kyberswap.com/bsc/api/v1/routes?tokenIn=$USDT&tokenOut=$DOGE&amountIn=$DIN_AMT") || fail "KyberSwap API 無法連線"
DB=$(jq -c --arg ex "$EX" '{routeSummary: .data.routeSummary, sender: $ex, recipient: $ex, slippageTolerance: 50}' <<<"$DQ" \
  | curl -sS --fail-with-body --retry 5 --retry-all-errors --retry-delay 5 -H "x-client-id: cre8-fork-drill" -H "content-type: application/json" -d @- \
  "https://aggregator-api.kyberswap.com/bsc/api/v1/route/build") || fail "KyberSwap build 失敗"
[ "$(jq -r .data.routerAddress <<<"$DB")" = "$KYBER" ] || fail "KyberSwap 回傳的 router 不是 $KYBER：$(head -c 300 <<<"$DB")"
D0=$(bal $DOGE $ACCOUNT)
send $ACCOUNT $EX "$REB" $ACCOUNT "[($USDT,$DOGE,$DIN_AMT,$DMIN,$KYBER,$(jq -r .data.data <<<"$DB"))]" 99999999999
DGOT=$(echo "$(bal $DOGE $ACCOUNT) - $D0" | bc)
[ "$(echo "$DGOT >= $DMIN" | bc)" = "1" ] && ok "6-8 經 KyberSwap 買 1,000 USDT 的 DOGE → $(echo "scale=2; $DGOT/10^8" | bc) DOGE（地板 $(echo "scale=2; $DMIN/10^8" | bc)）" || fail "KyberSwap DOGE 成交低於地板"
eq "    executor 沒有留下任何 USDT／DOGE、對 KyberSwap 的 allowance 歸零" "$(bal $USDT $EX)/$(bal $DOGE $EX)/$(cast call $USDT 'allowance(address,address)(uint256)' $EX $KYBER | awk '{print $1}')" "0/0/0"
SELL2=$(bal $WBNB $ACCOUNT)
MIN2=$(floor_of $WBNB $USDT $SELL2)
OQ=$(curl -sS --fail-with-body --retry 5 --retry-all-errors --retry-delay 5 "https://open-api.openocean.finance/v4/bsc/swap?inTokenAddress=$WBNB&outTokenAddress=$USDT&amountDecimals=$SELL2&gasPriceDecimals=50000000&slippage=0.5&account=$EX") \
  || fail "OpenOcean API 無法連線"
[ "$(jq -r .data.to <<<"$OQ" | tr '[:upper:]' '[:lower:]')" = "$(tr '[:upper:]' '[:lower:]' <<<"$OPENOCEAN")" ] || fail "OpenOcean 回傳的 to 不是 $OPENOCEAN：$(head -c 300 <<<"$OQ")"
ODATA=$(jq -r .data.data <<<"$OQ")
send "$SAFE_B" $EX "setVenue(address,uint8,address)" $OPENOCEAN 2 $OPENOCEAN
eq "6-9 Safe B setVenue(OpenOcean, ERC20_APPROVE) → kind 2" "$(venue_kind $OPENOCEAN)" "2"
U1=$(bal $USDT $ACCOUNT)
# OpenOcean 的 route 是照「現在的主網」算的，fork 落後一兩分鐘時，某些來源會在 OpenOcean 內部 revert。
# 成交就驗地板；revert 就驗「整筆退回、帳戶與 executor 餘額不變」——venue 失敗不能動到任何資金。
OOUT=$(cast send --json --gas-limit 5000000 $EX "$REB" $ACCOUNT "[($WBNB,$USDT,$SELL2,$MIN2,$OPENOCEAN,$ODATA)]" 99999999999 --unlocked --from $ACCOUNT 2>&1 || true)
if [ "$(jq -r .status <<<"$OOUT" 2>/dev/null)" = "0x1" ]; then
  GOT2=$(echo "$(bal $USDT $ACCOUNT) - $U1" | bc)
  [ "$(echo "$GOT2 >= $MIN2" | bc)" = "1" ] && ok "6-10 經 OpenOcean 賣 $(cast from-wei $SELL2) WBNB → $(cast from-wei $GOT2) USDT（地板 $(cast from-wei $MIN2)）" || fail "OpenOcean 成交低於地板"
else
  echo "  ⚠ 6-10 OpenOcean 的 calldata 在 fork 上 revert：$(grep -o 'OpenOcean[^"\\]*' <<<"$OOUT" | head -1)"
  eq "    整筆退回：帳戶 WBNB／USDT 不變" "$(bal $WBNB $ACCOUNT)/$(bal $USDT $ACCOUNT)" "$SELL2/$U1"
fi
eq "    executor 對 OpenOcean 的 allowance 為 0、沒有留下任何 WBNB／USDT" "$(cast call $WBNB 'allowance(address,address)(uint256)' $EX $OPENOCEAN | awk '{print $1}')/$(bal $WBNB $EX)/$(bal $USDT $EX)" "0/0/0"
send "$SAFE_B" $EX "removeVenue(address)" $KYBER
eq "6-11 Safe B removeVenue(KyberSwap) → kind 0" "$(venue_kind $KYBER)" "0"
expect_err "    移除後同一筆 KyberSwap 交易" "VenueNotAllowed(address)" $ACCOUNT $EX "$REB" $ACCOUNT "[($WBNB,$USDT,$SELL,$MIN,$KYBER,$KDATA)]" 99999999999

echo
echo "演練全部通過。"
