# 合約營運演練（ROADMAP A6，合約側）

## 白話摘要

合約上線後，平台有兩種「鑰匙」：

- **Safe**（多簽錢包，至少 2 個人一起簽才能動）：最高權限。可以換 operator、暫停任何帳戶、改手續費、換價格來源、把整個管理權交給另一個 Safe。
- **operator**（後端伺服器上的一把私鑰）：只能做日常的兩件事：幫使用者「加入策略」(enroll) 和「暫停／恢復」某個帳戶。動不到錢、手續費和管理權。

出事時要記住三件事：

1. **要暫停某個帳戶，先撤掉 operator，再暫停。** operator 可以解除暫停，也可以用「重新加入策略」把暫停清掉。如果懷疑 operator 的私鑰外洩，先暫停的話，對方可以馬上解除。
2. **使用者自己重新加入策略，也會清掉暫停。** Safe 的暫停只能擋住平台這一側，擋不住帳戶本人。
3. **目前沒有「一鍵全部停止」的開關。** 只能逐個帳戶暫停，或逐個資產拔掉價格來源（所有人那個資產的交易都會停）。

以下三個情境都在本機 BSC 主網 fork 上演過，腳本是 [`scripts/drill-ops-fork.sh`](../scripts/drill-ops-fork.sh)，全部 ✓。

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

## 情境 1：緊急暫停單一帳戶

**什麼時候用：** 某個帳戶的再平衡行為異常，或懷疑 operator 私鑰外洩。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 1-1 | Safe | registry `setOperator(0x0000…0000)` | `operator()` = 0，任何人都不再有 operator 權限 |
| 1-2 | Safe | registry `setPaused(帳戶, true)` | `enrollments(帳戶).paused` = true |
| 1-3 | （舊 operator 嘗試） | `setPaused(帳戶, false)` | revert `Unauthorized()` |
| 1-4 | （舊 operator 嘗試） | `enroll(帳戶, id)` | revert `Unauthorized()` |
| 1-5 | （帳戶嘗試） | executor `executeRebalance(帳戶, …)` | revert `Paused()` |

**順序不能反：** operator 可以 `setPaused(帳戶, false)` 解除暫停，`enroll` 也會把 `paused` 重設成 false。若先暫停、後撤 operator，兩筆 Safe 交易之間外洩的 operator 可以立刻解除暫停。先撤 operator 的代價是：在換上新 operator（情境 2）之前，後端無法幫任何人 enroll。

**注意：帳戶本人重新 `enroll` 會清掉暫停**（1-6）。`enroll` 允許 `msg.sender == account`，每次都寫入 `paused: false`。所以 Safe 的暫停只能擋住平台這一側（operator、後端），擋不住使用者自己從 smart account 重新加入策略。演練在 1-6 驗證了這個行為，1-7 由 Safe 再暫停一次。

**恢復：** 換上新 operator 後由 operator 或 Safe `setPaused(帳戶, false)`（見 2-5、2-6）。

## 情境 2：撤銷並更換 operator（relayer 私鑰外洩）

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 2-1 | Safe | registry `setOperator(新 operator)` | `operator()` = 新 operator |
| 2-2 | （舊 operator 嘗試） | `enroll(其他帳戶, id)` | revert `Unauthorized()` |
| 2-3 | （舊 operator 嘗試） | `setPaused(帳戶, false)` | revert `Unauthorized()` |
| 2-4 | 新 operator | `enroll(其他帳戶, id)` | `isEnrolled` = true |
| 2-5 | 新 operator | `setPaused(帳戶, false)` | `paused` = false |
| 2-6 | 帳戶 | `executeRebalance(帳戶, [], …)` | 不再 revert |

`setOperator` 是直接替換，不需要新 operator 接受。合約裡同時只有一個 operator，換上新的那一刻舊的就失效。後端要同時換成新私鑰（backend 的 `OPERATOR_PRIVATE_KEY`），否則 enroll 會一直失敗。

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

## 情境 4：緊急開關盤點

**目前沒有全域暫停。** executor 沒有 pause 函式，registry 只有逐帳戶的 `setPaused`（4-1 用 `forge inspect` 驗證）。要「全部停下來」，只有下面兩條路：

- 撤 operator（1-1）後逐個帳戶 `setPaused`，帳戶數多時要很多筆 Safe 交易；
- **逐資產拔價格來源：** Safe 對 router 送 `clearOracle(資產)`。之後所有帳戶涉及該資產的 swap 都會 fail closed（`OracleNotSet`）。

