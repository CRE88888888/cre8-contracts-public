# 生息市場、存領與估值（#40／#41／#42，PR #49）

測試網第二批合約介面。主網 manifest、`AtpMainnetSpecs`、`DeployAtpMainnet` 不變；本次只有本機 fork 交易。完整設定承諾／24 小時改設定仍屬 #28，hold／stack 沿用 `Version.scheduleHash`。

## 市場與權限

executor 在 constructor 自行建立空的 `AtpYieldRegistry` 並 immutable 綁定，沒有替換入口。registry 以 bytecode 固定連結外部 `YieldView` library，沒有更換入口；library 只含 view 函式、沒有 storage／owner／資產批准／可變設定，透過固定 library 呼叫共用讀值碼。補息、checkpoint、權限與曝險帳本仍在 registry。部署腳本先以 CREATE2 部署 library，再以固定地址連結 executor，避免 constructor 包進所有模組部署碼；冪等重跑重用同一 library。registry／executor 參照、市場 chain／asset／receipt／target／riskSource 不可覆寫，receipt 不可重複，也不能成為其他市場的 underlying。退休永久停新供給，保留估值與退出。生息 target／receipt／riskSource／yield registry 都不可當 swap venue 或 spender，執行時再次檢查。

帳戶本人透過 `setYieldPolicy` 同意，綁 enrollment strategy／version；重 enroll 要重新同意。operator 不能代同意。新供給受每帳戶／underlying 每 24 小時一次、同意的 raw 金額上限、使用率、協議 cap、跨帳戶集中度限制，不收換幣費、不耗買入配額。

**50 USDT 下限使用保守估值**：USDT 直接比較 raw 金額；其他資產使用 `oracle.previewSwap(...).minimum`（含 slippage 後地板），不是 `quoted`。因此 quoted 剛好 50 USDT、minimum 小於 50 時仍拒絕。這是刻意保留的安全界線。

純領出忽略 enrollment 暫停、現有版本資產清單、退休、供給啟閉／頻率／額度及買入配額。rate 上漲／下跌／越過 minRate 或 maxRate 均不鎖領出；typed redeem、精確餘額差及正數 `minAssets` 仍約束每筆輸出。真正 `globalPaused` 仍停止 executor，owner 可直接操作協議／轉出收據；協議無現金或自身停止領出則仍可能失敗。

## ABI 交接（backend／session／paymaster）

backend 讀 artifact 部署需先連結 YieldView，使用 manifest 的 `contracts.yieldView` 設定 `DAPP_LIBRARIES` 後重新編譯，再讀取 bytecode；未連結的 executor／registry 產物含 placeholder，不能直接部署。

所有 amount 為 raw 整數，kind：`1=Venus`、`2=Lista`、`3=Aave`。chain 97 marketId：`keccak256(abi.encode("cre8.testnet.yield.v1", uint8(kind), underlying))`。

| 合約 | ABI | 用途 |
| --- | --- | --- |
| executor | `executeSupply(address,bytes32,uint256,uint256,uint256)` | 同一帳戶存入；selector `0x5728db07` 不變 |
| executor | `executeWithdraw(address,bytes32,uint256,uint256,uint256)` | 同一帳戶純領出；selector `0x63f865c0` 不變 |
| executor | `previewAccountValue(address)`、`previewBuyAllowance(address)` | 用 eth_call，在同一快照補息、對帳後取保守 NAV／買入額度 |
| yield registry | `setYieldPolicy(bytes32,uint256,bool)`、`requestExit(bytes32)` | 帳戶同意／停止供給；只給 owner，不給 session |
| yield registry | `markRiskExit(address,bytes32)` | permissionless 風險標記，不搬資金 |
| yield registry | **第二輪新增** `reader() returns(address)` | bytecode 固定的 `YieldView` library，地址同時列入 manifest |
| executor | **第二輪新增** `YIELD_QUOTE_TOLERANCE_BPS() returns(uint256)` | 固定 10 bps，沒有調整入口 |
| yield registry | **新增** `reconcile(address,bytes32)` | permissionless 向下對帳，回收幽靈曝險，不增加 tracked units |
| yield registry | **新增** `accountMarkets(address) returns(bytes32[])` | 帳戶仍有 tracked 部位的市場；買入只掃這個清單 |
| yield registry | **新增** `acknowledgeIdentity(bytes32,bytes32 expected)` | owner 審核實作／IRM 後，必須與即時 identity 完全相同 |
| yield registry | `acknowledgeConfiguration(bytes32,bytes32 expected)` | owner 確認即時設定；不受 U>80% 阻擋 |
| yield registry | `acknowledgeRate(bytes32)` | owner 明確確認 loss／jump；不改配對、部位或用戶同意 |
| yield registry | **新增** `widenMaxRate(bytes32,uint256)` | owner 只能提高上界；不能降低上界或改 minRate |
| yield registry | `quoteSupply(bytes32,address,uint256)`、`quoteWithdraw(bytes32,uint256)` | 用 eth_call，補息後的可信 min 基準 |
| yield registry | `refreshHealth(bytes32)`、`health(bytes32)` | 前者補息後讀 S／L／U／configuration，後者唯讀（可能 stale） |
| yield registry | `market(bytes32)`、`marketCount()`、`marketIds(uint256)` | 全市場准入清單，上限 64 |
| yield registry | `units(bytes32,address)`、`receiptAssets(bytes32,address)` | 記帳 units／保守 tracked underlying 債權 |
| yield registry | `totalUnits(bytes32)`、`accountUnits(address,bytes32)`、`exiting(address,bytes32)` | 全平台及帳戶曝險、風險退出狀態 |

