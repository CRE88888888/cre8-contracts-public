# 策略加息（抵押借款）測試網手冊（#64）

只在 BSC 測試網 chain 97。依據 docs `docs/EARN_UX.zh-TW.md`（§B 策略加息、§C 測試網、§D 安全參數）。主網沒有部署、`src/atp/` 既有合約沒有改動。

## 1. 做了什麼

每一檔投資組合（一個 smart account）可以：把資產存進「該資產固定的那一個」借貸市場當抵押 → 以保守比例借出 USDT，**同一筆交易直接存進白名單 USDT vault** → 需要時從 vault 領回還款 → 取回抵押。借出的 USDT 從頭到尾不會以現金出現在帳戶裡，任何函式都沒有收款人參數；還清後 vault 剩下的部位只會回到同一個投資組合帳戶。

| 合約 | 用途 |
| --- | --- |
| `src/atp/borrow/AtpBorrowExecutor.sol` | 唯一搬錢的合約：`executeSupplyCollateral`、`executeBorrow`（借＋存 vault）、`executeRepay`、`executeDeleverage`（任何人可呼叫）、`executeWithdrawCollateral` |
| `src/atp/borrow/AtpBorrowRegistry.sol` | 由 executor 建立並永久綁定。市場清單、每個資產固定市場、帳戶同意、CRE8 總借款上限、LTV 線、使用率／利差檢查、讀取函式 `status` |
| `src/atp/borrow/BorrowReader.sol` | 只用 Venus／Moolah 真實 ABI 讀部位、價格、利率、使用率，換真市場不用改 |
| `src/testnet/lending/` | 模擬 Venus（comptroller＋vToken，含 delegate、清算）、模擬 Lista Moolah（含清算、壞帳）、owner 可調價 oracle、策略用 USDT vault（`MockEarnVault`）。都有可設定利率與激勵 |

為什麼另開合約、不改 `AtpExecutor`：既有 executor 已部署、後端與 session policy 綁著它的地址，而且只剩約 2.8 KB 空間。新合約共用同一個 registry、yield registry、numeraire 與 `globalPaused` 總開關。

## 2. 安全規則（合約強制）

LTV ＝ 負債價值 ÷ 抵押價值，用市場自己的 oracle（也就是會清算的那個價格）。F ＝ 市場的抵押率（Venus collateral factor／Lista LLTV；在這兩個模擬市場裡也是清算線）。

| 規則 | 值 | 合約位置 |
| --- | --- | --- |
| 目標 LTV（借款與取回抵押後不得超過） | min(類別上限, F/2, owner 設定)；類別：指數與大型股 35%、一般個股 30%、跟幣價連動的股票 20%。槓桿類沒有類別、無法上架 | `targetLtv(id)`、`setLtvConfig` 只能更保守 |
| 自動減倉線 | LTV ≥ 清算線 × 2/3 時任何人可呼叫 `executeDeleverage`，從該部位自己的 vault 份額還款回到目標 LTV | `deleverageLtv(id)` |
| 借款市場使用率 | 借完後 > 85% 不借 | `MAX_BORROW_UTILIZATION_BPS` |
| vault 使用率 | > 90% 不存新錢（不借）；> 95% 任何人可呼叫 `executeDeleverage` 收掉 | `MAX_VAULT_SUPPLY_UTILIZATION_BPS`、`VAULT_EXIT_UTILIZATION_BPS` |
| 淨利差 | 借款利率 − 借款激勵 > vault 利率 + vault 激勵 時不借；已借的可被收掉 | `carry(id)` |
| 一個資產一個市場 | 只有 `collateralMarket[asset]` 指定的市場能新增抵押與借款；改指定後舊部位仍可還款、取回 | `setCollateralMarket` |
| 同意 | 帳戶本人 `setBorrowPolicy(id, maxDebt, true)`，綁 enrollment；負債（含利息）不得超過 `maxDebt` | registry |
| CRE8 總上限 | 每市場本金上限（測試網 100,000 USDT） | `setBorrowCap` |
| 暫停 | `setBorrowPaused`、市場停用／退休、`AtpExecutor.globalPaused` 只擋新增；還款、減倉、取回抵押永遠開著 | |

