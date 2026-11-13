#!/usr/bin/env bash
# 在 BSC 主網 fork 上完整預演 DeployAtpMainnet：建一個 2-of-3 Safe、用真實部署者地址（impersonate）部署、
# 驗證重跑會被擋、模擬 Safe acceptOwnership、確認 operator 與 owner 的權限邊界、報價與 enroll。
#
# 不送任何主網交易，也不需要私鑰。先在另一個終端機起 fork（cancun：dataseed 不是 archive 節點，
# prague 的 EIP-2935 blockhash 讀取會 missing trie node）：
#   anvil --fork-url https://bsc-dataseed.bnbchain.org --chain-id 56 --port 8547 --hardfork cancun
# 再執行（部署者、operator 必須是不同地址；Safe 由本腳本在 fork 上新建）：
#   DEPLOYER=0x… OPERATOR=0x… scripts/rehearse-mainnet-fork.sh
set -euo pipefail

export ETH_RPC_URL="${FORK_RPC:-http://127.0.0.1:8547}"
DEPLOYER="${DEPLOYER:?DEPLOYER (address that will broadcast on mainnet) is required}"
OPERATOR="${OPERATOR:?OPERATOR (backend relayer address, must differ from DEPLOYER) is required}"
DEPLOYER=$(cast to-check-sum-address "$DEPLOYER")
OPERATOR=$(cast to-check-sum-address "$OPERATOR")
[ "$DEPLOYER" != "$OPERATOR" ] || { echo "OPERATOR must differ from DEPLOYER"; exit 1; }
cd "$(dirname "$0")/.."

[ "$(cast chain-id)" = "56" ] || { echo "fork at $ETH_RPC_URL is not chain 56"; exit 1; }

ZERO=0x0000000000000000000000000000000000000000
SAFE_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67     # SafeProxyFactory v1.4.1
SAFE_SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762   # SafeL2 v1.4.1
SAFE_FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99    # CompatibilityFallbackHandler v1.4.1
USDT=0x55d398326f99059fF775485246999027B3197955
UR=0x1A0A18AC4BECDDbd6389559687d1A73d8927E416     # PancakeSwap Universal Router（建構時登錄的 venue）
KYBER=0x6131B5fae19EA4f9D964eAc0408E4408b66337b5  # KyberSwap MetaAggregationRouterV2（由 Safe 加入的候選）
# Anvil 預設帳號 #1..#3 當 Safe signer（只存在 fork 上）
S1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
S2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
S3=0x90F79bf6EB2c4f870365E785982E1f101E93b906

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; exit 1; }
expect_revert() { # $1 = label, rest = cast send args
  local label="$1"; shift
  if cast send "$@" >/dev/null 2>&1; then fail "$label 應該 revert 卻成功了"; else ok "$label → revert"; fi
}

echo "== 建 2-of-3 Safe"
INIT=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$S1,$S2,$S3]" 2 $ZERO 0x $SAFE_FALLBACK $ZERO 0 $ZERO)
SALT=$RANDOM
SAFE=$(cast call $SAFE_FACTORY "createProxyWithNonce(address,bytes,uint256)(address)" $SAFE_SINGLETON "$INIT" $SALT --from $S1)
cast send -q $SAFE_FACTORY "createProxyWithNonce(address,bytes,uint256)" $SAFE_SINGLETON "$INIT" $SALT --unlocked --from $S1 >/dev/null
[ "$(cast call "$SAFE" 'getThreshold()(uint256)')" = "2" ] || fail "Safe threshold"
ok "Safe $SAFE"

echo "== 部署（impersonate $DEPLOYER）"
cast rpc anvil_impersonateAccount "$DEPLOYER" >/dev/null
NONCE=$(cast nonce "$DEPLOYER")
BAL_BEFORE=$(cast balance "$DEPLOYER")
ATP_SAFE=$SAFE ATP_TREASURY=$SAFE ATP_OPERATOR=$OPERATOR EXPECTED_DEPLOYER_NONCE=$NONCE \
  forge script script/DeployAtpMainnet.s.sol --rpc-url "$ETH_RPC_URL" --unlocked --sender "$DEPLOYER" \
  --broadcast --slow > /tmp/atp-rehearsal-deploy.log 2>&1 || { tail -30 /tmp/atp-rehearsal-deploy.log; fail "deploy"; }