**移除 ABI**：`reserveSupply`、`releaseReservation`、`reserved`、`totalReserved`，以及只供 executor 使用且重複補息的 `syncForWithdraw`；容量上限常數 getter `MAX_MARKETS()` 也移除（內部上限仍是 64）。沒有跨交易預留；存前檢查與實收後複核都在 `executeSupply` 同一筆交易完成，失敗整筆還原。這是 #1 採用的最簡單作法，不需要過期回收、持幣證明或 owner 清佔位。

新增事件：`ExposureReconciled(account indexed,marketId indexed,removed)`、`MarketIdentityAcknowledged`、`MaxRateWidened`。移除預留事件 `SupplyReserved`／`ReservationReleased`。constructor 錯誤改為 `InvalidConstructor()`。executor 專用 hook `recordWithdraw` 增加第 4 個 `trackedBefore` 參數，防止 redeem 回呼中的 permissionless 對帳重複釋放容量；backend 不呼叫此 hook。原 `SupplyExecuted`／`WithdrawExecuted` 參數與 indexed 欄位不變；raw assets、shares、remainingReceipts 都取實際結果，失敗不留成功事件。完整 ABI 以 `forge inspect AtpExecutor abi`／`forge inspect AtpYieldRegistry abi` 為準。第二輪另取 `forge inspect YieldView abi` 合併 library 的錯誤解碼；原協議讀值 error selectors 照常向外傳遞，部分讀值 error 不再出現在 registry 的內聯 ABI。存領 selector、事件與 constructor 參數均不變。

Venus／Lista 公開 shares 是 receipt raw；Aave 是 aToken raw，內部 accountUnits／totalUnits 使用 scaled units 與完整 ray index，不可混用。

新 session CallPolicy 只加兩個 executor 存領 selector；underlying／receipt approve 與 policy 仍須 owner 執行。舊 session 不會自動升權。paymaster 需解碼 canonical calldata，供給不可冒充 exit；成功需同時確認 UserOp、executor 事件與餘額／收據。

`quote*` 是 non-view，供 eth_call 在單一狀態補息。供給與領出皆要求 `min > 0`、`min ≥ floor(執行時 quote × 9990 / 10000)`，且真正實收 `≥ min`。10 bps 是合約常數，owner／operator 均不能調大。backend 可用報價的 9995/10000（向下取整，仍須正數）構造簽名 min，保留另一半帶寬給報價至執行的漂移；舊 quote 的 9990/10000 恰在邊緣，rate 上升時領出仍可能低於執行地板；過久或異常變動超出容差時須重新報價、重新簽名，不能繼續降低 min。更嚴格的用戶 min 仍約束實收。Kernel AA smoke 使用 APR 非零的 USDT Venus，在 quote 後明確增加時間並挖至少一區塊，再經 session／alto／paymaster 執行存領，核對成交區塊與報價區塊。沒有將 APR 設 0 的繞法。