剛好在門檻上一律通過、超過 1 個最小單位就擋（測試逐一覆蓋）。

## 3. 測試網參數（`script/testnet/TestnetBorrowBook.sol`）

| 資產 | 固定市場 | F | 類別 | 目標 LTV | 減倉線 |
| --- | --- | --- | --- | --- | --- |
| NVDAB | Venus | 60% | 個股 | 30% | 40% |
| TSLAB | Venus | 60% | 個股 | 30% | 40% |
| SPCXB | Venus | 50% | 個股 | 25% | 33.3% |
| QQQB | Lista | 70% | 指數 | 35% | 46.7% |
| MSTRB | Lista | 50% | 幣價連動 | 20% | 33.3% |
| BTCB、WBNB（#67） | Lista | 80% | 幣價連動 | 20% | 53.3% |
| SPYB、EWYB、XAUt（#67） | Lista | 70% | 指數 | 35% | 46.7% |
| AAPLB、MSFTB、GOOGLB、AMZNB、METAB、TSMB、AVGOB（#67） | Lista | 60% | 大型股（類別上限 35%，F/2 先卡住） | 30% | 40% |
| NFLXB、INTCB、SKHYB、MUB、SNDKB、ANTB、BABAB、PDDB、CRCLB、HOODB（#67） | Lista | 60% | 個股 | 30% | 40% |
| GMEB（#67） | Lista | 50% | 個股 | 25% | 33.3% |
| COINB、BMNRB、BNCB（#67） | Lista | 50% | 幣價連動 | 20% | 33.3% |

#67（2026-11-23）補上 21 檔首發基金裡其餘的非槓桿持股，共 31 個市場。已部署的 `AtpBorrowRegistry` 最多 32 個市場（`MAX_MARKETS`，合約不改），所以這些沒有上：槓桿類 TQQQB、SOXLB（§D 不開放）；DOGE（波動特別大，§D）；只在基金裡占 5% 衛星部位的小型股 AMCB、DJTB、CYPHB、PENGB、MRVLB、RDDTB（每檔對基金淨加息影響 < 0.1%）。留一個空位給日後換市場（`setCollateralMarket` 要先登記新市場）。新市場一律用 Lista：Lista 每個市場獨立，Venus 的健康度是整個帳戶一起算，同一檔基金多個 Venus 抵押品會互相占用額度。新市場的模擬利率與既有 Lista 市場相同（借款 2.5%、借款激勵 0.5%、抵押激勵 1%），每個市場背景流動性 25 萬 USDT。

模擬利率（owner 可調）：借款 2.5%；策略 vault 4.5%＋激勵 0.5%；Venus 抵押激勵 0.5%；Lista 抵押激勵 1%、借款激勵 0.5%。這些是「接近真實」的測試值，不是產品決定。背景流動性：vUSDT 50 萬、每個 Lista 市場 25 萬、策略 vault 25 萬。

策略 vault 是新的 `MockEarnVault`，以 `supplyEnabled = false` 登記在既有 `AtpYieldRegistry`（沿用它的使用率、利率與身分檢查），`AtpExecutor` 的閒置現金不會存進去，策略與現金生息的部位不會混在一起。既有的 Cash Earn vault 利率沒動。

激勵在模擬市場裡按部位價值逐秒累積，`claimReward(account)` 任何人都能觸發，但只付給持有部位的那個帳戶（測試網用 USDT 支付）。

## 4. 後端怎麼用

帳戶本人（owner 簽）一次性：`comptroller.updateDelegate(executor, true)`（Venus）或 `moolah.setAuthorization(executor, true)`（Lista）、`registry.setBorrowPolicy(id, maxDebt, true)`、對 executor approve 抵押品、USDT、策略 vault 份額。