RUN=broadcast/DeployAtpMainnet.s.sol/56/run-latest.json
REG=$(jq -r '[.transactions[]|select(.contractName=="AtpRegistry")][0].contractAddress' $RUN)
RT=$(jq -r '[.transactions[]|select(.contractName=="AtpMultiPoolOracle")][0].contractAddress' $RUN)
EX=$(jq -r '[.transactions[]|select(.contractName=="AtpExecutor")][0].contractAddress' $RUN)
SPENT=$(cast from-wei $(( BAL_BEFORE - $(cast balance "$DEPLOYER") )))
ok "registry $REG / router $RT / executor $EX"
ok "交易數 $(( $(cast nonce "$DEPLOYER") - NONCE ))，花費 $SPENT BNB（fork 的 gas price）"

echo "== 防呆"
if ATP_SAFE=$SAFE ATP_TREASURY=$SAFE ATP_OPERATOR=$OPERATOR EXPECTED_DEPLOYER_NONCE=$NONCE \
  forge script script/DeployAtpMainnet.s.sol --rpc-url "$ETH_RPC_URL" --unlocked --sender "$DEPLOYER" >/dev/null 2>&1; then
  fail "同一個 nonce 重跑沒有被擋"
else ok "同一個 EXPECTED_DEPLOYER_NONCE 重跑 → revert"; fi
if ATP_SAFE=$S1 ATP_TREASURY=$SAFE ATP_OPERATOR=$OPERATOR EXPECTED_DEPLOYER_NONCE=$(cast nonce "$DEPLOYER") \
  forge script script/DeployAtpMainnet.s.sol --rpc-url "$ETH_RPC_URL" --unlocked --sender "$DEPLOYER" >/dev/null 2>&1; then
  fail "ATP_SAFE 是 EOA 卻沒有被擋"
else ok "ATP_SAFE 填 EOA → revert"; fi
if ATP_SAFE=$SAFE ATP_TREASURY=$SAFE ATP_OPERATOR=$DEPLOYER EXPECTED_DEPLOYER_NONCE=$(cast nonce "$DEPLOYER") \
  forge script script/DeployAtpMainnet.s.sol --rpc-url "$ETH_RPC_URL" --unlocked --sender "$DEPLOYER" >/dev/null 2>&1; then
  fail "ATP_OPERATOR = 部署者卻沒有被擋"
else ok "ATP_OPERATOR 填部署者 → revert"; fi

echo "== Safe 接手前"
[ "$(cast call $REG 'pendingOwner()(address)')" = "$SAFE" ] && ok "registry pendingOwner = Safe"
[ "$(cast call $RT 'pendingOwner()(address)')" = "$SAFE" ] && ok "router pendingOwner = Safe"
expect_revert "非 Safe 呼叫 acceptOwnership" $REG 0x79ba5097 --unlocked --from $S1

echo "== Safe acceptOwnership ×2（impersonate Safe，等同 Safe 多簽執行）"
cast rpc anvil_impersonateAccount "$SAFE" >/dev/null
cast rpc anvil_setBalance "$SAFE" 0x16345785D8A0000 >/dev/null
cast send -q $REG 0x79ba5097 --unlocked --from "$SAFE" >/dev/null
cast send -q $RT 0x79ba5097 --unlocked --from "$SAFE" >/dev/null
[ "$(cast call $REG 'owner()(address)')" = "$SAFE" ] && ok "registry owner = Safe" || fail "registry owner"
[ "$(cast call $RT 'owner()(address)')" = "$SAFE" ] && ok "router owner = Safe" || fail "router owner"

[ "$(cast call $REG 'operator()(address)')" = "$OPERATOR" ] && ok "registry operator = $OPERATOR" || fail "registry operator"

