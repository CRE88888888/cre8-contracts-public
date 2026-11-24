# 策略加息動態路由 v2（合約介面與規則）

> 介面版本：**v2.0-draft6（2026-11-25）**。改介面時在這裡往下加一行。
>
> **draft6（第三輪審查的修正，對照表在 §16；ABI 完全沒變，變的是下面兩個行為。這一版還沒部署：測試網 chain 97 上跑的仍是 draft5 的程式）：**
> 1. Venus→Venus 的 `executeMigrate` 現在也會被 `ForeignDebt` 擋下（draft5 的檢查在這條路徑上永遠通過）。帳戶自己的負債不受影響。
> 2. `lens.routeDebt`：某個幣在 Venus 的本金已經是 0、只剩利息零頭時，整筆只歸給帳戶在這個幣的**第一個** Venus 部位（`accountRoutes` 的順序），同幣其他路線回 0；帳戶在這個幣沒有 v2 的 Venus 部位（外來負債）時每條都回 0。draft5 是每條都回整筆。**後端算帳戶負債用 `tokenDebt(account, token)`，不要加總 `routeDebt`**（兩版都適用，見 §5）。
> 3. 主網 `verify()` 一定要帶 `ATP_EXECUTOR`，而且必須是 `deployments/mainnet.json` 記的核心（§13）。
>
> **draft5（複審的修正，對照表在 §15；ABI 只多了唯讀函式，draft4 的呼叫都不用改）：**
> 1. lens 新增 `minDebt(routeId)`：部分還款後最少要留下的負債（`minLoan` × 1.01；Venus 是 0）。Lista 部位的負債 ≤ 這個數、策略盒的錢又不夠全還時，第三方的 `executeDeleverage` 一毛都還不了，**後端要自己補錢全還或關掉**（做法在 §5「小額部位」）。
> 2. executor 與 lens 新增唯讀的 `venusComptroller()`、`moolah()`（部署後驗證用）。
> 3. 被拿掉分級（`Tier.NONE`）的資產可以分批退出：每一步只要健康度不下降就可以（draft4 要求先全部還清）。只拿抵押不還款仍然會被擋。
> 4. `ForeignDebt` 的條件改成「帳戶在 Venus 欠這個幣，但在 v2 沒有這個幣的 Venus 部位」。本金還完、只剩利息零頭的自己的部位不再被誤擋。
> 5. `executeRescue` 合約分不出 owner 與 session key，**靠後端與 paymaster 的規則擋**，寫在 §4。
>
> **draft4（獨立審查的修正，對照表在 §14；後端要改的在前五點）：**
> 1. 新增 `executeRescue(account, vaultId, deadline)` 與事件 `Rescued`：vault 或 adapter 壞掉時，該幣別沒有負債就把策略盒裡的份額原樣送回帳戶。**不要放進 session key 的允許清單**（owner 才該送）。
> 2. 策略盒裡現在可能有「閒置的借款幣」（不在任何 vault）：lens 新增 `idleOf(account, token)`。**算淨值要加上它**；下一次還款會先用它，放回時一起付回帳戶。
> 3. `executeDeleverage` 只剩健康度減倉線一個觸發條件（vault 使用率 > 95% 不再讓外人觸發，改由後端用 `executeReduce`／`executeSwitchVault` 處理）；vault 的錢比要還的少時，還它有的，並且至少留下 Moolah 最低借款額的 1.01 倍，不會再 revert。
> 4. `executeSwitchVault` 現在要通過目的 vault 的存款條件（鏈上讀得到的使用率 ≤ 90%、enrollment 沒暫停）。
> 5. `routeLines(routeId)` 從 registry 搬到 lens；registry 新增錯誤 `ForeignDebt`（帳戶在 Venus 有不是 v2 開的負債時不能開 Venus 路線，見 §12 的 v1／v2 規則）。executor 新增唯讀的 `extension()`、`boxImplementation()`。
> 6. 取回抵押的放寬條件加嚴：負債÷預算不變高，**而且健康度不變低**（§5）。（draft4 另外要求「原本就有預算」，draft5 拿掉了：拿掉分級的資產可以分批退出。）
> 7. 單純還款完全不讀價格；沒有負債時取回抵押也不讀價格（oracle 掛掉時仍然還得了、拿得回）。
> 8. 策略盒的 ERC-1271 只留一種形式：`isValidSignature(bytes32,bytes)`＋EIP-191 雜湊（主網實測 Lista 只用這一種，§9）。
> 9. executor 的程式拆成兩半（主體＋`AtpBorrowExecutorV2Extension`，以 delegatecall 執行）：**地址、ABI、session key 的 target 都不變**。
> 10. 每個動作最多呼叫 Lista vault 一次；ERC4626 vault 要有至少 1,000 顆存量才能登記，每筆存入都驗證入帳價值。
>
> **draft3（使用者決定）**在下一段。
>
> **draft3（使用者決定）：借款市場使用率上限的預設值從 85% 改成 95%**（`MAX_BORROW_UTILIZATION_BPS = 9500`，新路線的 `Route.maxUtilizationBps` 預設 9500）。ABI 沒有變；owner 仍可逐條路線用 `setRouteMaxUtilization` 調高或調低。
> 機器可讀版：`docs/borrow-routing-v2.interface.json`（ABI 由 `src/atp/borrow/v2/I*.sol` 產生，兩邊一致）。
>
> **draft2 相對 draft1 改了什麼（後端請照這份）：**
> 1. **讀取搬到新合約 `AtpBorrowLensV2`**（地址 `executor.lens()`）：`routeStatus`、`vaultStatus`、`quote`、`health`、`debt`、`routeDebt`、`tokenDebt`、`collateral`、`targetLtv`／`deleverageLtv`／`liquidationLtv`，另加 `minLoan`、`deleverageAmount`、`borrowMarket`。原因是 registry 超過 24 KB 合約大小上限。registry 只留設定、同意、記帳與 `routeOpen`／`vaultOpen`／`routeLines`／`freshReport`。
> 2. **策略盒支援 ERC-1271，但只認一種訊息**（Lista 領激勵要簽的登入文字），見 §9。
> 3. 新增任何人可呼叫的 `collectRewards(account, token)`：策略盒 → 帳戶。`executeSweepRewards` 保留給退出時用。
> 4. `Opened` 事件最後一欄 `ltv` 改成 `debtValue, budgetValue` 兩欄；`VaultStatus` 多 `since`；registry 多 `vaultSince(account, vaultId)`。
> 5. 每條路線有自己的借款市場使用率上限 `Route.maxUtilizationBps`（draft2 預設 8500，draft3 起預設 9500；owner 用 `setRouteMaxUtilization` 改），原因見 §6。
> 6. 取回抵押／搬家的檢查從「一定要在目標內」放寬成「在目標內，或負債÷預算沒有比動作前更高」，見 §5。
> 7. executor 建構子改成 `(registry, lens)`；三個合約由單次使用的 `RoutingV2Deployer` 依序建立（部署腳本處理，後端不受影響）。
> 8. `executeDeleverage` 在 vault 的錢比該還的少時，改成「還它有的全部」而不是 revert；回傳實際還款額。
> 9. 一筆還款讓帳戶在該借款幣的負債歸零時（`executeReduce` 或 `executeMigrate` 的舊路線），會把指定 vault 的存款一次領完，超過負債的部分同一筆付回帳戶（`Released` 事件）。
> 10. `executeRelease`／關閉時的放回，也會把直接進到策略盒的同幣現金一起付回帳戶。

狀態：v2 是**新合約**，放在 `src/atp/borrow/v2/`，不改已部署的 v1（`AtpBorrowExecutor`／`AtpBorrowRegistry`）。測試網（chain 97）已於 2026-11-25 部署（地址在 §12 與 `deployments/testnet-97.json` 的 `borrowV2`），跑的是 draft5 的程式（commit `1888572`）；draft6 的修正還沒部署到任何鏈。主網還沒部署。

## 1. 跟 v1 差在哪

| | v1（chain 97 現況） | v2 |
| --- | --- | --- |
| 借什麼 | 只有 USDT | USDT／USDC／USD1／U（owner 白名單 `setLoanToken`），借 X 存 X，不換幣 |
| 路線 | 一個資產固定一個市場（`collateralMarket`） | 同一資產可以有多條路線（場所 × 借款幣 × Lista 市場），開倉時由後端挑；合約只管白名單與安全線 |
| 存款 vault | 一個市場綁一個 Lista 風格 vault | vault 另外登記（Lista ERC4626 vault、Venus vToken、Aave v3），開倉時跟路線分開指定，只要幣別相同 |
| vault 份額放哪 | 投資組合帳戶自己持有（§7 漏洞：舊 `AtpExecutor.executeWithdraw` 贖得走） | 每個帳戶一個「策略盒」`StrategyBox`（executor 用 CREATE2 建的最小 clone），份額只在盒子裡，只有 v2 executor 能動；`AtpExecutor` 與 session key 都碰不到 |
| vault 份額歸屬 | 每個市場各記各的 | 同一帳戶、同一個 vault 合併成一池（都是這個投資組合的策略錢）。任何一條同幣別路線的還款都可以用它 |
| 同意 | 每個市場一次 `setBorrowPolicy`，綁 strategyId＋version | 帳戶一次 `setStrategyPolicy(maxDebt, rewardRecipient, enabled)`，涵蓋白名單上所有路線；只綁 strategyId |
| Venus | 每個市場各自算 LTV，共用負債會互卡 | 整個帳戶一起算：負債價值 ≤ Σ(各抵押品價值 × 各自目標 LTV) |
| 搬家 | 沒有 | `executeMigrate` 一筆完成；`executeSwitchVault` 只換存款 vault |
| 利差檢查 | 只讀得到模擬利率 | 鏈上讀得到的直接讀（借款利率、Venus／Aave 存款利率）；讀不到的（Lista vault 利率、LISTA／XVS 激勵）由 `rateReporter` 回報，48 小時過期 |
| 負利差、vault 使用率過高 | 任何人可以收掉 | 只有帳戶自己（後端用 session key）處理；任何人可觸發的只剩健康度減倉線 |
| 激勵代幣 | 無 | `collectRewards`（策略盒 → 帳戶，任何人）、`executeSweepRewards`（退出時 → owner 指定地址） |

## 2. 合約

| 合約 | 用途 | 大小 |
| --- | --- | --- |
| `AtpBorrowExecutorV2` | 唯一搬錢的合約，永久綁定 registry、lens 與 extension，建構時建立策略盒實作。自己實作開倉、還款／關閉、減倉、搬家；其他進入點經 fallback 以 delegatecall 交給 extension | 18.4 KB |
| `AtpBorrowExecutorV2Extension` | executor 的另一半程式：換 vault、放回、救援、激勵。沒有狀態、沒有 immutable，只能被 executor 以 delegatecall 執行（直接呼叫會 revert） | 6.4 KB |
| `AtpBorrowRegistryV2` | 白名單（借款幣、路線、vault、adapter、激勵代幣）、同意、上限、LTV 線設定、利率回報、記帳 | 24.2 KB（上限 24,576，剩 389 bytes） |
| `AtpBorrowLensV2` | 所有讀取：部位、健康度、LTV 線、開倉條件、狀態快照；executor 的健康度、開倉、減倉計畫檢查也用它 | 22.2 KB |
| `StrategyBox` | 每個帳戶一個，只收 vault 份額（Lista vault share／vToken／aToken）與它們的激勵。只有 executor 能叫它 approve 或送出代幣 | 2.8 KB |
| `Erc4626VaultAdapter`／`VenusVaultAdapter`／`AaveVaultAdapter` | 三種存款場所，同一個介面 `IStrategyVaultAdapter`。無狀態、只聽 executor。每種 kind 只能設一次（`setAdapter`） | 2.5–4.9 KB |
| `RoutingV2Deployer` | 只用一次的部署器：用自己的 nonce 1、2、3 依序建立 registry、lens、executor，所以 executor 地址在部署器上鏈時就固定 | 2.1 KB |

