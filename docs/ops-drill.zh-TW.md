# 合約營運演練（ROADMAP A6，合約側）

## 白話摘要

合約上線後，平台有兩種「鑰匙」：

- **Safe**（多簽錢包，至少 2 個人一起簽才能動）：最高權限。可以換 operator、暫停任何帳戶、一次暫停全部交易、改手續費、換價格來源、把整個管理權交給另一個 Safe。
- **operator**（後端伺服器上的一把私鑰）：只能做日常的兩件事：幫新帳戶「第一次加入策略」(enroll)，以及「暫停／恢復」某個帳戶（只能恢復它自己暫停的）。動不到錢、手續費、管理權，也不能把已經加入的帳戶換到別的策略或版本。

使用者的帳戶本人（用自己錢包簽的交易）也能暫停、恢復自己，換策略或換版本只能由帳戶本人做。

出事時要記住四件事：

1. **Safe 暫停的帳戶，operator 解除不了。** 暫停會記下是誰暫停的（Safe、operator、帳戶本人）。operator 只能解除自己暫停的；Safe 可以解除自己和 operator 的；帳戶本人可以解除全部。懷疑 operator 私鑰外洩時，仍然建議先撤掉 operator（它還能幫新帳戶第一次加入策略）。
2. **使用者自己恢復或重新加入策略，會清掉所有暫停。** 帳戶是使用者自己的，Safe 的暫停只能擋住平台這一側，擋不住帳戶本人；反過來，使用者自己暫停的，Safe 也解除不了。
3. **出大事（價格來源或交易合約本身有問題）時，Safe 一筆交易就能停掉全部交易，一筆就能恢復。** 停的期間所有再平衡都會失敗，包括賣出；使用者仍然可以用自己的錢包把資金直接轉出。operator 碰不到這個開關。
4. **每個帳戶每 24 小時最多買入「帳戶總值 × 100%」，賣成 USDT 不受限制。** 外洩的 session key 就算繞過後端，自己反覆來回換幣，每一輪都要買回，買到額度就停。Safe 可以把額度調成 0，變成「只准賣出」模式：所有人都只能賣、不能買。operator 碰不到這個設定。

以下五個情境都在本機 BSC 主網 fork 上演過，腳本是 [`scripts/drill-ops-fork.sh`](../scripts/drill-ops-fork.sh)，全部 ✓。

## 怎麼重跑

```bash
# 終端機 1：全新的 fork（dataseed 不是 archive，起來後要立刻跑）
anvil --fork-url https://bsc-dataseed.bnbchain.org --chain-id 56 --port 8547 --hardfork cancun
# 終端機 2
scripts/drill-ops-fork.sh
```

不送主網交易、不用私鑰：所有角色都是 anvil 預設測試地址，用 `anvil_impersonateAccount` 代簽。腳本裡「Safe 送出」等同真實環境中 Safe 湊滿 2 個簽名後執行。部署用的是主網同一支 `script/DeployAtpMainnet.s.sol`。每一步都讀鏈上的值驗證；預期 revert 的步驟會檢查 revert 的 error 名稱，避免把「沒解鎖」或「沒 gas」誤算成權限擋下。

演練用的角色：

| 角色 | 演練地址 | 主網對應 |
| --- | --- | --- |
| Safe A | 腳本新建 2-of-3（#1 #2 #3） | 目前的 Safe |
| Safe B | 腳本新建 2-of-3（#1 #2 #7） | 交接後的新 Safe |
| OP1 | anvil #4 | 目前的 operator（backend relayer） |
| OP2 | anvil #8 | 換上的新 operator |
| 部署者 | anvil #5 | 部署者，交接後沒有任何權限 |
| 帳戶 | `0x…A77ACC01`（fork 上放一段 code） | 使用者的 smart account |

## 暫停的三個來源（A10-2）