dust 領出時，floor 向下取整會使相對容差大於名目的 10 bps；例如 quote=3 raw 時 floor=2 raw，相對差為 33.3%。這只放寬極小整數的守門門檻，協議實收仍為真實贖回值且須滿足簽名 min，沒有實際損失；供給有 50 USDT 下限，不會遇到此 dust 情境。

## 容量、對帳、退出與保守估值

存前以 `C + incoming ≤ min(floor(S/100),floor(L/10))`（含等號）檢查，成功後以實收 units、向上取整曝險再檢查同一存前限額。交易原子執行，沒有可長期佔用的 R。`C` 僅為經 executor 計帳的 tracked units 換算，利息仍算曝險，不掃帳戶陣列。協議 supply cap 另讀 Venus comptroller、Lista maxDeposit、Aave whole-token cap（0 表示協議無額外上限）。cap 耗盡仍保留領出。

外部轉走／直接 redeem 後，`reconcile`、`syncAccount`、`recordWithdraw` 以 `min(tracked, actual)` 向下收斂並減少 totalUnits。actual ≥ tracked 的差額是外部捐贈，不增加曝險，不阻擋供給。新供給只增加本次實收差額。買入只掃帳戶有 tracked 部位的市場，退休／舊版本部位仍保留；tracked 歸零即從持倉清單移除。外部轉入、未經 executor 供給的收據不增加 NAV／買入額度，屬保守低估；無需掃全 30 個市場發現捐贈。

群組上限只約束經 executor 計帳的部位；合作帳戶可轉走收據再 reconcile，騰出可再供給的 tracked 容量，因此不是協議內所有合作持有人的實際曝險上限。領出先扣 tracked，再扣外來收據，也可能低估剩餘實際持有量；此限制不增加 NAV／買入額度。

U≤80% 才可新增；只有 rate 相對 checkpoint 下跌、讀值失敗／過期或 U≥90% 可 permissionless 標記退出。rate 上跳（含超 maxRate）或單獨 configuration hash 變動不觸發退出，仍維持供給准入檢查。`requestExit` 停止同意，持倉風險旗標保持到 tracked 部位領清／對帳歸零。一般部分領出不新增 exiting；既有風險旗標仍保持。空帳戶不能被風險標記鎖住。receipt 讀值失敗時仍可 requestExit；`reconcile` 成功讀 receipt 後，原 tracked=0 **或** actual=0 就直接清旗標，不要求重新同意；`setYieldPolicy(enabled=true)` 在 tracked=0 且 receipt 可讀時也能清旗標。清旗標不會重新啟用已停用的 policy；可辨識的外部 dust 不製造退出風險。

Venus 同區塊核對 cash／borrows／reserves。Lista queues 各最多 16 項，忽略無曝險的舊退出項目；供給目的地仍核對 asset／IRM／供借量／資料時間，超過 60 秒或未來時間拒絕，剛好 60 秒接受。共享 core 的多 vault 將全份曝險保守算入每個可能目的地，取最小 S／L，不相加共用 core 現金。Aave 取 actual／virtual cash 較小者。必要資料讀取失敗仍 fail closed。

供給與領出 min 均須正數，且不得低於執行時可信 preview 的固定 9990/10000 地板。typed target／receiver／calldata 不可任意變更；供給精確 approve 本次金額後清零。實扣 underlying、receipt／scaled units、外部回傳與實收差額都核對，不吃 executor dust。Venus 非零錯誤碼整筆失敗。Aave mint／餘額向下取整，transfer／burn scaled units 向上取整。Lista maxRedeem 雙重向下取整，只豁免一個 underlying raw 對應的整數差，用戶簽名的 minAssets 與固定地板均仍執行。

NAV 不重複加本金或 accrued interest。rate 超過自動接受的 100% 名目年化＋一個 receipt raw 取整界線，或越過 rate bounds，僅停新供給；異常上漲 NAV 取 checkpoint 與實際值的較小者，下跌取實際值，不因 loss／jump revert，也不自動重設異常 checkpoint。缺失／零 rate、identity 改變仍 fail closed。owner 必須用即時 expected hash 明確確認 identity；配置變動不鎖估值／syncAccount，仍停新供給直到確認，確認不受 U>80% 影響。確認配置不會自動允許高 U 供給。