## 3. 識別碼

```
routeId = keccak256(abi.encode(uint8 venue, address collateral, address loan, bytes32 listaId))
          venue: 1 = VENUS, 2 = LISTA；Venus 的 listaId = 0x0
vaultId = keccak256(abi.encode(uint8 kind, address token, address target))
          kind: 1 = ERC4626（Lista vault，target = vault）、2 = VENUS（target = vToken）、3 = AAVE（target = Pool）
```

`registry.routeIdOf(...)`、`vaultIdOf(...)` 是同一個算法的 pure 函式。Lista 的 `listaId` 就是 Moolah 的 market id（`api.lista.org` 的 `id`）。Venus 的 vToken 由 owner 用 `setVenusMarket(underlying, vToken)` 登記，不進 routeId。

策略盒地址：`executor.boxOf(account)`（CREATE2，salt = account；第一次存款時才部署）。

## 4. 誰簽什麼

**帳戶 owner 簽一次（sudo）：**

1. `registry.setStrategyPolicy(maxDebt, rewardRecipient, true)`
   - `maxDebt`：這個帳戶所有路線的本金上限，18 位小數的美元（每種借款幣都當 1 美元；四種幣在 BSC 都是 18 位，等於直接加總）。
   - `rewardRecipient`：退出時激勵代幣要送去的地址（通常是用戶錢包）；填 0 表示只會從策略盒搬回帳戶。
2. Venus：`comptroller.updateDelegate(executor, true)`；Lista：`moolah.setAuthorization(executor, true)`。
3. 抵押品代幣 `approve(executor, max)`（每個會拿去抵押的資產）。
4. 選用：借款幣 `approve(executor, …)`，讓還款在 vault 不夠時可以用帳戶自己的同幣現金（`maxCashIn`）；激勵代幣 `approve(executor, …)`，讓 `executeSweepRewards` 能把帳戶裡的 LISTA／XVS 送走。

不需要 approve 任何 vault 份額（份額在策略盒，不在帳戶）。**不要**把 v2 的任何東西 approve 給舊的 `AtpExecutor`。

**同意綁 strategyId（選了保留綁定）：** My-mix 改比例會把帳戶 enroll 到新的私人策略（新 strategyId），同意就失效。處理方式是在**同一個 UserOp 裡、enroll 之後接著呼叫 `setStrategyPolicy`**（那個 UserOp 本來就是 owner 簽的，不多一次簽名）。沒有做成「同一個 owner 換策略自動沿用」：合約看不到 Kernel 帳戶的 owner 是誰，要沿用就只能完全不綁，等於同意一次永久有效到任何策略；保留綁定比較保守，而且漏接時只會停新開倉。同意失效或停用期間，**所有退出照常**：`executeReduce`、`executeRelease`、`executeDeleverage`、`collectRewards`、`executeSweepRewards` 都不檢查同意（有測試 `test_consent_voidAfterReEnroll_everyExitStillWorks_thenReconsent`）；被擋的只有 `executeOpen`、`executeMigrate`、`executeSwitchVault`。

**session key 可以呼叫的（target = `AtpBorrowExecutorV2`，第一個參數 `account` 必須是自己）：**
`executeOpen`、`executeReduce`、`executeMigrate`、`executeSwitchVault`、`executeRelease`、`executeSweepRewards`。
**`executeRescue` 只給 owner，這是後端與 paymaster 要守的規則，合約擋不了：** 合約只檢查 `msg.sender == account`，分不出這筆 UserOp 是 owner 簽的還是 session key 簽的。所以 (1) session key 的 CallPolicy 允許清單**不可以**有 `executeRescue` 的 selector；(2) paymaster **不代付**帶這個 selector 的 UserOp（除非是 owner 簽的救援流程）；(3) 後端的 operator 永遠不送它。它把策略盒的份額變成帳戶的一般持股（之後舊的 `AtpExecutor` 流程就碰得到），是 vault 或 adapter 壞掉時 owner 的最後手段。就算規則沒守住，它也只在該幣別沒有負債時才會成功，份額只會到帳戶本身。

**任何人都能呼叫（不用 session key、沒有 deadline，operator 可以批次送）：** `executeDeleverage`、`collectRewards`、`registry.reconcile`、lens 的 `sync`。

session key **不應該**被允許：`setStrategyPolicy`、Venus `updateDelegate`、Moolah `setAuthorization`、任何 `approve`、`executeRescue`。

**session key 與帳戶的 ERC-1271（後端要處理，不在這個 repo）：** 在測試網一個真實的投資組合帳戶上實測（`test/atp/fork/SessionKey1271Fork97.t.sol`）：目前安裝的 session 權限（ECDSA signer＋CallPolicy v0.0.4＋GasPolicy＋TimestampPolicy，旗標都是 0）**擋不住簽名**。三個 policy 對任何雜湊、任何請求者的 `checkSignaturePolicy` 都回 0，權限本身也沒有標成「不能用於簽名」，所以持有 session key 的人可以讓帳戶的 `isValidSignature` 對任意雜湊回傳有效。策略盒不受影響（它只認 Lista 那段文字）。帳戶本身目前沒有 approve 給 Permit2（實測 allowance 是 0），所以還沒有可以直接利用的地方，但任何接受帳戶 ERC-1271 簽名的協議都會把 session key 當成 owner。建議 session 權限加上簽名 policy（不允許任何請求者）或把權限標成不能用於簽名。

## 5. 動作

金額都是該代幣的最小單位；`type(uint256).max` 表示全部。帶 `deadline` 的都要 `msg.sender == account`。

| 動作 | 呼叫 | 說明 |
| --- | --- | --- |
| 開倉／加碼 | `executeOpen(account, routeId, vaultId, collateralAmount, borrowAmount, deadline)` | 抵押＋借款＋存進 vault 一筆完成。兩個金額可以其中一個是 0（只補抵押時 `vaultId` 填 0）。借款幣不會以現金出現在帳戶 |
| 還款／部分關閉／關閉／取回抵押 | `executeReduce(account, routeId, vaultId, repayAmount, withdrawAmount, maxCashIn, deadline)` | 先用策略盒在 `vaultId` 的存款還，不夠再用帳戶自己的借款幣（最多 `maxCashIn`）；`vaultId` 填 0 表示只用帳戶現金。之後取回 `withdrawAmount` 抵押。全關＝`(max, max)`。結束時帳戶在這個借款幣已經沒有負債，`vaultId` 剩下的錢會付回帳戶（vault 當下領不出來就留在策略盒，之後 `executeRelease`） |
| 自動減倉 | `executeDeleverage(account, routeId, vaultId, maxRepay)` | 任何人可呼叫。只有一個觸發條件：負債價值 ≥ 減倉線。用策略盒的錢（閒置的借款幣＋`vaultId` 的存款）還到回到目標線；盒裡的錢比要還的少就還它有的，但一定留下不低於場所最低借款額 1.01 倍的負債（不會因為剩零頭而 revert）。`maxRepay` 是上限。回傳實際還了多少 |
| 搬家 | `executeMigrate(account, fromRouteId, fromVaultId, toRouteId, toVaultId, borrowAmount, maxCashIn, deadline)` | 見 §7 |
| 只換存款 vault | `executeSwitchVault(account, fromVaultId, toVaultId, amount, deadline)` | 同幣別，從 A vault 領出直接存 B vault。不影響負債與健康度。目的 vault 要通過存款條件：開著、鏈上讀得到的使用率 ≤ 90%、同意有效且 enrollment 沒暫停。離開一個超過使用率的 vault 永遠可以 |
| 放回剩餘 | `executeRelease(account, vaultId, deadline)` | 該幣別已無負債時，把策略盒在這個 vault 的全部存款付回帳戶 |
| 救援 | `executeRescue(account, vaultId, deadline)` | vault 或 adapter 壞掉時的最後手段：該幣別沒有負債時，把策略盒裡這個 vault 的份額（vault share／vToken／aToken）**原樣**轉回帳戶，完全不呼叫 vault。owner 用，不給 session key |
| 收激勵 | `collectRewards(account, token)` | 任何人可呼叫。策略盒裡的激勵代幣 → 帳戶 |
| 退出時送出激勵 | `executeSweepRewards(account, token, accountAmount, deadline)` | 見 §9 |

沒有任何函式有收款人參數。錢只會在：帳戶 ↔ 借貸場所（抵押／負債）、借貸場所 → 策略盒的 vault、vault → 還款或回帳戶。激勵代幣只能到帳戶本身，或退出時到 owner 簽過的 `rewardRecipient`。

**部位只會經由這些事件改變（後端算「持有多久」可以用，鏈上也有 `openedAt`／`vaultSince`）：**
- 路線：`Opened`、`Reduced`、`Deleveraged`、`Migrated`（舊路線結束、新路線開始）。`registry.openedAt(account, routeId)` 是這個部位第一次借款的時間，本金歸零就清掉；搬家後新路線的 `openedAt` 是搬家當下。
- 策略盒的 vault：存入只有 `Opened`、`Migrated`（`toVaultId`）、`VaultSwitched`；領出有 `Reduced`、`Deleveraged`、`Migrated`（`fromVaultId`）、`VaultSwitched`、`Released`。`registry.vaultSince(account, vaultId)` 是策略盒在這個 vault 從空變成有的時間，清空就歸零。
- 合約不強制遲滯（負利差、市場暫停要能立刻處理），只提供這兩個時間。

### 風險檢查：在預算內，或沒有變更糟

`budgetValue` ＝ 抵押價值 × 目標 LTV（Venus 是整個帳戶加總）。

- **新增負債（`executeOpen` 借款、`executeMigrate` 的新路線）：** 結束時 `debtValue ≤ budgetValue`，沒有例外。
- **取回抵押（`executeReduce`、搬家後留在 Venus 的其他部位）：** 結束時 `debtValue ≤ budgetValue`；**或**同時滿足兩件事：`debtValue ÷ budgetValue` 不高於動作前、健康度（清算價值 ÷ 負債價值）不低於動作前。後面這組是給已經被利息或價格推過目標線的部位用的：還多少、拿多少，就可以縮小。只拿抵押不還款一定會被擋；在 Venus 上把抵押品換成場所估值較低的那種（負債÷預算不變但健康度下降）也會被擋。被拿掉分級（`Tier.NONE`，預算是 0）的資產不能再開倉、加碼，但可以分批退出：每一步還款的比例至少要跟取回抵押的比例一樣（健康度不下降），例如還一半、拿一成可以，還一成、拿一半不行。
- 單純還款不檢查，也**完全不讀價格**：oracle 讀不到價格時還款照常。沒有任何負債的部位取回抵押也不讀價格。會讀價格、所以 oracle 掛掉時會失敗的只有：新借款、有負債時取回抵押、搬家、減倉（它必須知道健康線）。

**策略盒裡的錢有兩種：** vault 的份額，和偶爾出現的「閒置借款幣」（直接放在盒裡）。閒置的來源：Lista vault 的份額換算用的是 vault 上次記帳的總額，領出來可能比要的多一點點；減倉時為了不低於最低借款額而少還的部分。閒置的錢跟 vault 存款一樣是策略錢：下一次還款先用它，`executeRelease`／關閉時一起付回帳戶，`lens.idleOf(account, token)` 讀得到。