registry 用 `pauseFlags(帳戶)` 記下是誰暫停的，三個 bit 可以同時存在。只要有任何一個 bit，帳戶就是暫停（`enrollments(帳戶).paused` = true，`executeRebalance` revert `Paused()`）。

| 誰呼叫 `setPaused(帳戶, …)` | `true`（暫停） | `false`（恢復） |
| --- | --- | --- |
| 帳戶本人 | 設 4 | **清掉全部** |
| Safe（owner） | 設 1 | 清掉 1 和 2，不動 4 |
| operator | 設 2 | 只清 2 |

- 帳戶本人重新 `enroll`（換策略或換版本）也會清掉全部。
- operator 只能幫**還沒加入**的帳戶做第一次 `enroll`；對已加入的帳戶 revert `AlreadyEnrolled(address)`。它不能換別人的策略，也不能用重新 enroll 清掉暫停。
- 恢復時如果還剩別人的 bit，交易照樣成功，但帳戶仍然是暫停。結果看 `pauseFlags` 或 `PauseFlagsSet` event。

## 情境 1：緊急暫停單一帳戶

**什麼時候用：** 某個帳戶的再平衡行為異常，或懷疑 operator 私鑰外洩。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 1-1 | Safe | registry `setOperator(0x0000…0000)` | `operator()` = 0，任何人都不再有 operator 權限 |
| 1-2 | Safe | registry `setPaused(帳戶, true)` | `enrollments(帳戶).paused` = true |
| 1-3 | （舊 operator 嘗試） | `setPaused(帳戶, false)` | revert `Unauthorized()` |
| 1-4 | （舊 operator 嘗試） | `enroll(帳戶, id)` | revert `Unauthorized()` |
| 1-5 | （帳戶嘗試） | executor `executeRebalance(帳戶, …)` | revert `Paused()` |
| 1-6 | 帳戶本人 | `enroll(帳戶, id)` | 清掉所有暫停，`paused` = false |
| 1-7 | 帳戶本人 | `setPaused(帳戶, true)` | `pauseFlags` = 4 |
| 1-8 | Safe | `setPaused(帳戶, true)` | `pauseFlags` = 5 |
| 1-9 | Safe | `setPaused(帳戶, false)` | `pauseFlags` = 4，**仍然暫停**（Safe 解除不了帳戶本人的） |
| 1-10 | 帳戶本人 | `setPaused(帳戶, false)` | `pauseFlags` = 0 |
| 1-11 | Safe | `setPaused(帳戶, true)` | `pauseFlags` = 1（接著演情境 2） |

**順序：** A10-2 之後，operator 已經解除不了 Safe 設的暫停，也不能重新 enroll 已加入的帳戶，所以「先撤 operator 再暫停」不再是擋住暫停被解除的必要條件。但懷疑 operator 外洩時仍然建議先撤：它還能幫新帳戶第一次 enroll，也還能暫停帳戶（擾亂服務）。先撤 operator 的代價是：在換上新 operator（情境 2）之前，後端無法幫任何人 enroll。

**注意：帳戶本人可以解除任何暫停**（1-6 重新 enroll、1-10 恢復）。帳戶是使用者自己的，Safe 的暫停只擋得住平台這一側（operator、後端），擋不住使用者自己從 smart account 恢復。反過來，使用者自己暫停的，Safe 也解除不了（1-9）。

**恢復：** Safe `setPaused(帳戶, false)`，會一起清掉 operator 設的暫停（見 2-9、2-10）。