# operator 先 impersonate 並給 gas，下面的 revert 才是權限擋下，不是沒解鎖或沒錢。
cast rpc anvil_impersonateAccount "$OPERATOR" >/dev/null
cast rpc anvil_setBalance "$OPERATOR" 0x16345785D8A0000 >/dev/null
U=0x000000000000000000000000000000000000dEaD
for WHO in "$DEPLOYER" "$OPERATOR"; do
  [ "$WHO" = "$DEPLOYER" ] && echo "== 舊部署者 $WHO 拿不到任何權限" || echo "== operator $WHO 拿不到 admin"
  expect_revert "setDefaultFeeBps"  $REG "setDefaultFeeBps(uint16)" 300 --unlocked --from "$WHO"
  expect_revert "setOperator"       $REG "setOperator(address)" "$S1" --unlocked --from "$WHO"
  expect_revert "setFeeRecipient"   $EX "setFeeRecipient(address)" "$WHO" --unlocked --from "$WHO"
  expect_revert "clearOracle"       $RT "clearOracle(address)" 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c --unlocked --from "$WHO"
  expect_revert "registry transferOwnership" $REG "transferOwnership(address)" "$WHO" --unlocked --from "$WHO"
  expect_revert "router transferOwnership"   $RT "transferOwnership(address)" "$WHO" --unlocked --from "$WHO"
  expect_revert "executor setGlobalPaused"   $EX "setGlobalPaused(bool)" true --unlocked --from "$WHO"
  expect_revert "executor setMaxBuyBps"      $EX "setMaxBuyBps(uint16)" 20000 --unlocked --from "$WHO"
  expect_revert "executor setVenue"          $EX "setVenue(address,uint8,address)" $KYBER 2 $KYBER --unlocked --from "$WHO"
  expect_revert "executor removeVenue"       $EX "removeVenue(address)" $UR --unlocked --from "$WHO"
done

echo "== operator 的日常權限（策略、enroll、暫停）"
cast send -q $REG "registerStrategy(string,string,bool)" "Elon Universe" "rehearsal" true --unlocked --from "$OPERATOR" >/dev/null
ASSETS='[0x5b1910eAaD6450E50f816082Aa078C41F10C292f,0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,0xbA2aE424d960c26247Dd6c32edC70B295c744C43,0x2170Ed0880ac9A755fd29B2688956BD959F933F8]'
cast send -q $REG "publishVersion(uint256,address[],uint16[],bytes32,uint64)" 1 "$ASSETS" "[2000,2000,2000,2000,2000]" \
  0x0000000000000000000000000000000000000000000000000000000000000001 0 --unlocked --from "$OPERATOR" >/dev/null
ok "operator 以 provider 身分註冊並發布策略 1"
cast send -q $REG "enroll(address,uint256)" $U 1 --unlocked --from "$OPERATOR" >/dev/null && ok "operator enroll"
cast send -q $REG "setPaused(address,bool)" $U true --unlocked --from "$OPERATOR" >/dev/null && ok "operator 暫停帳戶"
# 策略 1 已存在、帳戶已 enroll，這兩筆 revert 只可能是權限：部署者交接後不保留 operator 權限。
expect_revert "部署者 enroll"            $REG "enroll(address,uint256)" $S3 1 --unlocked --from "$DEPLOYER"
expect_revert "部署者 setPaused（解除）" $REG "setPaused(address,bool)" $U false --unlocked --from "$DEPLOYER"
expect_revert "Safe（owner）enroll" $REG "enroll(address,uint256)" $S2 1 --unlocked --from "$SAFE"
# A10-2：operator 只能做第一次 enroll，也只能解除自己設的暫停
expect_revert "operator 重新 enroll 已 enroll 的帳戶" $REG "enroll(address,uint256)" $U 1 --unlocked --from "$OPERATOR"
flags() { cast call $REG 'pauseFlags(address)(uint8)' "$1"; }
[ "$(flags $U)" = "2" ] && ok "pauseFlags = 2（operator 設的）" || fail "pauseFlags $(flags $U)"
cast send -q $REG "setPaused(address,bool)" $U true --unlocked --from "$SAFE" >/dev/null
cast send -q $REG "setPaused(address,bool)" $U false --unlocked --from "$OPERATOR" >/dev/null
[ "$(flags $U)" = "1" ] && ok "Safe 也暫停後，operator 解除 → 只清自己的，仍被 Safe 暫停（pauseFlags = 1）" || fail "pauseFlags $(flags $U)"
cast send -q $REG "setPaused(address,bool)" $U false --unlocked --from "$SAFE" >/dev/null
[ "$(flags $U)" = "0" ] && ok "Safe 解除 → pauseFlags = 0" || fail "pauseFlags $(flags $U)"