### Venus：整個帳戶一起算

Venus 的負債按借款幣記在帳戶上（同一個幣只有一筆），健康度是整個帳戶。

- **預算** `budgetValue` ＝ Σ(該帳戶每個 Venus 抵押品的價值 × 它的目標 LTV)。沒在 v2 登記、或沒有分級的抵押品預算算 0。
- **減倉線** `deleverageValue` ＝ Σ(價值 × 減倉 LTV)。`debtValue ≥ deleverageValue` 時任何人可減倉；要還哪個幣的負債由呼叫者選路線（`routeId` 的借款幣）與該幣的 vault。
- `lens.debt(routeId, account)` 回傳帳戶在這個借款幣的**整筆**負債；`lens.routeDebt(routeId, account)` 是按 principal 比例分給這條路線的部分（這個幣別只剩這條路線有 principal 時＝整筆）。`executeReduce` 的 `repayAmount = max` 還的是 `routeDebt`。
- **本金歸零、只剩利息零頭時**（例如還款金額剛好等於本金、或減倉還掉了全部本金）：這個幣的整筆負債只算在帳戶第一個這個幣的 Venus 部位上（`accountRoutes` 裡排最前面的那條），同幣其他路線的 `routeDebt` 是 0。對 `routeDebt` 是 0 的路線送 `repayAmount = max` 不會還任何錢（沒有同時取回抵押就 `NothingToRepay`）。要清掉零頭：對 `routeDebt` 不是 0 的那條送 `max`，或在任何一條同幣路線上傳明確金額（上限是 `debt()`）。帳戶在這個幣沒有任何 v2 的 Venus 部位時（負債不是 v2 開的），每條路線的 `routeDebt` 都是 0。
- **後端怎麼讀負債：** 帳戶在某個幣的總負債用 `lens.tokenDebt(account, token)`（Venus 加上清單裡的 Lista 部位）；只看 Venus 那一筆就用任何一條該幣路線的 `debt()`。**不要把各路線的 `routeDebt` 加起來當成帳戶負債**：比例是向上取整的（n 條路線加起來最多多 n−1 個最小單位），而且測試網目前部署的 draft5 lens 在本金歸零時每條同幣路線都回整筆，加總會重複計算。`routeDebt` 只用來知道「這條路線送 `max` 會還多少」與顯示各路線的份額。
- 同一個抵押品的多條 Venus 路線（只差借款幣）共用同一批 vToken；`accountRoutes` 只會留一筆有 principal 的。

**關閉兩個以上 Venus 部位（對應 backend #252）：** vault 現在是合併的，不需要「誰的 vault 最大誰收尾」。

- 每條路線各借到自己的目標（後端平常的開法）：依序對每條路線送 `executeReduce(account, route_i, vault, max, max, maxCashIn, deadline)`。每一筆還它自己的份額、取回它的抵押，留下的部位比例不變；最後一筆把負債還清並把 vault 剩餘付回帳戶。
- 各路線借的比例不一樣（例如 A 借滿、B 只借一點）而先關 B：只還 B 的份額會讓 A 比動作前更靠近（或超過）預算，這筆會 `LtvTooHigh`。改傳明確的 `repayAmount`（上限是 `debt()` 整筆），或先關借得多的那條。後端照 #252 的算法算「留下的抵押需要還多少」即可，還款來源不用再分 vault。
- 只關其中一個也是同一個呼叫。

### Lista：每個市場獨立

`debt` 與 `routeDebt` 相同。Moolah 有最低借款額（`lens.minLoan(routeId)`，主網目前約 15 美元等值）：開倉借的金額、部分還款後剩下的負債都不能低於它，否則 Moolah 會 revert；`executeDeleverage` 算出來的金額若會留下低於它的零頭，會改成全還。

**小額部位（後端要處理）：** `lens.minDebt(routeId)` 是部分還款後最少要留下的負債（`minLoan` × 1.01，1% 是留給接下來幾個區塊的利息；Venus 路線是 0）。兩個後果：
- 還款的錢不夠全還、又會留下低於 `minDebt` 的負債時，合約會少還一點，讓剩下的負債剛好是 `minDebt`；多領出來的錢留在策略盒當閒置（`lens.idleOf`，主網約 15 美元以內），下次還款先用它。
- **負債本身 ≤ `minDebt` 的部位只能一次全還。** 第三方的 `executeDeleverage` 只能用策略盒的錢；盒裡的錢（各 vault 的 `assets`＋`idleOf`）比負債少時它什麼都還不了（`VaultShortfall`），這是 Moolah 的規則，合約繞不過去。這種部位要由後端自己處理：用 `executeReduce(account, routeId, vaultId, MAX, 取回數量, maxCashIn, deadline)` 帶帳戶裡的同幣現金補足差額一次還清，或直接關閉。
- 後端的檢查式（每個 Lista 部位）：`routeDebt ≤ minDebt(routeId)` 而且 `vaultStatus(vaultId).assets + idleOf(account, token) < routeDebt` → 這個部位第三方救不了，排進「補錢全還或關閉」。金額很小（≤ 約 15 美元的負債對應的抵押），但健康度一樣會隨價格變差，不要放著。

## 6. 安全線與開倉條件

F ＝ Venus collateral factor／Lista LLTV。

| 規則 | 值 |
| --- | --- |
| 目標 LTV | min(類別上限, F/2, owner 設的更保守值)；類別（`setAssetTier`，跟著抵押品走）：指數與大型股 35%、一般個股 30%、跟幣價連動 20%。沒有類別的資產不能開 |
| 減倉線 | min(F × 2/3, owner 設的更保守值) |
| 借款市場使用率 | 借完超過該路線的上限就不借。預設 95%，owner 可以逐條路線改（`setRouteMaxUtilization`）。還款、減倉、取回抵押不受影響 |
| vault 使用率 | > 90% 不存新錢（開倉、搬家、換 vault 都擋）。> 95% 時 `vaultStatus.shouldExit` 為 true，由後端用 session key 換 vault 或還款；**不開放任何人觸發**（使用率在同一個區塊內可以被人為推高）。只在鏈上讀得到時適用（Venus、Aave）。Lista vault 的提領佇列有 22–142 個市場，鏈上算不動，由後端判斷 |
| 利差 | `vaultRate + vaultIncentive + borrowIncentive < borrowRate` 不借（`NEGATIVE_CARRY`）。vault 利率鏈上讀不到又沒有 48 小時內的回報：不借（`VAULT_UNREADABLE`） |
| 同意 | `policy.enabled`、帳戶已 enroll 且未暫停、strategyId 相符；帳戶本金合計 ≤ `maxDebt` |
| CRE8 上限 | 每條路線本金上限 `borrowCap`（借款幣最小單位） |
| 每帳戶部位數 | 最多 24 條路線、24 個 vault |
| 暫停 | `registry.setPaused`、路線／vault 停用或退休、借款幣或類別被拿掉、`AtpExecutor.globalPaused` 只擋新增（開倉、搬家、換 vault）。還款、減倉、取回抵押、放回剩餘、激勵永遠開著 |

**借款市場使用率上限為什麼是 95%（使用者 2026-11-24 決定）：** v1 測試網用的是 85%。Lista 的利率模型把市場導向約 90% 使用率，2026-11-24 實測 NVDAB/USD1 是 92.7%、TSLAB/USDC 80.7%、QQQB/USDC 63.9%、QQQB/USD1 58.6%，照 85% 一刀切主力市場開不了。預設改成 95%：92.7% 的市場可以開，借完會超過 95% 的不借（測試 `test_borrowUtilization_default95_openAt927_blockedAbove95_exitsUnaffected`）。

**利率回報 `reportRates(routes[], vaults[])`（`rateReporter`，後端 operator）：**
- 路線回報借款激勵、抵押激勵；vault 回報基礎利率（只有鏈上讀不到的 Lista vault 會用到）與激勵。每項上限 50%。
- 一筆回報用 48 小時，過期後激勵當 0、Lista vault 利率當未知（該 vault 暫時不能開新倉；已開的不受影響，也不會因此被任何人收掉）。
- 建議頻率：每 12 小時一次，另外在數字變動超過 0.25% 時補一次。40 條路線＋10 個 vault 一筆 322,052 gas（測試 `test_reportRates_onlyReporter_bounded_andBatchGas`，上限斷言 100 萬），一筆交易放得下。

讀取（都在 `AtpBorrowLensV2`，用 eth_call，會先 accrue）：

- `quote(routeId, vaultId)` → `gate`（0 可開）、目標 LTV、借款利率、兩邊激勵、vault 利率、`carry`。
- `routeStatus(routeId, account)` → 利率、使用率、可借流動性、剩餘上限、三條 LTV 線、部位（抵押、負債、`routeDebt`、principal、`openedAt`）、`shouldDeleverage`、`health`。`account` 可以是 0。
- `vaultStatus(vaultId, account)` → 存款利率（`rateOnChain` 表示是不是鏈上讀的）、激勵、使用率、策略盒在這個 vault 的存款 `assets`、`since`、`shouldExit`。
- `deleverageAmount(routeId, account)`、`minLoan(routeId)`、`minDebt(routeId)`、`idleOf(account, token)`、`tokenDebt(account, token)`、`borrowMarket(routeId)`。
- registry：`accountRoutes(account)`、`accountVaults(account)`、`policy(account)`、`accountPrincipalUsd(account)`、`principal`、`openedAt`、`vaultSince`、`route`／`vault`、`routeOpen`／`vaultOpen`。

淨值仍由後端算：抵押價值 ＋ 策略盒各 vault 的 `assets` − 負債。

## 7. 搬家：哪些一筆完成、哪些要兩步

`executeMigrate` 的順序：從 `fromVault` 領出 → 還清舊路線（Venus：還這條路線的份額）→ 取回舊路線全部抵押 → 抵押到新路線 → 在新路線借 `borrowAmount` → 存進 `toVault`。整筆交易任何一步失敗就全部還原。過程中舊路線只會變安全（先還再取），新路線從 0 借到不超過目標；結束時新路線一定在預算內，並通過所有開倉條件（同意、上限、利差、使用率）。抵押品從舊場所經 executor 直接進新場所，不經過帳戶；沒有任何一步讓代幣停在帳戶或 executor。

| 情況 | 做法 |
| --- | --- |
| 同借款幣、換場所（Venus ↔ Lista）或換 Lista 市場 | 一筆 `executeMigrate` |
| 換借款幣（借 X → 借 Y），舊 vault 的 X（加上 `maxCashIn` 內的帳戶現金）夠還舊負債 | 也是一筆：X 的負債用 X 的 vault 還，新路線借 Y 存 Y 的 vault，**不需要換幣**。帳戶在 X 已經沒有別的負債時，X vault 多出來的利息在同一筆付回帳戶（`Released` 事件）；還有別的 X 負債就留在策略盒 |
| 同路線、只換存款 vault | 一筆 `executeSwitchVault` |
| Venus → Venus 同抵押品、只換借款幣 | 一筆 `executeMigrate`（抵押品不動） |
| 舊 vault 的錢不夠還舊負債（減倉過、或利差是負的），帳戶同幣現金也補不滿 | **兩步**：`VaultShortfall` 整筆還原。後端先賣資產、把差額換成舊借款幣放進帳戶，再 `executeReduce` 關掉舊路線，然後 `executeOpen` 新路線。換幣走既有的交易路徑，v2 合約不做 swap |
| 舊 vault 一次領不出來（流動性不足）、舊場所暫停取回、新場所可借額度不足、新路線沒過開倉條件 | 整筆還原。可以先 `executeReduce` 能還的部分，或換一條路線 |
| 一部分搬、一部分留 | 不支援。`executeMigrate` 一律搬整個部位；要縮小就先 `executeReduce` |