| 步驟 | 誰簽 | 呼叫 | 預期結果 |
| --- | --- | --- | --- |
| 4-2 | Safe | router `clearOracle(WBNB)` | `oracleOf(WBNB)` = 0 |
| 4-3 | （任何人） | router `previewSwap(USDT, WBNB, …)` | revert `OracleNotSet(address)` |
| 4-4 | Safe | router `setOracle(WBNB, 池子, 1800, 100, 3600)` | 部署一個**新的** oracle，報價恢復 |

**注意：** `clearOracle` 不是暫停開關。恢復時 `setOracle` 會部署新的 oracle 合約（地址會變），參數要照 `DeployAtpMainnet` 的同一組重填（池子、30 分鐘 TWAP、slippage、1 小時 age）。7 個資產全停就要 7 筆 Safe 交易，恢復也要 7 筆。

## 演練輸出（2026-11-12，fork block 133187577，42 秒）

```
== 準備：部署 v2 並交給 Safe A（與主網同一支 DeployAtpMainnet）
  ✓ Safe A 0xC5A6CFacA6BE8dB9D011F17666E729B560265Ca0（2-of-3：#1 #2 #3）
  ✓ registry 0x891d13a0a03bb7c435bc7b7c2242f2c2982b6733 / router 0x61df85c020f21e320b9889f9afd71a7176551818 / executor 0xcd8a3ae15dff0fc218473ca58d00f4b49b6414a9
  ✓ registry owner = Safe A
  ✓ router owner = Safe A
  ✓ operator = OP1
  ✓ 帳戶已 enroll、未暫停
  ✓ 帳戶可以呼叫 executeRebalance（空步驟）

== 情境 1：緊急暫停單一帳戶（順序：先撤 operator，再暫停）
  ✓ 1-1 Safe A setOperator(0) → operator = 0
  ✓ 1-2 Safe A setPaused(帳戶, true) → paused = true
  ✓ 1-3 舊 operator 解除暫停 → revert Unauthorized()
  ✓ 1-4 舊 operator 重新 enroll（會清掉暫停） → revert Unauthorized()
  ✓ 1-5 帳戶 executeRebalance → revert Paused()
  -- 注意：帳戶本人重新 enroll 會清掉暫停
  ✓ 1-6 帳戶自己 enroll → paused = false（Safe 的暫停被帳戶本人解除）
  ✓ 1-7 Safe A 再暫停一次 → paused = true

== 情境 2：撤銷並更換 operator（OP1 私鑰外洩）
  ✓ 2-1 Safe A setOperator(OP2) → operator = OP2
  ✓ 2-2 舊 operator enroll → revert Unauthorized()
  ✓ 2-3 舊 operator setPaused → revert Unauthorized()
  ✓ 2-4 新 operator enroll 另一個帳戶
  ✓ 2-5 新 operator 解除帳戶暫停 → paused = false
  ✓ 2-6 帳戶恢復，executeRebalance 不再 revert

== 情境 3：Safe 交接（Safe A → Safe B，簽署人 #3 換成 #7）
  ✓ 3-1 Safe B 0xD0BA62DcCbf6FDfD98b9488e3EaF4AC0ca962427（2-of-3：#1 #2 #7）
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

== 情境 4：緊急開關盤點
  ✓ 4-1 executor 沒有全域暫停；registry 只有逐帳戶 setPaused
  ✓ 4-2 Safe B clearOracle(WBNB) → oracleOf(WBNB) = 0
  ✓ 4-3 USDT→WBNB 報價（所有帳戶的 WBNB swap 都停） → revert OracleNotSet(address)
  ✓ 4-4 Safe B setOracle 恢復（新 oracle 0xc2903F80Ada219b73328025cDf23daDe08a02d96），報價 153292749463350088

演練全部通過。
```

## 這次沒演到

- 真實的 Safe 多簽流程（在 Safe 介面湊簽名、送交易）：演練用 impersonate 代替，合約端看到的 `msg.sender` 相同。
- 和 backend 一起演：operator 換鑰匙後後端是否正確切換、暫停後後端是否停止排程。A3 跑通後再和 backend 一起演一次。
- seed 輪替程序（ROADMAP A6 的文件部分）不在本文件範圍。