| 動作 | 呼叫 |
| --- | --- |
| 開啟 | `executeSupplyCollateral(account, id, amount, deadline)` → `executeBorrow(account, id, usdt, deadline)`（借款金額＝抵押價值 × 目標 LTV 以內） |
| 關閉／賣出前 | `executeRepay(account, id, type(uint256).max, true, deadline)`（先用 vault，不足用帳戶自己的 USDT）→ `executeWithdrawCollateral(account, id, type(uint256).max, deadline)` |
| 減倉／收掉 | `status(id, account)` 回傳 `shouldDeleverage` 或 `shouldUnwind` 為 true 時呼叫 `executeDeleverage(account, id)`（任何人可呼叫，只動該部位的 vault 份額）。vault 流動性不夠時只還得了一部分，剩下的由後端賣抵押品後 `executeRepay(..., false, ...)` |
| 讀取 | `status(id, account)` 用 eth_call：`gate`（0 可用，其他＝「暫時無法使用」）、各項利率與激勵、使用率、LTV 線、部位 LTV、負債、vault 價值、健康度 |

加息 APY ＝（vault 利率 ＋ vault 激勵 − 借款利率 ＋ 借款激勵）× 比例 ＋ 抵押品利率 ＋ 抵押激勵。比例：已開的用 `ltv`，買入前用 `targetLtv`。真市場不在鏈上公布激勵與 vault 利率，這兩項主網要由後端補；讀不到 vault 利率時合約不開新借款。

注意：`AtpExecutor.previewAccountValue` 不算抵押品、也不扣負債；淨值要由後端算（抵押價值 ＋ vault 價值 − 負債）。

## 5. 部署與演練

```bash
# 環境：manifest 地址
export TESTNET_EXECUTOR=$(jq -r .contracts.executor deployments/testnet-97.json)
for s in NVDAB TSLAB SPCXB QQQB MSTRB; do export TOKEN_$s=$(jq -r ".assets.$s.token" deployments/testnet-97.json); done
YV=$(jq -r .contracts.yieldView deployments/testnet-97.json)
# 部署（冪等，第二次跑沒有交易）
forge script script/testnet/DeployBorrowTestnet.s.sol:DeployBorrowTestnet --libraries src/atp/yield/YieldView.sol:YieldView:$YV \
  --rpc-url https://bsc-testnet.bnbchain.org --broadcast --slow --with-gas-price 150000000 --priority-gas-price 150000000 \
  --gas-estimate-multiplier 130 --sender 0x55662B4183fcA1230694D5D57F56E4F2E0e3008a   # 金鑰經 TESTNET_DEPLOYER_KEY／TESTNET_OWNER_KEY
# 演練：抵押 → 借款存 vault → 降價 → 自動減倉 → 復價 → 從 vault 還清 → 取回抵押 → 領激勵
BORROW_EXECUTOR=... BORROW_LENDING_ORACLE=... BORROW_MARKET_ID=... forge script script/testnet/BorrowDemoTestnet.s.sol:BorrowDemoTestnet ... --gas-estimate-multiplier 200
```

演練要用 `--gas-estimate-multiplier 200`：forge 在同一個時間點模擬所有步驟，鏈上各步之間會累積利息，還款那一步實際多用約 20% gas。2026-11-23 第一次廣播用 130 倍率，「從 vault 還清」那筆因 gas 不足失敗（`0x52055244…0e59`），之後用 `cast send` 加大 gas 補完同一輪。

清算演練：owner `lendingOracle.setPrice(資產, 低價)` 後，任何人用 `vUSDT.liquidateBorrow(帳戶, 金額, vToken)` 或 `moolah.liquidate(params, 帳戶, 抵押數量, 0, "")`，再 `registry.reconcile(帳戶, id)` 對帳。

fork 實測（2026-11-23）：部署 59 筆、32,288,031 gas（最大單筆 8,784,255，低於 BSC 16,777,216 上限）；演練 17 筆、4,716,723 gas。

## 6. chain 97 部署紀錄（2026-11-23）

地址寫在 `deployments/testnet-97.json` 的 `borrow` 區塊：executor `0x16ab59A8bacB578C6437528AC0961e234e4b717b`、registry `0x973341a0bA6A725630F2a4F66D7dbba92fEA4E00`、策略 vault `0x2e915B874a5a544736f5afD97f3Fa1Dd45d417a9`、oracle `0xc5E37daC4B0c662fD9B848e9882A453A00Fd2E50`、Venus comptroller `0x93AB77260c8C62b26698bBB0ee8da3E175b9ad8D`、vUSDT `0xC0a352E6Aa517910b4F2CFc277B6161042CEa366`、Lista Moolah `0x993237aC050512f3749bfEE2dE759b6B86Aea653`。部署 59 筆全部成功（區塊 144259996–144260395）；再跑一次部署腳本沒有新交易。