**gas（主網 fork 實測，2026-11-24）：** Lista vault 每次存、領都會走完整個提領佇列（USD1 vault 142 個市場、USDC vault 50 個），所以碰到它的交易都很重。BSC 單筆上限 16,777,216（EIP-7825）。

| 動作 | gas（審查修正後重測） |
| --- | --- |
| 只抵押（Lista／Venus） | 47 萬／64–68 萬 |
| 開倉借款存進 Lista USD1 vault | 671 萬 |
| 開倉借款存進 Lista USDC vault | 335 萬 |
| 開倉借款存進 Aave（Venus 路線） | 154–190 萬 |
| 部分還款，從 Lista USD1 vault／USDC vault／Aave | 601 萬／245 萬／69 萬 |
| 換 vault：Lista USD1 vault → Venus vUSD1 | 615 萬 |
| 減倉，從 Lista USD1 vault | 631 萬 |
| 減倉，整筆負債但 vault 少幾 wei（審查 M2 的情境；修正前 1,180 萬後 revert） | 641 萬，留下最低借款額 |
| 搬家 Lista → Venus（USDC vault → vUSDC） | 399 萬 |
| 搬家 Venus 換借款幣（Aave USDT → vU） | 185 萬 |
| 搬家 Venus → Lista（vU → Aave USDC） | 210 萬 |
| 搬家換借款幣 Lista USDC vault → Lista USD1 vault（兩個大 vault 各一次） | 887 萬 |
| 關閉（還清＋取回抵押＋放回剩餘），Lista USD1 vault／Venus vUSDC／Aave | 621–640 萬／116 萬／79–138 萬 |

每個動作對同一個 Lista vault 最多呼叫一次（修正前關閉要兩次、vault 的錢不夠時兩次、最壞情況三次約 1,800 萬）：需要多少就請 vault 給「最多這麼多」，給不足不會 revert；vault 完全領不出來也不重試，改用帳戶現金或留在策略盒。fork 測試對每個動作斷言 < 1,200 萬 gas。唯一會碰兩個大 vault 的是搬家（各一次，887 萬）。

**後端要做的：** 送出前 `eth_estimateGas`，超過 1,200 萬就拆成 `executeReduce`＋`executeOpen`；監看各 Lista vault 的 `withdrawQueueLength`（佇列越長越貴，USD1 vault 現在 142）。

## 8. 單位

| 欄位 | 單位 |
| --- | --- |
| `collateralAmount`／`withdrawAmount`／`collateral` | 抵押品最小單位 |
| `borrowAmount`／`repayAmount`／`maxCashIn`／`maxRepay`／`debt`／`routeDebt`／`principal`／`borrowCap`／vault `assets` | 該路線借款幣最小單位（主網四種幣都是 18 位） |
| `maxDebt`、`accountPrincipalUsd` | 美元 18 位（借款幣以 1 美元計、依 decimals 換算） |
| 利率、LTV | 18 位小數（年化；1e18 = 100%） |
| 使用率 | bps（無條件進位） |
| `*Value` | 美元 18 位，來自場所自己的 oracle |

## 9. 激勵代幣（LISTA、XVS）

產品規則：激勵留在用戶自己的投資組合帳戶、按組合顯示；只有全部賣出／提領／刪除時才送到 owner 錢包。

- 借款激勵（Lista `LendingRewardsDistributor` merkle claim、Venus `claimVenus`）任何人都能觸發，代幣進**借款帳戶**（投資組合帳戶）。不用合約。
- 存款 vault 的激勵進**策略盒**（它才是存款人），merkle claim 的對象是 `boxOf(account)`。領到之後任何人呼叫 `collectRewards(account, token)` 把它搬進帳戶。`token` 必須在 `setRewardToken` 白名單上；白名單不接受借款幣與任何 vault 份額，所以這個函式搬不動策略錢。
- 退出時 `executeSweepRewards(account, token, accountAmount, deadline)`：把策略盒裡全部的 `token`，加上帳戶裡最多 `accountAmount`（需要 approve），送到 `policy.rewardRecipient`。從帳戶拿的部分有一道保護：`token` 如果是這個帳戶的策略交易過的資產（`AtpRegistry.wasAssetAllowed`）就拒絕，避免把持股當激勵送走。沒設收款人時只做「策略盒 → 帳戶」。

**策略盒的 ERC-1271（只為了領 Lista vault 激勵）：** Lista 的 proof API 要「被領的那個地址」對一段登入文字簽名（`"<ISO 時間>\nThank you for your support of listaDAO."`），合約地址要帶 `type=safe`。策略盒的 `isValidSignature(bytes32 hash, bytes signature)` 只在以下全部成立時回傳有效：

1. `signature = abi.encode(bytes message, bytes accountSignature)`；
2. `message` 的結尾等於 registry 的 `rewardProofSuffix`（owner 可改，16–64 bytes，設成空字串就完全關閉），前面最多 64 bytes；
3. `hash` 等於這段 `message` 的 personal_sign 雜湊（EIP-191）；
4. 帳戶本身的 `isValidSignature(hash, accountSignature)` 回傳有效。

其他任何雜湊（EIP-712、EIP-2612 permit、Permit2、別的文字、尾巴對但前面塞了長文字、訊息的純 keccak256）一律無效，就算帳戶真的簽了也一樣（測試 `test_box_signsOnlyTheRewardProofMessage`、`test_L3_box_plainKeccakOfAnEip712Preimage_isRefused`）。EIP-191 的文字雜湊不可能等於 EIP-712 的 digest（後者的原文以 `0x1901` 開頭），所以不管誰簽，簽名都動不了策略盒裡的東西。

**主網實測（2026-11-24，使用者核准，花 0.00025 BNB；工具在 `script/mainnet-verify/`）：** 部署了一個 Kernel v3.3 帳戶、綁它的真實 `StrategyBox`（clone）與 7 個「呼叫形式探針」，再用拋棄式金鑰簽 Lista 的登入文字去問 proof API：

| 問題 | 結果 |
| --- | --- |
| (a) Kernel 帳戶的合約簽名（借款端激勵） | 接受（`userProof`、`userMultiProof` 都回 `000000000 success`） |
| (b) 策略盒的受限包裝（vault 端激勵） | 接受 |
| Lista 用哪種方式呼叫合約 | 只有 `isValidSignature(bytes32,bytes)`，hash 是 EIP-191 personal_sign 雜湊。純 keccak、舊版 `(bytes,bytes)` 的四種形式全部被拒 |
| 簽名長度 | 沒有限制（策略盒那種幾百 bytes 的簽名可以） |
| 要注意 | 合約地址一定要帶 `type=safe`，不帶會回 `500 System error`；EOA 簽名帶 `type=safe` 則回 `1005 Invalid signature` |

交易：`0xc68cb891e048305b36157700cdcc23e05f348af394dd22fd9d9c0dd1211745f8`（Kernel 帳戶 `0x103Ba86A0DC4E59A02462EC789F64bA777232401`）、`0xecac97d77c03a6f8cf6b3c9d55156d462d580791d88fd9df6347e5b4beabd74e`（host `0x0f904B16c4C19C898cBC467C167Bb5F7563A91EC`，策略盒 `0x650566c7E7c23c335C2dC534DB3122f0236b391d`）。這些合約不持有任何東西。依實測結果，策略盒已拿掉用不到的兩種形式（純 keccak、舊版 selector）。

## 10. 威脅檢視

**session key 外洩能做的：** 在白名單路線與 vault 之間開倉、搬家、換 vault、還款、取回抵押到帳戶本身；把帳戶裡同幣現金（在 owner approve 的額度內）拿去還這個帳戶自己的負債；退出式地把激勵送到 owner 指定的收款地址。最壞結果是選了較差的路線、反覆搬家耗 gas 與利息零頭，以及負債拉到目標 LTV（不會超過，也不會超過 `maxDebt`）。

**做不到的：** 把任何代幣送到帳戶、策略盒、借貸場所以外的地址（激勵只能到 owner 簽的收款人）；動策略盒裡的份額去做還款、換 vault、放回帳戶以外的事；讓負債超過預算；用沒登記的路線、vault、借款幣；改同意、改收款人；動其他帳戶；用簽名（permit 類）搬走策略盒的份額。

**任何人（`executeDeleverage`、`collectRewards`、`reconcile`）：** 只能在減倉線以上時用該帳戶策略盒的錢還該帳戶的負債、把激勵搬進該帳戶、把記帳的本金往下修到實際負債。拿不到任何東西。減倉線只看場所 oracle 的價格與負債，沒有可以在同一個區塊內人為推動的觸發條件（vault 使用率已經不是觸發條件）。

**rateReporter 外洩：** 可以亂報激勵與 Lista vault 利率（每項上限 50%），讓負利差的路線通過檢查。結果是開在不划算的路線上（損失＝利差 × 時間），拿不走本金；也無法讓人被強制平倉。主網腳本要求 rateReporter 是一把獨立的金鑰（`ATP_RATE_REPORTER`），不能是 session key 的 operator，也不能是 owner。開倉條件（利差、使用率）讀的是借款前那一刻的現貨數字，只是「不要開在明顯不划算的地方」的參考線，不是安全保證；安全靠的是目標線與減倉線。

**registry owner（上主網前要換 Safe／timelock，沿用 `AtpRegistry.owner()`）：** 可以登記惡意的 vault 或路線、把 `rewardProofSuffix` 改成別的文字，這是最高權限，跟 v1 相同。adapter 每種只能設一次，設完不能換，而且鏈上會檢查它綁的是這個 executor；executor（含 extension）、lens、策略盒都沒有 owner、不可升級。adapter 或 vault 之後壞掉時，帳戶 owner 用 `executeRescue` 把份額原樣拿回（先把該幣別的負債還清）。`maxDebt` 管的是本金（借出金額），不含之後累積的利息。

**重入：** executor 兩半的所有進入點都是 `nonReentrant`，共用同一個旗標（extension 以 delegatecall 執行，用的是 executor 的 storage），所以從 vault 回呼到任何一半都會被擋（測試 `test_reentrancy_fromAVault_isRefusedInBothHalves`）；registry 的寫入 hook、adapter、策略盒都只收 executor。借貸場所與 vault 都是白名單合約；四種借款幣沒有 transfer hook。executor 每筆交易結束餘額回到進入前（借款幣與抵押品都有檢查），executor 與 adapter 不留 allowance（單元測試 `_noResidue` 逐一檢查）。