捐贈 underlying 造成的 rate 上跳仍可暫停整個群組新供給：checkpoint 剛更新時捐贈約 TVL/365，100% 名目 APR 成長帶寬要約一天追上（回歸中 23 小時仍拒絕、25 小時恢復），不影響 NAV／typed 退出。此為 C3 接受的供給可用性限制。

`minRate` 沒有放寬入口；跌破初始 rate/2 後，若 rate 未自行恢復至該下界，該市場永久不能供給，即使 owner acknowledgeRate 也不改下界，同一 receipt 不能重新登記。退出與保守 NAV 不受此下界鎖住。

## 主網准入界線

**主網部署路徑待 [issue #50](https://github.com/CRE8Finance/cre8-contracts/issues/50)**：補 chain 56 的 YieldView library bootstrap、固定連結與部署 pin；目前 `DeployAtp`／`DeployAtpMainnet` 不可作為可用部署路徑。此 PR 不處理該 issue。

typed actions 用 BSC 真 Venus／Lista／Aave fork 驗相容性，與准入分開。正式 registerMarket 要求可觀測的 implementation getter，pin target／receipt／riskSource 的實作位址及 codehash；沒有可靠 getter 就拒絕。fork 回歸測試直接證明三協議主網地址缺此證明時無法 register。沒有新增主網可信證明服務或 whitelist；正式准入來源仍需 C3 決定。主網 Lista 僅允許核實的 adaptive IRM，不豁免未知／fixed／broker 模型。

## chain 97 mocks、owner 剩餘權限與部署

C3 2026-11-16 最終表實際 **30 列（Venus 21、Lista 4、Aave 5）**，標題「32」未自行補兩個。沿用 USDT＋20 個資產，年化以 bps（最小 1 bps）保存，不含 NVDAB Lista 異常 27% 市場。Venus receipt 8 decimals、Lista 18、Aave 同 underlying。manifest aprBps 是初始值，即時讀 target／aToken；畫面標「模擬利率」，不能當主網收益。

背景供給為每市場 1,000,000 USDT baseline 等值，receipt 給測試 owner。利息只能按時間／APR mint 給市場自身。**mock owner 僅保留 `setAprBps`（0–10,000）及明確用於退出劇本的 `setLiquidity`**：後者只更改模擬借款記帳，現金始終留在 Venus／Lista mock 或 Aave aToken 內，模擬恢復不轉帳、不要求 owner 出資或 approve。未被模擬為借出的現金才可贖回。移除 owner pause／錯誤碼／cap／exchangeRate／reserves／riskCore／exitFee／performanceFee／feeRecipient setter；Lista exit fee／performance fee 固定 0、feeRecipient 固定部署 owner。保留真 ABI getter 供風控讀值。部署用 mock 不模擬 pause／錯誤碼／cap／exitFee 情境；這些 getter 固定初值，相關錯誤路徑只由測試 fixture 驗證，不能用公開測試網演練。異常協議控制僅存在 `test/atp/YieldAdversarialMocks.sol` 的測試 fixture，不部署到測試網。

owner 仍持有背景收據，可像一般持有人贖回自己的份額；代幣 owner／faucet／operator／keeper 原有權限不變。這些是測試幣環境，無公開鏈操作。此 PR 不變更既有 TestnetToken 的管理權限。

`MockLista.market().lastUpdate` 回傳實際 `lastAccrual`，60 秒失效可以實測；不是把每次讀取時間當成已補息。

`DeployTestnet` 每輪預設處理 8 個生息市場，全部完成才移交／匯出 manifest。部署預算用 300% gas estimate，涵蓋模擬同 timestamp 無利息、廣播跨區塊卻需 mint 的分支（不降低 min，費用仍按實際 gasUsed）。seed 只 mint DEPLOYER 的不足額；已 seed 尚未 register 時先 broadcast 補息再計 health，支援中斷續跑。CREATE2／minter／seed／登記可冪等重跑。fork 的 wei 餘額比較使用任意精度整數，避免 Bash signed-int64 溢位；預演驗 2／11 tBNB 重跑均零交易、manifest 與餘額不變。固定 library 連結設定會進入所有編譯產物的 metadata，因此本輪除 executor／yield registry／mock 外，既有測試幣／AMM／oracle／registry／paymaster 的 CREATE2 位址也會重產。角色不變，後端須整份更新 manifest，不能只替換 executor。library 先以未連結自身的獨立產物部署，再固定連結其地址；部署開始前與 manifest 匯出前都核對 library：連結地址必須等於 `DeployYieldView` 依未連結 initcode hash 計算的 CREATE2 地址，runtime hash 也必須符合未連結產物的 pin，不符立即失敗。

keeper／smoke 的 `TestnetBook` 也必須使用相同連結設定，否則會推導出不同的 token／feed 地址。`fork-e2e.sh` 已由 manifest 自動傳遞；單獨操作 keeper／smoke 前先執行：

```bash
export DAPP_LIBRARIES="src/atp/yield/YieldView.sol:YieldView:$(jq -er '.contracts.yieldView' deployments/testnet-97.json)"
```

`deploy-97.sh` 的 library bootstrap 會先排除繼承的 `DAPP_LIBRARIES`，避免 library 的自身連結 metadata 改變 CREATE2 位址；核心部署再固定連結。`YieldViewPin` 的 initcode／runtime hash 取自未連結產物；bootstrap 及回歸測試會核對 pin 與實際產物，避免誤用連結後 metadata。runtime 比對只遮掉 library 開頭 PUSH20 的 self-address 槽；目前全 view 的 via-IR 產物沒有該槽，連 metadata 一起完整比對。未來若原碼或編譯設定變動，須以未連結 build 更新兩個 pin 並重新核對 CREATE2 位址；不能沿用舊 pin。

本機驗收僅使用 8581：

```bash
anvil --fork-url https://bsc-testnet.publicnode.com --chain-id 97 --port 8581 \
  --hardfork cancun --prune-history --retries 15 --fork-retry-backoff 1500 --timeout 90000
FORK_RPC=http://127.0.0.1:8581 TESTNET_ALLOW_UNMERGED=1 ALTO_DIR=/tmp/alto ALTO_PORT=3081 \
  bash scripts/testnet/fork-e2e.sh
pkill -f "anvil.*--port 8581"
```

fork-e2e 驗新部署／零交易冪等重跑、92 資產買賣、30 市場供給／一年補息／高 U 部分退出／恢復／重試全退、keeper 兩輪。Kernel smoke 使用 Anvil 公開測試身分，不讀 `~/.cre8-testnet`；本機 paymaster immutable signer 暫換，finally 還原並核對原 code。CallPolicy 包含三個 executor selector，session＋paymaster 實際跑供給／領出；領出 call gas 採 alto 估算的 2 倍，重新簽 final gas limits 的 paymaster 資料，使用固定 10 bps min；APR 全程非零且不寫入；直接轉帳、改同意、錯 signer、無 paymaster 仍拒絕。

## 第一輪審查驗收（歷史，2026-11-16）

Solidity 來源 `eafc1a6`，最終預演腳本與 manifest 來源 `84e70fd`。在全新 chain 97 fork、上游區塊 **142950829** 驗收，只使用 8581、`--prune-history`；沒有公開交易／真金鑰。結束已精準停止自己的 8581 anvil 與 3081 alto，兩埠均釋放。

- `forge fmt --check`、三支 shell `bash -n`、Kernel TypeScript bundle：通過。
- `forge build --sizes`：通過。executor runtime **21,752**、creation **48,408**、含 constructor args 的 initcode **48,664**；yield registry runtime **24,562**、creation **24,884**、含 args **24,948**。測試 harness 含 args **49,054**。全數低於 EIP-170／3860；**registry 僅餘 14 bytes**，新增功能前必須先處理模組拆分／大小。
- `FOUNDRY_PROFILE=ci forge test`：**452 passed、0 failed、5 skipped**（26 suites）；skip 是既有未設 RPC 的 fork setup，沒有新增 skip。
- `BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test`：**475 passed、0 failed、0 skipped**（26 suites），含真三協議存領與三個主網缺 implementation 證明的拒絕測試。
- 修前快照 `74d2292` 的反向 PoC／續跑／gas 回歸：**20 failed、1 passed**；另先重現捐贈收據 NoFloor／sticky exit 與 redeem 回呼對帳重複釋放曝險，再修正。保留舊測試的安全界線，舊預留案例依原子供給改寫。
- 完整 `fork-e2e.sh`：**exit 0，全過**。92 資產買賣；30 市場供給／一年補息／高 U 部分退出／恢復／重試歸零，30 個業務事件集合與鏈上狀態逐一核對；2／11 tBNB 各自重跑皆 **0 交易、manifest 與餘額不變**；312 個地址有 code。
- 生息供給 **182 筆／73,383,150 gas**，退出 **150 筆／42,063,971 gas**。keeper 兩輪為 277／92 筆、20,134,770／10,992,869 gas。
- Kernel＋session＋自有 paymaster 全過：owner approve **277,473**、3 買入 rebalance **1,344,156**、供給 **1,620,897**、領出 **517,513 actualGasUsed**。收據與 tracked 歸零；越權轉帳、改 policy、錯 signer、無 paymaster 四項均拒絕。APR 還原為 300 bps、paymaster 原 code 還原核對通過。

整套部署實際收據：

| 輪 | 交易數 | gasUsed |
| --- | ---: | ---: |
| 1 | 517 | 883,387,426 |
| 2 | 480 | 853,777,004 |
| 3 | 274 | 285,456,813 |
| 4 | 95 | 25,384,576 |
| 5 | 72 | 17,383,772 |
| 6 | 478 | 39,836,199 |
| 合計 | **1,916** | **2,105,225,790** |

供給／領出 gas（本機 owner account 內 quote＋執行，不是 UserOp）：

| 協議 | supply | partial | retry |
| --- | --- | --- | --- |
| Venus | 1,269,915–1,381,200 | 209,896–236,180 | 215,786–235,584 |
| Lista | 1,400,960–1,470,365 | 302,654–309,234 | 280,404–286,960 |
| Aave | 1,303,450–1,379,803 | 237,154–252,865 | 222,224–223,228 |

單次真買入 gas fixture（30 個市場皆無持倉；同一 cold/warm 規則）：

| 版本 | 空登記器 | 30 市場 | 額外 gas |
| --- | ---: | ---: | ---: |
| 修前 | 402,269 | 1,488,461 | **1,086,192** |
| 修後 | 402,671 | 402,787 | **116** |

同一筆買入總共少 1,085,674 gas。這是回歸 fixture，實際 UserOp 還需加 Kernel／paymaster 成本；有持倉只為其持倉市場補息／估值。

預演額外修正：部署補息在同 timestamp 估算沒有 mint、廣播才進 mint 分支，39,989 gas limit OOG（實需估算 59,388），改部署 300% 預算並實測中斷續跑 558 筆成功；11 tBNB 超過 Bash signed-int64，原本零交易重跑仍誤改餘額為 10，已修任意精度比較及狀態斷言。Kernel 領出 279,994 call gas 不足，改估算 2 倍並重簽 final paymaster 資料；APR 還原另有 53,178 gas OOG，改控制預算及 receipt／區塊讀值核對。合約、min／授權／歸零斷言未放寬。

### 第一輪位址與後端交接（歷史）

- executor：**`0x79D50A5007DaAe63eDD696Ce6DD1b88Ae1Bce8C8`**。
- yield registry：**`0xFa3aE1EAdE0e84E29320b28f8AF8cB3449634f34`**。
- 30 市場 target／receipt 見 `deployments/testnet-97.json` 的 `yieldMarkets[]`。既有 assets／roles、registry／router／paymaster 等其他核心地址與修前完全相同。主網 manifest／AtpMainnetSpecs／DeployAtpMainnet／lib 均未改。
- 依前述 ABI 表重產兩份 ABI；存領 selector 與業務事件維持。後端以 tracked／exiting 對帳；remainingReceipts 仍是實際持有量，可能含未 tracked 捐贈，不能僅以 dust 非零永久重試。

### 第一輪 tBNB 需求（歷史）

依提供的 deployer **1.343 tBNB**、既有角色分發＋paymaster 存款 **0.98 tBNB**，使用完整部署實際 gas 計算。下表的 20% 只加在部署 gas；CLI 300% gas limit 是交易執行預算，沒有把它當成實付費用。gasUsed 隨區塊時間／池子暖機略有變動。

| 項目（tBNB） | 0.1 gwei | 0.2 gwei |
| --- | ---: | ---: |
| 基本總需求 | 1.190522579 | 1.401045158 |
| 對 1.343 的餘額（負數為不足） | 0.152477421 | -0.058045158 |
| 含 20% 部署 gas 餘裕的總需求 | 1.232627095 | 1.485254190 |
| 含餘裕後的餘額 | 0.110372905 | -0.142254190 |

第一輪待辦為 C3 決定公開部署 gas price／補款餘裕，並協調後端 ABI、地址、owner 升權與報價整合（第二輪已改固定 10 bps 容差）；0.2 gwei 基本不足約 0.05805 tBNB，含 20% 部署 gas 餘裕不足約 0.14225。正式送出前仍須重新讀餘額／費率。主網准入的 implementation 證明來源仍維持待定、缺證拒絕，這次沒有公開部署。


## 第二輪複審最終驗收（2026-11-16）

合約來源 `7d6ccca`，部署／完整預演來源 `ccf994a`（含 `988f038` 的 library pin 修正）。全新 chain 97 fork，固定上游區塊 **142959423**，僅 8581、`--prune-history`。沒有公開交易、合併或真金鑰讀取；結束精準停止自己的 8581 anvil，alto 的 PID trap 已收尾，8581／3081 均釋放。

- 修前最初 17 個第二輪回歸：**6 passed、11 failed、0 skipped**。PoC 新案例轉入 `AtpYieldReview2.t.sol`，原 f1–f10 留在 `AtpYieldReview.t.sol`；本輪共新增 21 個專屬案例，包含六個三協議跨區塊存領、地板等號／低 1 raw、零 min／quote、實收不足、過舊報價、捐贈／rate 下跌／U 邊界／失敗或 stale 讀值，以及 C3 接受的記帳限制。
- `forge fmt`／`forge fmt --check`、三支 shell `bash -n`、Kernel TypeScript bundle、完整 diff 檢查通過。
- `FOUNDRY_PROFILE=ci forge test`：**517 passed、0 failed、5 skipped**（27 suites），skip 僅既有未設 RPC 的 fork setup。
- `BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test`：**540 passed、0 failed、0 skipped**（27 suites）。
- `fork-e2e.sh` **exit 0**，不是中途紀錄。2／11 tBNB 兩次重跑皆 **0 交易、manifest 與餘額不變**；獨立 library 也零交易重用。keeper 更新 feeds、92 資產買賣、30 市場生息／部分風險退出／重試全退，業務事件與鏈上歸零均核對通過。
- exporter 驗 313 個列出位址；另對 contracts／assets／yieldMarkets 去重後 **348 個唯一合約地址全部有 code**。
- 生息供給 **182 筆／73,669,906 gas**、退出 **150 筆／43,360,044 gas**；keeper 兩輪 **277 筆／20,163,367 gas**、**92 筆／10,982,307 gas**。
- Kernel 使用 **Venus.USDT APR 500 bps（5%）**，全程不寫 APR。供給 quote／成交區塊 **142962051 → 142962053**；領出 **142962053 → 142962055**。session＋自有 paymaster 實際供給 **1,689,629**、領出 **503,927 actualGasUsed**，實收超過簽名 min、receipt／tracked 歸零、APR 保持 500 bps、paymaster 原 code 還原。改同意、轉帳、錯 signer、無 paymaster 四項拒絕均過。owner approve **277,473**、三買 rebalance **1,341,759 actualGasUsed**。

### 最終大小（bytes）

沒有調高 EVM 大小限制。initcode 包含實際 constructor 參數；linked library 不包在 executor constructor 內。

| 合約 | runtime | EIP-170 餘裕 | initcode 含參數 | EIP-3860 餘裕 |
| --- | ---: | ---: | ---: | ---: |
| AtpExecutor | 21,819 | 2,757 | 41,197 | 7,955 |
| AtpYieldRegistry | 16,937 | 7,639 | 17,414 | 31,738 |
| YieldView | 12,402 | 12,174 | 12,432 | 36,720 |

`forge build --sizes` 的 creation code（未含參數）分別為 executor **40,941**、registry **17,350**、library **12,432**；鏈上 runtime 另逐一驗證相同。三者全部至少保留 1,000 bytes。

### 本輪部署收據與 gas

| 輪 | 交易數 | gasUsed |
| --- | ---: | ---: |
| library | 1 | 2,739,684 |
| run 1 | 517 | 881,237,282 |
| run 2 | 561 | 864,761,846 |
| run 3 | 283 | 286,770,116 |
| run 4 | 98 | 25,867,022 |
| run 5 | 72 | 17,380,228 |
| run 6 | 509 | 42,889,634 |
| 合計 | **2,041** | **2,121,645,812** |

| 協議 | supply | partial | retry |
| --- | --- | --- | --- |
| Venus | 1,276,147–1,385,760 | 231,670–256,430 | 232,480–236,969 |
| Lista | 1,404,688–1,474,518 | 323,076–329,656 | 299,907–306,475 |
| Aave | 1,309,495–1,385,948 | 259,010–260,288 | 238,984–243,464 |

以上為 owner account 同區塊 quote＋執行，Kernel 數字另列；CLI gas budget 倍率不當成實付 gasUsed。

### 本輪新位址與 ABI

| 合約 | 僅本機 fork 預演位址 |
| --- | --- |
| executor | `0xE3725CBdC1B4BE58ed9b49E6f863cDDE654bbfce` |
| yieldRegistry | `0x80d3A6AD26dBE4b33bC6fe4abD38b1E1D78cBd14` |
| yieldView | `0xC8EEBa84f9C74B2D879dFaEdb02a0a523aA02657` |
| registry | `0x7D39178401923140dF8b5A559a02682326F17350` |
| router | `0x8e9371550fC397144D198A7C159C2DA5D143239E` |
| usdt | `0x7Ad6E310B0F6744B66d97Cb7cb525BD974501cb5` |
| paymaster | `0x797bB6961A570BD68b0550C7F0e9F16D12101b1b` |

與 `8abbc61` manifest 比較，角色完全相同；**92 組 assets 的 298 個地址欄位、30 個 yieldMarkets 都有更新**。marketId 隨 underlying 地址重算，不能沿用舊市場 ID／policy。ownedDeployer／USDT feed 也更新；canonical EntryPoint／Permit2／V3 基建及 GasPolicy 維持。後端必須整份重載 manifest，不能只換兩個主合約地址。

本輪 ABI 僅新增 executor `YIELD_QUOTE_TOLERANCE_BPS()`、registry `reader()` 與獨立 `YieldView` ABI；原存領／constructor／業務事件不變。錯誤解碼合併 library ABI，`YieldMinimum.required` 改為固定 10 bps 地板；簽名 min 可用 9995/10000 留漂移空間。舊 session 不會自動升權，沒有 DB schema 改動。

### 依 0.1／0.2 gwei 重算 tBNB

基準仍使用提供的 deployer **1.343 tBNB**、角色分發＋paymaster **0.98 tBNB**；部署 gas 使用本輪實際收據。20% 只加在部署 gas，沒有讀真金鑰或送公開交易。

| 項目（tBNB） | 0.1 gwei | 0.2 gwei |
| --- | ---: | ---: |
| 部署 gas 費 | 0.2121645812 | 0.4243291624 |
| 基本總需求 | 1.1921645812 | 1.4043291624 |
| 對 1.343 的餘額 | 0.1508354188 | -0.0613291624 |
| 含 20% 部署 gas 餘裕的總需求 | 1.23459749744 | 1.48919499488 |
| 含餘裕後餘額 | 0.10840250256 | -0.14619499488 |

C3 仍須決定公開部署費率／補款餘裕，並協調後端整份 manifest／ABI／owner session 交接；0.2 gwei 基本不足 **0.0613291624 tBNB**，含 20% 部署 gas 餘裕不足 **0.14619499488 tBNB**。主網 implementation 證明來源仍維持缺證拒絕，這輪沒有新增主網准入或公開部署。

自我 review／失敗後修正：第一版拆分仍將 module creation code 包在 executor，initcode 53,681 超限，改為固定連結、獨立 CREATE2 library；部署驗出自身連結 metadata 導致 library CREATE2 hash 誤算，改核對固定連結地址；接著 keeper 實跑重現未傳遞連結設定而 `feed.USDT/USD: not deployed`，已統一全工具設定並排除 bootstrap 的繼承設定。最後從全新 fork 重跑全套，沒有跳過失敗階段。合約的正數 min／實收／權限／容量／oracle 地板與歸零斷言維持。