echo "== Safe 的 admin 權限"
cast send -q $EX "setFeeRecipient(address)" "$SAFE" --unlocked --from "$SAFE" >/dev/null && ok "Safe setFeeRecipient"
cast send -q $REG "setOperator(address)" "$OPERATOR" --unlocked --from "$SAFE" >/dev/null && ok "Safe setOperator"
[ "$(cast call $EX 'globalPaused()(bool)')" = "false" ] || fail "部署後 globalPaused 應為 false"
cast send -q $EX "setGlobalPaused(bool)" true --unlocked --from "$SAFE" >/dev/null
[ "$(cast call $EX 'globalPaused()(bool)')" = "true" ] && ok "Safe setGlobalPaused(true) → 全域暫停" || fail "全域暫停"
cast send -q $EX "setGlobalPaused(bool)" false --unlocked --from "$SAFE" >/dev/null
[ "$(cast call $EX 'globalPaused()(bool)')" = "false" ] && ok "Safe setGlobalPaused(false) → 恢復" || fail "恢復"
[ "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')" = "10000" ] && ok "部署後 maxBuyBps = 10000" || fail "maxBuyBps"
[ "$(cast call $EX 'numeraire()(address)')" = "$USDT" ] && ok "executor numeraire = USDT" || fail "numeraire"
cast send -q $EX "setMaxBuyBps(uint16)" 0 --unlocked --from "$SAFE" >/dev/null
[ "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')" = "0" ] && ok "Safe setMaxBuyBps(0) → 只准賣出" || fail "setMaxBuyBps 0"
cast send -q $EX "setMaxBuyBps(uint16)" 10000 --unlocked --from "$SAFE" >/dev/null
[ "$(cast call $EX 'maxBuyBps()(uint16)' | awk '{print $1}')" = "10000" ] && ok "Safe setMaxBuyBps(10000) → 恢復" || fail "setMaxBuyBps 10000"
venue_kind() { cast call $EX 'venues(address)(uint8,address)' "$1" | head -1; }
[ "$(venue_kind $UR)" = "1" ] && ok "部署後唯一的 venue：Universal Router（PANCAKE_UR）" || fail "UR venue"
[ "$(venue_kind $KYBER)" = "0" ] || fail "部署後不該有 KyberSwap venue"
cast send -q $EX "setVenue(address,uint8,address)" $KYBER 2 $KYBER --unlocked --from "$SAFE" >/dev/null
[ "$(venue_kind $KYBER)" = "2" ] && ok "Safe setVenue(KyberSwap, ERC20_APPROVE)" || fail "setVenue"
cast send -q $EX "removeVenue(address)" $KYBER --unlocked --from "$SAFE" >/dev/null
[ "$(venue_kind $KYBER)" = "0" ] && ok "Safe removeVenue(KyberSwap)" || fail "removeVenue"

echo "== 報價（100 USDT → 各資產）"
for a in 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436 0xbA2aE424d960c26247Dd6c32edC70B295c744C43 \
         0x5b1910eAaD6450E50f816082Aa078C41F10C292f 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c \
         0x2170Ed0880ac9A755fd29B2688956BD959F933F8; do
  q=$(cast call $RT 'previewSwap(address,address,uint256)(uint256,uint256)' $USDT $a 100000000000000000000 | head -1 | awk '{print $1}')
  [ "$q" != "0" ] && ok "$a quoted $q" || fail "$a quote"
done

echo
echo "預演全部通過。"