**oracle：** 健康度用場所自己的 oracle（Venus `ResilientOracle`、Lista 各市場 oracle），也就是會清算你的那個價格；v2 不引入新價格來源。這些 oracle 在價格過舊時會 revert，那時新借款、有負債時取回抵押、搬家、減倉都會失敗；**單純還款與沒有負債時取回抵押不讀價格，照常運作**（審查 M1，測試 `test_M1_repayWorksWhileTheOracleCannotPrice`）。
週末會不會過舊：用有歷史狀態的節點回查 2026-11-20（五）收盤到 11-23（一）開盤，每隔幾小時取樣 Venus 的 TSLAB 價格源（`SingleFeed TSLAB/USD`）、Venus `ResilientOracle.getPrice`、Lista oracle `peek`（TSLAB、QQQB）：**週末全程都在更新**，每個取樣點距離上次更新都不到 1 小時（開盤時段約 1 分鐘），價格也在動（週六 349–354、週日 354–359），沒有任何一次讀取失敗。也就是 bStock 的鏈上價格是 24 小時報價，週末可以正常開倉、調整、退出；審查員 fork 測試裡的 `AllCapsReached` 是測試快轉兩天造成的假象，不是週末的真實風險（存進 Lista vault 時 Moolah 會讀供給佇列各市場的價格，測試現在把那些價格一起固定）。開盤跳空由目標線到清算線之間的距離吸收（目標 ≤ F/2）。借款幣在 `maxDebt` 以 1 美元計，只影響同意上限，不影響健康度計算。Venus 的 F 用 collateral factor（Venus 另有較高的 liquidation threshold），是保守的一邊。

**授權：** 帳戶對 executor 的抵押品 approve 是無上限的，但 executor 只會把抵押品送進該帳戶自己的部位。Venus delegate 與 Moolah authorization 給的是 executor 合約。策略盒只對「該種 vault 的 adapter」approve 自己的份額（測試 `test_box_guards` 檢查沒有別的 allowance）；adapter 只聽 executor。

**部署：** registry 綁 executor、executor 綁 registry 與 lens，三者由 `RoutingV2Deployer` 用固定的 nonce 建立並逐步檢查接線；任何一步接錯就 revert。

**slither（CI 的 `Slither` 工作，2026-11-24，slither-action v0.4.0，只看正式合約）：** v2 的合約沒有任何重入類的發現。列在 v2 上的有四類，逐項看過都是設計如此：
- 「transferFrom 的 from 可任意指定」：executor 的 `from` 是 `account`，而帶 `deadline` 的進入點都要求 `msg.sender == account`；唯一任何人可呼叫又會走到還款的 `executeDeleverage` 固定 `maxCashIn = 0`，不會從帳戶拉錢。adapter 的 `from` 是策略盒，只有 executor 能呼叫。
- 「abi.encodePacked 多個動態參數」：策略盒算 personal_sign 雜湊，就是 EIP-191 的標準寫法（固定前綴＋長度＋訊息）。
- 「嚴格相等」：都是餘額差額、是否為 0 的檢查。
- 「未初始化的區域變數／沒用到的回傳值」：預設值 0 是刻意的；沒用到的回傳值後面都改用餘額差額驗證。

整個 repo（含既有合約）共 305 筆，多數在既有合約，這個 PR 沒有處理；CI 目前設成只報告、不擋合併。

## 11. 主網地址與實測（2026-11-24 用公開 RPC 查證）

| 項目 | 地址 |
| --- | --- |
| Lista Moolah（proxy） | `0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C` |
| Venus core comptroller | `0xfD36E2c2a6789Db23113685031d7F16329158384` |
| Aave v3 Pool | `0x6807dc923806fE8Fd134338EABCA509979a7e0cB`（只有 USDT、USDC 有 reserve；USD1、U 沒有） |
| USDT／USDC／USD1／U | `0x55d3…7955`／`0x8AC7…580d`／`0x8d0D…8B0d`／`0xcE24…6666`（全部 18 位） |
| vUSDT／vUSDC／vUSD1／vU | `0xfD5840Cd36d94D7229439859C0112a4185BC0255`／`0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8`／`0x0C1DA220D301155b87318B90692Da8dc43B67340`／`0x3d5E269787d562b74aCC55F18Bd26C5D09Fa245E` |
| vNVDAB／vTSLAB／vSPCXB／vBTC／vWBNB | `0xEb8Ca841cBe1BC4832A10b15c7dAB1081eDaD371`／`0x97421799419Eb782628e73e7220d8E0A207469a3`／`0xC36dFaCc7a125859C106F29b9F2d874CCF29A55A`／`0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B`／`0x6bCa74586218dB34cdB402295796b79663d816e9` |
| Lista vault | USD1 `0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627`、U `0x9A17Fd5Cb8EFc25d11567e713aE795A89775a759`、USDC `0x8a06Ac91265dBEBE6D4606f45b10993E9a571869`、USDT（Gauntlet）`0x6d6783C146F2B0B2774C1725297f1845dc502525` |

這些只是查證紀錄與 fork 測試用；合約裡不寫死任何資產的路線。

**在真實市場上碰到、後端選路線時要知道的：**

- Venus 的 bStock 有很小的 supply cap：vNVDAB 上限 1,500 NVDAB，已用 1,499.2（幾乎滿，等於不能再抵押）；vTSLAB 上限 236、已用 34.9；vSPCXB 上限 2,000、已用 264。抵押時撞到上限會 revert，後端要先看 `supplyCaps` 的剩餘額度。
- Lista 的 Gauntlet USDT vault 供給佇列是空的，存不進去（`AllCapsReached`）；選 vault 前要看 `maxDeposit`。
- Lista 市場使用率普遍接近 90%（見 §6），在預設的 95% 上限之內。
- Venus 借 USDT 年化約 5.0%、vUSDT 存款約 3.5%；Aave USDT 存款利率與各 vault 數字見 fork 測試輸出。Venus 借、Venus 存同一個幣一定是負利差。
- 測試合約的預設地址在主網上本來就有 26.5 USDT 的零頭，跟合約無關，測試以前後差額為準。

## 12. 測試網（chain 97）：已部署（2026-11-25）

腳本：`script/testnet/DeployBorrowRoutingTestnet.s.sol`（部署＋設定，可重複執行，第二次沒有交易）、`script/testnet/RoutingDemoTestnet.s.sol`（演練）。參數在 `script/testnet/TestnetRoutingBook.sol`。

**部署紀錄（2026-11-25 00:17–00:26 台北時間，程式碼 commit `1888572`）：**

| 合約 | 地址 |
| --- | --- |
| `AtpBorrowExecutorV2`（session key 的 target） | `0x494C106498e8221D3f72474f36995C191ACf6bB5` |
| `AtpBorrowExecutorV2Extension` | `0x7bC1E80Cd0a684D56333775423a95efF13602bf8` |
| `AtpBorrowRegistryV2` | `0x7eae73a76Ff2359fE1aB059A77Dd36840A32559E` |
| `AtpBorrowLensV2` | `0x18A55C04aE72A00ED7790577FbdA9159DAc94000` |
| `StrategyBox` 實作 | `0xa448e0108f31Ab1d084FfdDcD4827D9CB5D4E191` |
| adapter：ERC4626／Venus／Aave | `0x3548A7641bae787A48E263f8aF053899e46fF02d`／`0x861e91a0a3d46c391587323B3FE32A43E53CFe91`／`0x432f96D0790f3bc3ceBed379Fd476F367CE63BAa` |
| 模擬 USDC／USD1／U | `0xB887Ca3379dC41F1155dD0cb1B2e3c1D85D17eD5`／`0xEA13862CB4612d228BA89b4319fEEc60F05Ab3AC`／`0xC71E4Efb5A36bD54ad8DE9E9742bFA8fBd750875` |
| 模擬激勵代幣 LISTA | `0xFfE08AC6f45A4aE5Ae2a692f0965EA46CE7d822c` |

66 條路線、10 個 vault 的 id 與參數、vToken／earn vault／Aave 池的地址都在 `deployments/testnet-97.json` 的 `borrowV2`。`rateReporter` 是 OPERATOR（`0xd8CE…9d7F`）。

- 部署＋設定：331 筆（DEPLOYER 21、OWNER 310），區塊 144626656–144628034，0 筆失敗，82,530,848 gas，0.01238 tBNB。地址跟 fork 演練完全相同。再跑一次腳本：0 筆。
- 唯讀檢查：各合約有程式碼且互相接線正確、場所地址＝v1 用的那套模擬 Venus／Lista、66 條路線與 10 個 vault 都開著、四種借款幣與激勵代幣在白名單、沒有任何一筆交易的對象是 v1 的 executor／registry。
- 演練 `RoutingDemoTestnet`：41 筆（OWNER），區塊 144629276–144629454，0 筆失敗，9,644,612 gas（比 fork 演練多 3.9%，鏈上各步之間有利息），0.00145 tBNB。示範帳戶 `0x65c3251F4854A53Cc01C2386A44ec372F292C37c`，策略盒 `0xf56bc1EC1185F5Dbf31a7b6E38afA9029eF8B520`，第三方減倉還了 504.97 USD1，結束時沒有部位、沒有負債。每一步的交易 hash 在 manifest 的 `borrowV2.demo.txs`。
- 跑完餘額：DEPLOYER 0.4333 tBNB、OWNER 0.0040 tBNB（OWNER 之後要再做設定先補一點）。

跟演練不同的只有一件事：廣播用的 RPC。`https://bsc-testnet.bnbchain.org` 只留幾分鐘的歷史狀態，forge 模擬 331 筆要約 10 分鐘，第一次在模擬階段就 `missing trie node` 停下（**一筆都沒送出**，兩個帳戶的 nonce 沒動）；改用 `https://bsc-testnet.publicnode.com` 後一次跑完。

測試網上的 Venus 存款 vault（vUSDT／vUSDC／vUSD1／vU）利率＝借款利率 × 使用率，現在幾乎沒人借所以是 0%：直接「借了存進去」會被負利差擋下（`quote` 的 gate＝4），從別的 vault 換過去（`executeSwitchVault`）不受這條限制。後端在測試網選 vault 時會自然選到 earn vault 或 Aave。

以下是腳本做的事與部署前的 fork 演練。

沿用（不重新部署、不改設定）：核心 `AtpRegistry`／`AtpExecutor`、#64 的借貸 oracle、模擬 Venus comptroller、vUSDT、模擬 Lista Moolah、31 個抵押品與它們的 vToken／Lista USDT 市場。v1 的 `AtpBorrowExecutor`／`AtpBorrowRegistry` 與既有部位完全不動，可以跟 v2 並存。

新增：

| 類別 | 內容 |
| --- | --- |
| 模擬代幣 | USDC、USD1、U（18 位）；模擬激勵代幣 LISTA（當 1 美元計） |
| Venus | vUSDC、vUSD1、vU（借款市場＋存款 vault），各 50 萬流動性 |
| Lista | NVDAB、TSLAB、QQQB、MSTRB、BTCB、WBNB、SPYB、XAUt 各加 USDC／USD1／U 三個市場；NVDAB、TSLAB 另加 USDT 市場（讓同一資產能在 Venus 與 Lista 之間搬）。共 26 個新市場，各 25 萬流動性 |
| 存款 vault | 四種幣各一個 ERC4626 earn vault（`MockRewardEarnVault`：利息用本幣、激勵用模擬 LISTA 付給策略盒）；Aave 模擬池 USDT、USDC |
| v2 合約 | `RoutingV2Deployer`、registry、lens、executor（含策略盒實作）、三個 adapter |
| v2 設定 | 4 種借款幣、31 個資產分級、7 個 Venus 市場對應、66 條路線（31 條沿用 v1 市場的 USDT 路線＋Venus 3 檔 × 3 種新幣＋Lista 26 個新市場）、10 個 vault、激勵代幣白名單、領激勵簽名文字、第一次利率回報，之後 `rateReporter` 交給 OPERATOR |

模擬利率（owner 隨時可調；只是讓不同路線有高有低，不是產品決定）：