演練帳戶 `0x5683Cf2f1e038e8c4444Bf853A31dBF4C841BF54`，NVDAB／Venus（目標 LTV 30%、減倉線 40%）：

| 步驟 | 結果 | 交易 |
| --- | --- | --- |
| 抵押 5 NVDAB | | `0xbe76b51149b4da1baf9cfdb698f30606c58676e01d8b1ec1c1839fec34ace167` |
| 借 150 USDT 同筆存 vault | LTV 18.5% | `0xe74e681ce7f3f09b17c5723de5ef47124573a4b8fdfec04630c99b84cbaa0e33` |
| owner 把 NVDAB 調到 70 USD | LTV 42.9% ≥ 40% | `0x3008e1fa239753aefa51bf8e0fff82e89ac34c9b02ac955356b55c207b927841` |
| 任何人觸發減倉 | 從 vault 還 45 USDT，LTV 回到 30.0% | `0x2be7ae36653252d1c6ec26f0965245c627e6c4686edea0fe3bbd19172bf6714b` |
| 復價 | | `0xd8ab2e2f70b2d5d2216560bcb036be29b9406a4e6db5806a7d584eb59ef2499e` |
| 從 vault 還清 | 負債 0，剩下的 vault 份額回帳戶 | `0xa05b8c8d093d2b4e6730f30e4560bf4f03d95f6bb5cad27cbdaab17f273f33f6` |
| 取回全部抵押 | 5 NVDAB 回帳戶 | `0x3c70187fa6dcde8b458c13b51f51550bd8773126a9657c84c0daeaa374f5fad4` |
| 領抵押激勵、vault 激勵 | 進同一個帳戶 | `0xdfb5c99bb854d486e993821875c9294498ba3c93404b731e930640b336fc4fd9`、`0x1e2e3d63463d098d482c8ea931d5b8b509f91c6032837798f163c93bcb9a6d7c` |

## 7. 已知限制：策略 vault 份額與 `AtpExecutor.executeWithdraw`

策略 vault 登記在既有 `AtpYieldRegistry`（供借款合約讀使用率與利率），`supplyEnabled = false` 擋住現金生息存入，但既有 `AtpExecutor.executeWithdraw` 沒有「只限現金生息」的檢查：**若帳戶曾對 `AtpExecutor` approve 策略 vault 份額**，session key 可把策略份額贖回成帳戶現金。錢仍在同一個投資組合帳戶，不會到別的帳戶或用戶錢包，但會跟現金混在一起、借款部位失去 vault 還款來源。`AtpExecutor` 已部署不改，所以後端必須：只對 `AtpBorrowExecutor` approve 策略 vault 份額、絕不對 `AtpExecutor` approve；session policy 不允許對策略 vault 的 market id 呼叫 `executeWithdraw`。主網要在下一版 executor 或 registry 擋掉。

## 8. #67 補齊首發基金市場（2026-11-23）

OWNER 從部署者轉入 0.01 tBNB（`0x33b85c0cbc0f51d8024b6d51d96eca3e23850ba0e4bc86d1db934ce54bc93300`）後重跑同一支冪等腳本：26 個新 Lista 市場（每個：設 oracle 價、`createMarket`、激勵、25 萬 USDT 背景流動性、`registerMarket`），183 筆、21,921,393 gas（最大單筆約 32 萬），區塊 144321385–144323209，全部成功。第一次執行到第 25 個市場時本機磁碟滿、forge 寫不進 broadcast 檔而中斷，清出空間後重跑，腳本從斷點接著補完。再跑一次沒有交易。既有 5 個市場的價格與參數沒有動。

驗證：`marketCount()` = 31；31 個市場 `status(id, 0).gate` 全部 0（可借）；目標 LTV／減倉線見 `deployments/testnet-97.json` 的 `borrow.markets`（新列有 `addedIn: "#67"`）。fork 演練：同一腳本 184 筆、21,586,460 gas，再跑一次 0 筆。