## 情境 2：撤銷並更換 operator（relayer 私鑰外洩）

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 2-1 | Safe | registry `setOperator(新 operator)` | `operator()` = 新 operator |
| 2-2 | （舊 operator 嘗試） | `enroll(其他帳戶, id)` | revert `Unauthorized()` |
| 2-3 | （舊 operator 嘗試） | `setPaused(帳戶, false)` | revert `Unauthorized()` |
| 2-4 | 新 operator | `enroll(其他帳戶, id)`（第一次加入） | `isEnrolled` = true |
| 2-5 | 新 operator | `setPaused(帳戶, false)` | `pauseFlags` 仍是 1：**解除不了 Safe 的暫停** |
| 2-6 | （新 operator 嘗試） | `enroll(帳戶, id)`（帳戶已加入） | revert `AlreadyEnrolled(address)` |
| 2-7 | 新 operator | `setPaused(帳戶, true)` | `pauseFlags` = 3 |
| 2-8 | 新 operator | `setPaused(帳戶, false)` | `pauseFlags` = 1（只清自己的） |
| 2-9 | Safe | `setPaused(帳戶, false)` | `paused` = false |
| 2-10 | 帳戶 | `executeRebalance(帳戶, [], …)` | 不再 revert |

`setOperator` 是直接替換，不需要新 operator 接受。合約裡同時只有一個 operator，換上新的那一刻舊的就失效。後端要同時換成新私鑰（backend 的 `OPERATOR_PRIVATE_KEY`），否則 enroll 會一直失敗。舊 operator 生前設的暫停（bit 2）會留著，只有 Safe 或帳戶本人能清掉。

## 情境 3：Safe 交接（換 Safe，或換簽署人）

registry 和 router 各自做兩步交接；executor 沒有自己的 owner，`setFeeRecipient` 看的是 registry 的 owner，所以不用另外交接。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 3-1 | — | 建好新 Safe B，確認門檻 ≥ 2 | — |
| 3-2 | Safe A | registry `transferOwnership(Safe B)`、router `transferOwnership(Safe B)` | 兩邊 `pendingOwner()` = Safe B；`owner()` 仍是 Safe A |
| 3-3 | （其他人嘗試） | `acceptOwnership()` | revert `NotPendingOwner()` |
| 3-4 | Safe B | registry `acceptOwnership()`、router `acceptOwnership()`（calldata `0x79ba5097`） | 兩邊 `owner()` = Safe B，`pendingOwner()` = 0 |
| 3-5 | （Safe A 嘗試） | `setOperator`、`setDefaultFeeBps`、`transferOwnership`、executor `setFeeRecipient`、router `clearOracle` | revert `NotOwner()`；`setPaused` revert `Unauthorized()` |
| 3-6 | Safe B | executor `setFeeRecipient`、registry `setOperator` | 成功 |

**注意：**
- 在 Safe B 接受之前，Safe A 仍然擁有全部權限；`transferOwnership` 送錯地址可以再送一次覆蓋，或送 `transferOwnership(0x0)` 取消。
- registry 和 router 是兩筆獨立的交接，**兩筆都要接受**。只接受一筆的話，兩份合約的 owner 會不一樣（例如 router 還在 Safe A 手上）。演練 3-4 兩邊都有驗。
- 只換簽署人（不換 Safe 地址）不用動合約，在 Safe 介面裡增刪簽署人即可；本情境是換成另一個 Safe 地址的做法。

## 情境 4：全域暫停

**什麼時候用：** oracle 或 executor 本身有問題，例如報價異常、發現合約漏洞，任何一筆再平衡都可能用錯的地板價成交。

executor 有一個 `globalPaused` 開關，只有 registry 的 owner（Safe）能切換；Safe 交接後，開關自動跟著新 Safe。`executeRebalance` 第一行就檢查它，比任何逐帳戶的檢查都早。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 4-1 | — | executor `globalPaused()` | 部署後是 false |
| 4-2 | （operator、舊 Safe 嘗試） | executor `setGlobalPaused(true)` | revert `NotOwner()` |
| 4-3 | Safe | executor `setGlobalPaused(true)` | `globalPaused()` = true |
| 4-4 | （帳戶嘗試，帳戶本身沒被暫停） | executor `executeRebalance(帳戶, …)` | revert `ExecutorPaused()` |
| 4-5 | （operator 嘗試） | executor `setGlobalPaused(false)` | revert `NotOwner()` |
| 4-6 | Safe | executor `setGlobalPaused(false)` | `globalPaused()` = false |
| 4-7 | 帳戶 | `executeRebalance(帳戶, [], …)` | 不再 revert |