| 幣 | Venus 借款 | Lista 借款 | ERC4626 vault | vault 激勵 | Aave 存款 |
| --- | --- | --- | --- | --- | --- |
| USDT | 2.5%（既有） | 2.5%（既有） | 4.5% | 0.5% | 4.2% |
| USDC | 3.0% | 2.2% | 4.0% | 0.5% | 3.8% |
| USD1 | 2.0% | 1.8% | 3.6% | 1.0% | 無 |
| U | 3.5% | 3.0% | 5.2% | 0% | 無 |

Lista 新市場的抵押激勵 1%、借款激勵 0.5%（跟 #64 一樣，模擬市場用 USDT 付給借款帳戶）。每條路線 CRE8 上限 10 萬。

USDT 會多幾個 minter（模擬利息用）：新的 USDT earn vault、Aave USDT 池的 aToken。OWNER 在灌流動性時暫時當 USDT minter，同一次執行結束前收回。

**本機 chain 97 fork 演練結果（2026-11-24，fork 區塊 144597575，gas price 0.15 gwei）：**

| | 交易數 | gas | 花費 |
| --- | --- | --- | --- |
| 部署＋設定（複審修正後重跑，fork 區塊 144623xxx） | 331 筆（DEPLOYER 21 筆、OWNER 310 筆），0 筆失敗 | 82,090,915（最大單筆 5,346,486） | 0.0123 tBNB（DEPLOYER 0.00674、OWNER 0.00558） |
| 再跑一次 | 0 筆 | | |
| 演練 `RoutingDemoTestnet`（複審修正後重跑） | 41 筆（都是 OWNER），0 筆失敗 | 9,346,203（最大單筆 1,169,428） | 0.00140 tBNB（OWNER） |

目前餘額：DEPLOYER 0.440 tBNB、OWNER 0.0110 tBNB。OWNER 兩支腳本共花 0.00698，餘額是它的 1.58 倍，夠；跑完剩約 0.004，之後要再做設定的話先補一點。測試網目前的最低 gas price 是 0.1 gwei，腳本固定用 0.15 gwei。

演練內容：QQQB 在 Lista 借 USDC 存 USDC vault → 部分還款 → 一筆搬到 Lista USD1 市場（換借款幣）→ 存款換到 Venus vUSD1 → owner 把這條路線的線調緊（目標 10%、減倉 20%）→ 第三方觸發減倉（還 505.0 USD1）→ 線調回預設 → 關閉；NVDAB 在 Venus 借 USDT 存 Aave → 一筆搬到 Lista（同幣）→ 關閉；激勵由 vault 發給策略盒 → `collectRewards` 進帳戶 → `executeSweepRewards` 到 owner 指定地址。

**v1 與 v2 不能在同一個帳戶上同時用 Venus（後端要守的規則）：** Venus 的負債與抵押是整個帳戶一起算的，v2 會把帳戶在 Venus 的全部 USDT 負債、全部 vToken 當成自己的。規則：一個投資組合帳戶要嘛用 v1、要嘛用 v2；要從 v1 換到 v2，先把 v1 在 Venus 的部位完全關掉（負債 0、抵押取回、v1 的 vault 份額贖回），再開 v2。合約這邊多一道保險：帳戶在 Venus 欠某個借款幣、但在 v2 沒有這個幣的 Venus 部位時，v2 這個幣的 Venus 路線開不了（`ForeignDebt`），用 `executeOpen` 或搬家搬進去都一樣（搬家這條路徑是 draft6 才擋得住的；測試網上的 draft5 程式用 Venus→Venus 搬家可以繞過，見 §16 的 L-1，所以在換上修正版之前這一點完全靠後端的規則）。v2 自己的部位本金還完、只剩利息零頭時不算（部位會留在 `accountRoutes` 直到這個幣的負債歸零）。這道保險只擋「先有 v1 負債、才來開 v2」；v2 部位開著之後又去 v1 借同一個幣，合約分不出來，還是要靠後端的規則。Lista 每個市場獨立，v1／v2 用同一個 Lista 市場時也一樣要先關 v1（合約擋不到這個，因為同一個市場的負債分不出是誰開的）。

演練只動它自己的示範帳戶（OWNER 用 CREATE2 建的 `RoutingDemoAccount`）與 v2 的東西：模擬代幣是鑄給示範帳戶的，減倉演練調的是 v2 這一條路線的線，**不動借貸 oracle 的價格**（那個 oracle v1 的部位也在讀；最早的版本是把 QQQB 價格砍半再調回，已改掉）。它會在核心 `AtpRegistry` 登記一個示範帳戶自己的非公開策略並 enroll 自己。

**減倉那一段現在只在本機 fork 上跑（第三輪審查 I-4）：** QQQB/USD1 是所有帳戶共用的路線。2026-11-25 那次鏈上演練把它的線調緊（目標 10%、減倉 20%）再調回，中間那兩筆交易之間，這條路線上 LTV ≥ 20% 的其他帳戶任何人都可以減倉。腳本現在用 `anvil_nodeInfo` 判斷：RPC 是本機 Anvil fork 才做「調緊 → 第三方減倉 → 調回」這三筆；對公開測試網跑時自動跳過（印 `ROUTING_DEMO_DELEVERAGE_SKIPPED_NOT_A_FORK`），鏈上那一趟少 3 筆，不再動任何共用設定。上面的演練紀錄與筆數是改之前的。審查員讀過鏈上 66 條路線的 `ltvConfig`，目前都是預設值，沒有殘留。改完後用目前的鏈上狀態各模擬一次（都不廣播）：對公開節點 38 筆、跳過減倉、結束時沒有部位；對本機 Anvil fork 41 筆、第三方減倉還 504.97 USD1。另外，示範帳戶的 CREATE2 地址跟這個腳本檔案的編譯結果綁在一起，檔案改過之後下次演練會建一個新的示範帳戶（模擬裡是 `0xd641…3Fb1`），舊的 `0x65c3…C37c` 沒有部位、留在鏈上不用處理。

要注意的兩件事：
- 演練腳本所有步驟在同一個模擬時間點跑，vault 還沒生息，份額取整會讓 vault 比負債少 1 個最小單位。腳本先給帳戶 1 個借款幣當 `maxCashIn`。後端剛開倉就馬上搬家或關閉也會遇到，同樣帶一點 `maxCashIn` 即可；隔幾個區塊之後 vault 的利息就蓋過去了。
- 廣播指令跟 #64 一樣，改腳本名稱即可；`--gas-estimate-multiplier 200`；RPC 要用留得住十幾分鐘歷史狀態的（publicnode 可以，`bsc-testnet.bnbchain.org` 不行，見上）。

```bash
export TESTNET_EXECUTOR=$(jq -r .contracts.executor deployments/testnet-97.json)
export BORROW_EXECUTOR_V1=$(jq -r .borrow.executor deployments/testnet-97.json)
YV=$(jq -r .contracts.yieldView deployments/testnet-97.json)
forge script script/testnet/DeployBorrowRoutingTestnet.s.sol:DeployBorrowRoutingTestnet \
  --libraries src/atp/yield/YieldView.sol:YieldView:$YV --rpc-url <RPC> --broadcast --slow \
  --with-gas-price 150000000 --priority-gas-price 150000000 --gas-estimate-multiplier 200 \
  --sender 0x55662B4183fcA1230694D5D57F56E4F2E0e3008a   # 金鑰經 TESTNET_DEPLOYER_KEY／TESTNET_OWNER_KEY
# 演練：ROUTING_EXECUTOR=<上一步印出的 routingExecutor> forge script script/testnet/RoutingDemoTestnet.s.sol:RoutingDemoTestnet ...
```

## 13. 主網部署路徑（腳本已備好，沒有執行）

腳本 `script/DeployBorrowRoutingMainnet.s.sol`，名單在 `script/BorrowRoutingMainnetSpecs.sol`。分三步，部署的 key 不需要任何 owner 權限，owner（Safe）不需要部署任何東西。

**前置：** 目前主網上 2026-11-09 那套 `AtpExecutor`（`0x5477…c9e7`）沒有 `globalPaused()`，registry 的 owner 還是部署者 EOA。v2 要綁的是新版核心（`DeployAtpMainnet` 部署、owner 交給 Safe 之後的那一套）；腳本一開始就會檢查 `ATP_EXECUTOR.globalPaused()`，舊的那套會直接被拒絕。**新版核心部署後要先把它的地址寫進 `deployments/mainnet.json`（`contracts.AtpExecutor`、`contracts.AtpRegistry`）並合併**：步驟 3 的 `verify()` 拿這個檔案當錨點，檔案裡現在記的還是舊核心，所以在那之前 `verify()` 一定不過。

| 步驟 | 指令 | 誰 | 做什麼 |
| --- | --- | --- | --- |
| 1 部署 | `ATP_EXECUTOR=<核心 executor> EXPECTED_DEPLOYER_NONCE=$(cast nonce <deployer>) forge script script/DeployBorrowRoutingMainnet.s.sol --rpc-url <RPC> --broadcast` | 任何有 BNB 的部署 key | 8 筆：`RoutingV2Deployer`、registry、lens、extension、executor、三個 adapter。不做任何設定。nonce 不符就不送（跑第二次會被擋） |
| 2 設定 | `forge script script/DeployBorrowRoutingMainnet.s.sol --sig "printConfig(address,address,address,address)" <executor> <erc4626Adapter> <venusAdapter> <aaveAdapter> --rpc-url <RPC>` | 唯讀；印出的呼叫由 Safe 送 | 列出名單裡還沒做的 owner 呼叫（to＝routing registry、calldata）。全做完時印 0 筆。fork 演練或 owner 是 key 時可改用 `configure(...)` 直接送 |
| 3 驗證 | `ATP_SAFE=<safe> ATP_RATE_REPORTER=<reporter> ATP_EXECUTOR=<核心 executor> forge script script/DeployBorrowRoutingMainnet.s.sol --sig "verify(address)" <executor> --rpc-url <RPC>` | 唯讀；Safe 送完設定後的最終檢查 | 八個合約的鏈上程式碼跟本 repo 的編譯結果**完全相同**：immutable 的位置從編譯產物的 `immutableReferences` 讀出來，這些位置以外每一個 byte 都要一樣；每個 immutable 的值必須是預期的地址（registry、lens、executor、extension、策略盒實作、Venus comptroller、Moolah、核心），哪個位置放哪個值再由 getter 逐一核對（executor 與 lens 自己那份場所地址也有 getter）；互相的接線；**鏈上的路線、vault 數量與內容跟名單完全相同**（多一條、少一條都失敗）；每條路線的上限（launch cap）、使用率上限（9500）、目標線＝min(類別上限, F/2)、減倉線＝F×2/3；激勵代幣；簽名文字；`rateReporter`＝`ATP_RATE_REPORTER`（不能是 operator 或 owner）；`ATP_SAFE` 必填，必須是合約、已經是 registry 的 owner、沒有待接手的移轉；**`ATP_EXECUTOR` 必填**（draft6）：必須等於 `deployments/mainnet.json` 的 `contracts.AtpExecutor`，它的 `registry()` 必須等於 `contracts.AtpRegistry`，檔案的 `chainId` 必須是目前的鏈。核心地址只從環境變數與這個檔案來，不會從被驗證的合約自己讀。任何一項不符就 revert |

步驟 2、3 都要帶 `ATP_RATE_REPORTER`（回報利率的獨立金鑰）。Lista 市場在名單裡用「market id＋抵押品地址＋借款幣地址＋oracle 地址」釘住，Moolah 回傳的任何一項不同就不產生設定。

第一批名單（2026-11-24 鏈上查證；之後 owner 用 `registerRoute`／`registerVault` 逐步加，後端不用等合約改版）：

- 借款幣：USDT、USDC、USD1、U。
- Venus 抵押品：NVDAB、TSLAB、SPCXB（一般個股），各 4 種借款幣，共 12 條路線。
- Lista 市場：NVDAB/USD1、TSLAB/USDC、QQQB/USDC、QQQB/USD1、QQQB/U、SPYB/USDC、SPYB/USD1、SPYB/U，共 8 條（QQQB、SPYB 是指數類）。
- vault：Lista USDC／USD1／U vault、Venus vUSDT／vUSDC／vUSD1／vU、Aave USDT／USDC，共 9 個。
- 激勵代幣：LISTA（`0xFceB…dC46`）、XVS（`0xcF6B…6C63`）。
- 每條路線的 CRE8 上限：50,000（借款幣）。這是我先放的上線值，不是產品決定，請使用者確認；owner 之後可逐條用 `setRouteCap` 改。

**fork 演練（`test/atp/fork/BorrowRoutingMainnetScriptFork.t.sol`，需要 `BSC_RPC_URL`）：** 用腳本的同一段程式部署 → 套用它列出的 owner 呼叫（54 筆）→ `verify` 通過 → 再列一次是 0 筆；接著逐項弄壞確認 `verify` 每一項都會失敗：拿掉分級、改上限、改使用率上限、暫停、停用 vault、reporter 換成 operator、多登記一條名單外的路線、把合約程式碼換掉或翻一個 bit、`ATP_SAFE` 不是 owner、移轉未接手；reporter 設成 operator 時腳本連設定都不產生。最後用名單上的路線（Lista QQQB/USD1 → Lista USD1 vault）實際開倉、關閉一次。fork 測試綁的是替身核心（`RoutingCoreStub`＋全新的 `AtpRegistry`，測試本身當 owner），所以它呼叫的是把核心地址明確傳進去的 `verifyWith(executor, core)`；正式的 `verify(executor)` 只吃 `ATP_EXECUTOR`＋`deployments/mainnet.json`，替身核心過不了（`test_script_verify_coreIsAnchoredToTheManifest_notToTheContractsUnderVerification`；不需要 RPC 的那一半在 `test/script/DeployBorrowRoutingMainnetChecks.t.sol`，CI 會跑）。

部署後還要做、但不在腳本裡的事：把地址寫進 `deployments/mainnet.json`；後端 operator 送第一次 `reportRates`（在那之前 Lista vault 的路線開不了）；第一個策略盒建立後實測 Lista 的領激勵簽名（§9）。

## 14. 獨立審查（2026-11-24）的發現與修正

沒有 Critical。審查員的 PoC 都改寫成回歸測試（修正前的程式會讓它失敗）。單元測試在 `test/atp/borrow/v2/`，fork 測試在 `test/atp/fork/`。

| 發現 | 修正 | 測試 |
| --- | --- | --- |
| **H1a** 分級被拿掉（預算 0）時取回抵押的檢查形同虛設，可以把 LTV 拉到場所上限 | 放寬條件要求健康度不得下降（跟 H1b 同一條）：只拿抵押不還款一定被擋。draft4 另外要求「動作前就有預算」，複審 R3 之後拿掉，改成可以分批退出 | `test_H1a_tierRemoved_collateralLeavesOnlyAgainstRepayment_lista`／`_venus`、`test_R3_tierRemoved_positionCanBeWoundDownInSteps` |
| **H1b** Venus 混合抵押時只比負債÷預算，可以換成估值低的抵押品讓健康度 1.67→1.07 | 放寬條件加上「健康度不得下降」 | `test_H1b_venusMixedCollateral_healthFactorMayNotDrop`；不變量 `invariant_noActionWorsensAPositionPastItsBudget` |
| **M1** 單純還款也讀價格，oracle 掛掉時還不了 | 只有抵押離開時才讀；沒有負債時取回抵押也不讀 | `test_M1_repayWorksWhileTheOracleCannotPrice` |
| **M2** Lista 減倉在 vault 少幾 wei 時留下低於最低借款額的零頭而 revert，還燒 1,180 萬 gas | 還不滿時至少留下最低借款額 ×1.01；多領的錢回策略盒 | `test_M2_deleverage_boxAFewUnitsShort_leavesTheMinimumInsteadOfReverting`、`test_M2_deleverageAmount_roundsUpToAFullRepaymentNearTheMinimum`、fork `test_fork_M2_deleverageWholeDebt_vaultShortByDust`（641 萬 gas）；`MinLoanMoolah` 測試用合約 |
| **M3** gas 懸崖：一個動作呼叫 Lista vault 兩到三次，最壞約 1,800 萬 > 單筆上限 | 每個動作每個 vault 最多一次（「最多領這麼多」，不足不 revert）；vault 失敗不重試、不再接著放回 | `test_M3_vaultIsCalledOnce_partialRepay_shortHolding_andClose`、`test_M3_vaultThatCannotPay_isNotRetried_closeFallsBackToCash`；fork 測試每個動作斷言 < 1,200 萬 |
| **M4** 換 vault 不檢查開倉條件，可以搬進 99% 使用率的 vault；不看 enrollment 暫停 | 換 vault 套用存款使用率線與暫停檢查 | `test_M4_switchVault_respectsUtilizationGate_andPausedEnrollment` |
| **M5** adapter 或 vault 壞掉時策略盒的份額永遠鎖住；`setAdapter` 沒有鏈上檢查 executor | 新增 `executeRescue`（份額原樣回帳戶，不呼叫 vault）；`setAdapter` 檢查 `adapter.executor()` | `test_M5_rescue_sendsReceiptsToTheAccount_onlyWithoutDebt`、`test_M5_setAdapter_requiresAnAdapterOfThisExecutor` |
| **L1** vault 使用率 > 95% 的任何人觸發可被同區塊操縱 | 拿掉這個觸發條件；只剩健康度減倉線 | `test_vaultAbove95Percent_isNotPermissionless_accountExits` |
| **L2** 開倉條件用借款前的現貨利率；rateReporter 跟 operator 同一把金鑰 | 文件寫明是參考線；主網腳本要求獨立的 `ATP_RATE_REPORTER` | fork `test_script_verify_catchesExtrasForeignCodeAndOwnership` |
| **L3** 策略盒接受純 keccak，配合惡意的 suffix 可以驗過 EIP-712 digest | 主網實測後只留 `(bytes32,bytes)`＋EIP-191；suffix 限 16–64 bytes | `test_L3_box_plainKeccakOfAnEip712Preimage_isRefused`、`test_box_signsOnlyTheRewardProofMessage`；真實 Kernel＋已部署 policy：fork97 `test_fork97_sessionKey_passesTheAccounts1271_butTheBoxOnlyForTheListaText` |
| **L4** ERC4626 adapter 回報的入帳金額讓 1bp 檢查失效，空 vault 的膨脹攻擊抓不到 | 用實際收到的份額換算入帳價值；登記時要求至少 1,000 顆存量 | `test_L4_emptyVaultCannotBeListed_andAFeeOnDepositIsRefused` |
| **L5** 經由另一條 Venus 路線還款時 principal 記帳不動 | 超過本路線 principal 的部分沖銷同幣別其他 Venus 路線 | `test_L5_repayingThroughASiblingVenusRoute_retiresTheRealPrincipal`；不變量 `invariant_principalBooksAddUp` |
| **L6** 同一帳戶的 v1 與 v2 Venus 部位互相干擾 | 文件寫明後端規則；帳戶有非 v2 的 Venus 負債時拒絕開倉（`ForeignDebt`） | `test_L6_accountWithForeignVenusDebt_cannotOpen` |
| **L7** 主網 `verify()` 不夠嚴 | 路線／vault 與名單完全相同、`ATP_SAFE` 必填、比對鏈上程式碼、Lista 市場用地址與 oracle 釘住 | fork `test_script_deployConfigureVerify_andDriftIsCaught`、`test_script_verify_catchesExtrasForeignCodeAndOwnership` |
| **L8** 沒登記的 Venus 抵押品沒有減倉線；退出路徑可能被滿的 vault 清單擋住；激勵代幣可以是抵押品；24 個部位時 Venus→Venus 搬家失敗 | 減倉線照算；退出路徑只會從清單移除；`setRewardToken` 拒絕抵押品／借款幣／份額；搬家時新路線接手舊路線的位置 | `test_L8_unlistedVenusCollateral_keepsADeleverageLine`、`test_L8_fullVaultList_neverBlocksAnExit`、`test_L8_venusToVenusMigrate_keepsOnePosition_evenWhenTheListIsFull`、`test_rewards_sweepOnExit_toOwnersRecipient` |
| **測試** | 不變量／fuzz（隨機 session key 動作序列）、oracle 失效還款、高使用率換 vault、minLoan、非 18 位小數、收費／重入的惡意 vault、fork 測試的 gas 上限與資金守恆、缺口用量測的不用 `deal` 蓋掉、可用 `BSC_FORK_BLOCK` 釘區塊 | `RoutingInvariant.t.sol`（5 個不變量）、`test_decimals_6DecimalLoan_8DecimalCollateral`、`test_reentrancy_fromAVault_isRefusedInBothHalves`、`test_extension_onlyRunsAsTheExecutor`、fork 的 `_begin/_end`（gas < 1,200 萬、策略錢不減少）與 `_topUp`（缺口有上界） |

沒做的：真實 Kernel＋CallPolicy 的「arg0 == account」整合測試（要 ZeroDev SDK 與 bundler，屬於後端的 kernel-smoke；這裡改成直接在測試網的真實帳戶與已部署 policy 上驗 ERC-1271 那一半，結論見 §4）。

## 15. 複審（2026-11-24，head `59511e8`）的發現與修正

複審結論：原本 17 項都已修正或明確處理，沒有新的 Critical／High，可以上測試網。下面是複審另外提出的項目。