**注意：**
- 全域暫停**連賣成 USDT 也擋**：會用到它，通常是價格來源有問題，這時賣出也會用錯的地板價。使用者退出走 owner 轉出（錢包的 sudo 交易），不經過 executor，不受影響。
- 錯誤名稱是 `ExecutorPaused()`，跟單一帳戶的 `Paused()` 不同，後端和 app 用它分辨「平台暫停」和「你的帳戶暫停」。
- 全域暫停不改任何帳戶的 enrollment，也不改逐帳戶暫停。恢復後每個帳戶回到原本的狀態。

### 備案：逐資產拔價格來源

只想停單一資產時，Safe 對 router 送 `clearOracle(資產)`。之後所有帳戶涉及該資產的 swap 都會 fail closed（`OracleNotSet`），其他資產照常。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 4-8 | Safe | router `clearOracle(WBNB)` | `oracleOf(WBNB)` = 0 |
| 4-9 | （任何人） | router `previewSwap(USDT, WBNB, …)` | revert `OracleNotSet(address)` |
| 4-10 | Safe | router `setOracle(WBNB, 池子, 1800, 100, 3600)` | 部署一個**新的** oracle，報價恢復 |

**注意：** `clearOracle` 不是暫停開關。恢復時 `setOracle` 會部署新的 oracle 合約（地址會變），參數要照 `DeployAtpMainnet` 的同一組重填（池子、30 分鐘 TWAP、slippage、1 小時 age）。

## 情境 5：買入額度與「只准賣出」模式（A10-1）

**規則：** 每個帳戶在固定 24 小時窗內，USDT→資產的累計買入金額不能超過「帳戶目前總值 × `maxBuyBps` / 10000」（部署時是 10000，也就是 100%）。窗口從第一筆買入開始算，24 小時後的第一筆買入重新開窗。資產→USDT 的賣出不擋，也不計入。帳戶總值 = USDT 餘額 + 策略版本內其他資產用 oracle 報價換算成 USDT；報不出價的資產算 0（額度只會變小）。超過時整批 revert `BuyLimitExceeded(買入後累計, 額度)`。

**什麼時候調：**
- `setMaxBuyBps(0)`：只准賣出。例如某個資產的買入方向有問題，或想讓使用者先退出再說。跟全域暫停（情境 4）不同，賣出仍然可以。
- 調高（上限 20000，也就是 200%）：例如要讓大量帳戶在一天內換到新版本。只有 Safe 能改。

演練用真的 swap（fork 上的 PancakeSwap WBNB/USDT 池），帳戶先包 0.01 BNB 成 WBNB：

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 5-1 | — | executor `maxBuyBps()`、`numeraire()` | 10000、USDT |
| 5-2 | （operator 嘗試） | executor `setMaxBuyBps(20000)` | revert `NotOwner()` |
| 5-3 | 帳戶 | WBNB `deposit()`、approve executor | 帳戶持有 0.01 WBNB |
| 5-4 | Safe | executor `setMaxBuyBps(0)` | 只准賣出 |
| 5-5 | （帳戶嘗試） | `executeRebalance`：USDT→WBNB | revert `BuyLimitExceeded` |
| 5-6 | 帳戶 | `executeRebalance`：WBNB→USDT（全部） | 成交；買入窗沒有打開（賣出不計入） |
| 5-7 | Safe | executor `setMaxBuyBps(10000)` | 恢復 |
| 5-8 | 帳戶 | `executeRebalance`：USDT→WBNB（一半） | 成交；`buyAllowance(帳戶)` 的已用 = 買入金額，額度 = 帳戶總值 |
| 5-9 | （帳戶嘗試） | `executeRebalance`：USDT→WBNB（一整個額度） | revert `BuyLimitExceeded` |