| 發現 | 修正 | 測試 |
| --- | --- | --- |
| **R2** `ForeignDebt` 誤擋自己的部位：條件是「記帳本金為 0 而 Venus 還有負債」，但還款先沖本金，所以「本金還完、剩利息零頭」（借 100、30 天後剛好還 100，剩 0.205）之後連只加抵押的 `executeOpen`、新借款、搬進這個幣的 Venus 路線都被擋 | 改成「帳戶欠這個幣，而且在 v2 沒有這個幣的 Venus 部位」才算外來負債。配合的記帳規則：某個幣在 Venus 還有負債時，至少留一個這個幣的 Venus 部位在帳戶的清單裡（同一抵押品開兩種幣、其中一種本金還完時，原本會把那個部位移掉） | `test_R2_interestLeftAfterThePrincipal_isNotForeignDebt`、`test_R2_sharedCollateral_positionStaysWhileItsTokenIsOwed`、原有的 `test_L6_accountWithForeignVenusDebt_cannotOpen` |
| **R3** 被拿掉分級的資產，部分退出完全被擋（還一半＋拿一成也不行，只能一次全關） | 拿掉「動作前要有預算」這一條，只留「負債÷預算不變高、健康度不變低」。沒有預算時前者恆成立，由健康度把關：只拿抵押不還款（H1a 的原始攻擊）健康度一定下降，照樣被擋；審查員原本的 H1a PoC 對現在的程式仍然失敗（`LtvTooHigh(300, 0)`） | `test_R3_tierRemoved_positionCanBeWoundDownInSteps`、`test_H1a_tierRemoved_collateralLeavesOnlyAgainstRepayment_lista`／`_venus`；不變量測試的 `reduced_without_budget` 計數（沒有預算的部位成功退出的次數） |
| **R4** 主網 `verify()` 的程式碼比對：編譯結果是 0 的位置可以任意不同（最多 2,048 bytes），而 executor 與 lens 自己那份場所地址（private immutable）沒有 getter，所以「程式一樣但場所地址被換掉」的 executor 驗得過 | 從編譯產物的 `immutableReferences` 讀出每個 immutable 的位置：這些位置以外逐 byte 完全相同；每個 immutable 的值必須在預期的地址清單裡（一個 immutable 對一個地址）；executor 與 lens 新增 `venusComptroller()`、`moolah()` getter 並逐一核對。`foundry.toml` 因此允許腳本讀 `out/` | fork `test_script_verify_catchesSwappedVenuePins_andBytesAlteredWhereTheBuildHasZeros`（場所地址換成別的、兩個場所對調、在編譯結果為 0 的位置改一個 byte，三種都被擋） |
| **R5** 負債 ≤ 最低借款額 × 1.01（約 15 美元）而且策略盒的錢不夠的部位，第三方減倉不了（Moolah 的規則）；減倉少還之後可能有約 15 美元閒置在策略盒 | 寫進 §5「小額部位」與介面 JSON（`lista.smallPositions`）；lens 新增 `minDebt(routeId)`，後端用 `routeDebt ≤ minDebt` 且 `assets + idleOf < routeDebt` 找出這種部位，自己補錢全還或關閉 | `test_M2_deleverage_boxAFewUnitsShort_leavesTheMinimumInsteadOfReverting`、`RoutingMinLoan.t.sol`（原有，改用 `minDebt`） |
| **R6** 測試 | 不變量 handler：Venus 抵押品不同質（TSLA CF 90%／20% 類、NVDA CF 60%／30% 類）；新增動作：改分級（含拿掉）、改路線的目標線／減倉線、救援、發激勵／任何人領／帳戶送出、放回、先把價格推過減倉線再由第三方減倉；新增不變量：借款幣這一側的價值守恆（每個動作前後，錢包＋策略盒＋vault − 負債 不變，容許 vToken 取整的 1e11）、激勵代幣只會在策略盒／帳戶／owner 指定的收款人；跑得更深（本機 48×80，CI 64×100＝6,400 次呼叫，原本 32×60＝1,920；CI 的 job 上限 10 分鐘，128×100 會跑到 8 分鐘所以取 64）；每次跑完印整個 campaign 的累計次數。CI 的 fork 測試要釘區塊（`CI=true` 而沒設 `BSC_FORK_BLOCK` 時直接失敗） | `RoutingInvariant.t.sol`（7 個不變量）。CI 深度的一次結果（256×100 時）：開倉 1,925、還款／取回 2,522（其中沒有預算的部位 34）、搬家 922、換 vault 329、放回 56、救援 48、第三方減倉 817（共還 9,888 顆）、領激勵 185、送出激勵 564、改分級 1,153、改線 1,032；0 個違反 |
| `executeRescue` 只給 owner | 合約分不出 owner 與 session key，文件（§4）與介面 JSON（`rescueIsOwnerOnlyByPolicy`）寫明後端與 paymaster 的三條規則 | `test_M5_rescue_sendsReceiptsToTheAccount_onlyWithoutDebt`（合約這一側：沒有負債才行、只到帳戶本身） |

測試網演練腳本的兩個修改（不是審查項目）：減倉演練不再動共用的借貸 oracle 價格，改成調 v2 那一條路線的線；結束時的抵押品檢查容許 Venus vToken 取整的零頭（1e11 個最小單位以內）。

## 16. 第三輪審查（2026-11-25，`59511e8..1888572`，以 main `a6ae1fe` 執行）的發現與處理

第三輪結論：沒有 Critical／High／Medium；2 個 Low、6 個 Info。沒有任何路徑讓 session key 把抵押品或借款資金送出帳戶／策略盒。審查員另外確認了測試網 chain 97 上 8 個 v2 合約的 bytecode 與 `a6ae1fe` 的編譯結果逐 byte 相同。

**這一節的修正（draft6）只在 repo 裡，還沒部署到任何鏈。** 測試網上跑的仍是 draft5 的程式；換上修正版要重新部署整套 v2 合約（registry 把 executor 的地址寫死，不能只換 executor 或 lens），要不要換、什麼時候換由使用者決定。

| 發現 | 處理 | 測試／位置 |
| --- | --- | --- |
| **L-1** `ForeignDebt` 在 Venus→Venus 搬家時被繞過（R2 引入的退步）：`executeMigrate` 先 `recordSwap` 把新路線放進帳戶清單，才呼叫 `beforeOpen`，而新條件是「欠這個幣、清單裡卻沒有這個幣的 Venus 部位」，此時一定找得到自己剛放進去的那條。帳戶有外來的 Venus USDT 負債時，先開同抵押品的 USDC 路線（只放抵押）再搬到 USDT 路線就過了，之後 v2 把那筆外來負債當成自己的。資金不會離開帳戶、預算仍把那筆負債算進去，所以是 Low | **已修**（只動 executor，registry 沒動）：`beforeOpen` 移到 `recordSwap` 前面，仍在 `recordReduce` 後面（舊本金已沖銷，上限與 `maxDebt` 的算法不變）。`beforeOpen` 是唯讀的，兩者之間只有 `ForeignDebt` 這一條讀帳戶清單，其他檢查結果不變。自己的負債不會被誤擋：新借款幣在 Venus 有自己的負債時，清單裡一定已經有這個幣的部位（R2 的記帳規則），不需要靠這次搬家放進去的那條 | `RoutingReview.t.sol`（第三輪那一段）：`test_L1_foreignDebt_venusToVenusMigrate_isRefused`、`test_L1_foreignDebt_migrateWithOldAndNewDebt_isRefused`（審查員的兩個 PoC，修正前兩個都不會 revert）、`test_L1_ownDebtInTheNewToken_venusToVenusMigrate_passes`（別條路線有本金、目標路線自己有本金、只剩利息零頭三種）、`testFuzz_L1_venusList_ownDebtIsNeverForeign`（隨機 40 步的開倉／還款／Venus→Venus 搬家／時間／第三方代還／reconcile：欠幣必有該幣部位、有本金或抵押必有部位、開倉與搬家都不會出現 `ForeignDebt`） |
| **L-2** 主網 `verify()` 沒給 `ATP_EXECUTOR` 時，核心取自被驗證的 registry 自己，綁在假核心／假 `AtpRegistry` 上的整套 v2 驗得過（repo 的 fork 測試就是這樣通過的） | **已修**：`verify()` 用 `vm.envAddress("ATP_EXECUTOR")`（沒設就失敗），並要求它等於 `deployments/mainnet.json` 的 `contracts.AtpExecutor`、它的 `registry()` 等於 `contracts.AtpRegistry`、檔案的 `chainId` 等於目前的鏈；immutable 比對用的核心也改成這個值。`foundry.toml` 因此允許讀 `deployments/mainnet.json`。fork 測試改呼叫明確傳入替身核心的 `verifyWith(executor, core)` | `test/script/DeployBorrowRoutingMainnetChecks.t.sol`（CI 會跑：沒設 env、不是檔案裡的核心、registry 不符、鏈不符都失敗）；fork `test_script_verify_coreIsAnchoredToTheManifest_notToTheContractsUnderVerification` |
| **I-1** `lens.routeDebt` 在該幣 Venus 本金為 0 時，每一條該幣的 Venus 路線都回整筆負債：後端加總會重複計算 | **已修（只改 lens）＋文件化**：本金為 0 時整筆只歸給帳戶第一個這個幣的 Venus 部位，其他路線與沒有部位的帳戶回 0；有本金時按比例的算法不變。連帶的行為：對 `routeDebt` 是 0 的路線送 `max` 不還任何錢（要清零頭就對有 `routeDebt` 的那條送 `max`，或傳明確金額），搬家離開這種路線時不會順便還掉零頭。後端的讀法寫在 §5 與介面 JSON（`venus.readingDebt`）：帳戶負債用 `tokenDebt`，不加總 `routeDebt`（測試網上的 draft5 lens 仍是舊行為） | `test_I1_routeDebt_interestWithoutPrincipal_belongsToOneRoute`、`test_I1_explicitAmount_repaysTheInterestThroughAnyRoute`、`test_I1_routeDebt_foreignDebtIsNoRoutes_andTheSplitByPrincipalIsUnchanged`；上面的 fuzz 每一步檢查兩條同幣路線的 `routeDebt` 加起來＝該幣負債（容許向上取整的 1 個最小單位）、不是部位的路線是 0 |
| **I-2** `AtpBorrowRegistryV2` 24,187 bytes，離 EIP-170 上限只剩 389 | **文件化，沒改程式**：這一輪的修正都不動 registry（大小不變）。之後 registry 要加任何邏輯，得先把東西搬到 lens 或 executor（lens 剩 2,424、executor 剩 6,170） | §2 的大小表 |
| **I-3** 主網 `verify()` 的「名單以外沒有別的」只涵蓋路線與 vault；多加的借款幣、激勵代幣、資產分級、`venusMarket` 對應、`venusBlocksPerYear` 查不出來（「沒有路線但有分級＋vToken 對應」的資產會替 Venus 帳戶多算預算） | **主網前待辦**（這次不改程式） | 下面的清單 |
| **I-4** 演練腳本在共用測試網上調緊正式路線的線，兩筆交易之間其他帳戶可能被減倉 | **已修**：減倉那三步只在本機 Anvil fork 上跑，公開鏈自動跳過（§12） | `script/testnet/RoutingDemoTestnet.s.sol` |
| **I-5** 健康度用 Venus 的 collateral factor，不是 liquidation threshold（主網 vNVDAB／vTSLAB 是 CF 60%／LT 70%，vUSDT 80%／80%）。水位上是保守的；帳戶同時有 LT÷CF 比例不同的抵押品時，「健康度不下降」的比較對真正的清算線會有幾個百分點的偏差。只有 bStock 抵押時不受影響 | **主網前待辦**（這次不改程式） | 下面的清單 |
| **I-6** v1 與 v2 同帳戶（只有測試網有 v1）：沒有任何 v2 部位的帳戶，v2 的 `executeReduce` 可以把 v1 放的 Venus 抵押品取回到帳戶本身，直到全帳戶 LTV 到 v2 的目標線。沒有越過安全線，資產也只回帳戶本身 | **主網前待辦**（這次不改程式）；測試網照舊靠後端「一個帳戶只用一套」的規則（§12） | 下面的清單 |

**主網前待辦（第三輪留下的）：**

1. **I-3**：決定 `verify()` 要不要補上借款幣、激勵代幣、資產分級、`venusMarket` 對應、`venusBlocksPerYear` 的「名單以外沒有別的」。registry 沒有空間再加列舉用的 getter（I-2），做法是掃 registry 的設定事件跟名單核對。
2. **I-5**：決定 Venus 的健康度（清算價值）要不要改用 liquidation threshold；要上 LT÷CF 比例跟 bStock 不同的 Venus 抵押品之前一定要先定。
3. **I-6**：主網不部署 v1 借貸（`deployments/mainnet.json` 現在沒有），或在合約層做 v1／v2 互斥；不能只靠後端規則。
4. 修正後的 L-1 再給審查員看一次（審查員的要求）。
5. 審查員另外列的：兩組主網 fork 測試用釘區塊的 archive RPC 跑完整一次（CI 不跑 fork 測試）；session key 的 CallPolicy／paymaster 規則與簽名 policy 的整合測試；owner 換 Safe／timelock、`rateReporter` 用獨立金鑰。