**注意：**
- 後端排程前要讀 `buyAllowance(帳戶)`（額度、已用、窗口結束時間），把這一批的買入縮到「額度 − 已用」以內，留 1–2% 餘裕（讀值和上鏈之間總值會小幅變動）。額度用完就等到窗口結束。
- 使用者退出（redeem、close 都是賣成 USDT）和 owner 自己轉出不受額度影響。
- 額度跟著「目前」總值算，所以同一天加碼存入後，額度也跟著變大。

## 演練輸出（2026-11-13，fork block 133202784，40 秒）

```
== 準備：部署 v2 並交給 Safe A（與主網同一支 DeployAtpMainnet）
  ✓ Safe A 0x73d35883F3Ce673Af336C34b314D2c0119AF2921（2-of-3：#1 #2 #3）
  ✓ registry 0x891d13a0a03bb7c435bc7b7c2242f2c2982b6733 / router 0x61df85c020f21e320b9889f9afd71a7176551818 / executor 0xcd8a3ae15dff0fc218473ca58d00f4b49b6414a9
  ✓ registry owner = Safe A
  ✓ router owner = Safe A
  ✓ operator = OP1
  ✓ 帳戶已 enroll、未暫停
  ✓ 帳戶可以呼叫 executeRebalance（空步驟）

== 情境 1：緊急暫停單一帳戶（建議順序：先撤 operator，再暫停）
  ✓ 1-1 Safe A setOperator(0) → operator = 0
  ✓ 1-2 Safe A setPaused(帳戶, true) → paused = true
  ✓ 1-3 舊 operator 解除暫停 → revert Unauthorized()
  ✓ 1-4 舊 operator 重新 enroll → revert Unauthorized()
  ✓ 1-5 帳戶 executeRebalance → revert Paused()
  -- 注意：帳戶本人重新 enroll 會清掉暫停
  ✓ 1-6 帳戶自己 enroll → paused = false（Safe 的暫停被帳戶本人解除）
  -- 帳戶本人的暫停：Safe 解除不了，只有帳戶本人能解除
  ✓ 1-7 帳戶自己暫停 → pauseFlags = 4
  ✓ 1-8 Safe A 也暫停 → pauseFlags = 5
  ✓ 1-9 Safe A 解除 → 只清自己的，仍被帳戶本人暫停（pauseFlags = 4）
  ✓     paused = true
  ✓ 1-10 帳戶自己解除 → pauseFlags = 0
  ✓ 1-11 Safe A 再暫停一次 → pauseFlags = 1

== 情境 2：撤銷並更換 operator（OP1 私鑰外洩）
  ✓ 2-1 Safe A setOperator(OP2) → operator = OP2
  ✓ 2-2 舊 operator enroll → revert Unauthorized()
  ✓ 2-3 舊 operator setPaused → revert Unauthorized()
  ✓ 2-4 新 operator enroll 另一個帳戶
  ✓ 2-5 新 operator 解除 → 解除不了 Safe 的暫停（pauseFlags = 1）
  ✓ 2-6 新 operator 重新 enroll 已 enroll 的帳戶 → revert AlreadyEnrolled(address)
  ✓ 2-7 新 operator 自己暫停 → pauseFlags = 3
  ✓ 2-8 新 operator 解除自己的 → pauseFlags = 1
  ✓ 2-9 Safe A 解除 → paused = false
  ✓ 2-10 帳戶恢復，executeRebalance 不再 revert

== 情境 3：Safe 交接（Safe A → Safe B，簽署人 #3 換成 #7）
  ✓ 3-1 Safe B 0x1EdD6B66E068a150F23025Dc1B90136f8fF7f46c（2-of-3：#1 #2 #7）
  ✓ 3-2 registry pendingOwner = Safe B
  ✓     router pendingOwner = Safe B
  ✓     接受前 registry owner 仍是 Safe A
  ✓ 3-3 非 Safe B 呼叫 registry acceptOwnership → revert NotPendingOwner()
  ✓     非 Safe B 呼叫 router acceptOwnership → revert NotPendingOwner()
  ✓ 3-4 registry owner = Safe B
  ✓     router owner = Safe B
  ✓     registry pendingOwner 清空
  ✓     router pendingOwner 清空
  ✓ 3-5 Safe A setOperator → revert NotOwner()
  ✓     Safe A setPaused → revert Unauthorized()
  ✓     Safe A setDefaultFeeBps → revert NotOwner()
  ✓     Safe A executor setFeeRecipient → revert NotOwner()
  ✓     Safe A router clearOracle → revert NotOwner()
  ✓     Safe A registry transferOwnership → revert NotOwner()
  ✓ 3-6 Safe B setFeeRecipient（executor 跟著 registry owner，不用另外交接）
  ✓     Safe B setOperator

== 情境 4：全域暫停（Safe 一筆停全部、一筆恢復）
  ✓ 4-1 部署後 globalPaused = false
  ✓ 4-2 operator 啟動全域暫停 → revert NotOwner()
  ✓     舊 Safe A 啟動全域暫停 → revert NotOwner()
  ✓ 4-3 Safe B setGlobalPaused(true) → globalPaused = true
  ✓ 4-4 帳戶 executeRebalance（未被逐帳戶暫停） → revert ExecutorPaused()
  ✓ 4-5 operator 解除全域暫停 → revert NotOwner()
  ✓ 4-6 Safe B setGlobalPaused(false) → globalPaused = false
  ✓ 4-7 恢復後 executeRebalance 不再 revert

== 情境 4 備案：逐資產拔價格來源（只停單一資產）
  ✓ 4-8 Safe B clearOracle(WBNB) → oracleOf(WBNB) = 0
  ✓ 4-9 USDT→WBNB 報價（所有帳戶的 WBNB swap 都停） → revert OracleNotSet(address)
  ✓ 4-10 Safe B setOracle 恢復（新 oracle 0xc2903F80Ada219b73328025cDf23daDe08a02d96），報價 152406269117717839

== 情境 5：買入額度與只准賣出模式（真的在 fork 上 swap）
  ✓ 5-1 部署後 maxBuyBps = 10000、numeraire = USDT
  ✓ 5-2 operator 改買入額度 → revert NotOwner()
  ✓ 5-3 帳戶持有 0.01 WBNB
  ✓ 5-4 Safe B setMaxBuyBps(0) → 只准賣出
  ✓ 5-5 買入 USDT→WBNB → revert BuyLimitExceeded(uint256,uint256)
  ✓ 5-6 賣出 WBNB→USDT 照常成交（得到 6.555140152971590208 USDT）
  ✓     賣出不計入額度（買入窗沒有打開）
  ✓ 5-7 Safe B setMaxBuyBps(10000) → 恢復
  ✓ 5-8 買入一半 USDT → 成交，buyAllowance 已用 = 買入金額
  ✓     額度 = 帳戶總值 6.555323016786556153 USDT，窗口到 1794592218
  ✓ 5-9 再買入一整個額度（超過） → revert BuyLimitExceeded(uint256,uint256)

演練全部通過。
```

## 這次沒演到

- 真實的 Safe 多簽流程（在 Safe 介面湊簽名、送交易）：演練用 impersonate 代替，合約端看到的 `msg.sender` 相同。
- 和 backend 一起演：operator 換鑰匙後後端是否正確切換、暫停後後端是否停止排程、排程是否照 `buyAllowance` 縮小買入。用真的 Kernel、session key、bundler 送 UserOp 的買入額度負面測試，由 X1 在 A3 做（#10 決定）。A3 跑通後再和 backend 一起演一次。
- seed 輪替程序（ROADMAP A6 的文件部分）不在本文件範圍。
