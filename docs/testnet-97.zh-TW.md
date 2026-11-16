# BSC 測試網（chain 97）部署手冊

cre8-contracts#30（測試網 T1）。這份文件說明整套合約怎麼部署到 chain 97、怎麼在本機 fork 驗收，以及上線後 keeper 要做什麼。依據是 docs `research/2026-11-14-testnet-plan.zh-TW.md` 的推薦方案，以及使用者 2026-11-14 的授權（ROADMAP「T 段授權」、docs#47、docs#48）。

**只用在 chain 97。** 每支腳本開頭都檢查 `block.chainid == 97`。`DeployAtp`、`DeployAtpMainnet` 對 chain 56 的防護都沒有改動。

## 1. 部署了什麼

| 項目 | 內容 |
| --- | --- |
| 測試 USDT | `TestnetUSDT`，18 decimals，是計價資產。內建水龍頭只由 faucet 角色（operator）操作（#47）：`claimFor` 每個地址每 24 小時最多 1,000（參數表 §4 的每日領取）；`welcomeFor` 是迎新，每個地址一次 10,000（`WELCOME_AMOUNT`）。沒有任何人可呼叫的 `claim`（全站每日上限與每人每天一次由 backend 控管，公開的 `claim` 會讓任何地址繞過）。faucet 不能 `mint`；不限量的 `mint` 只屬於 minter，生息版本僅對三個 USDT 市場的利息合約授予 minter（Venus／Lista target、Aave aToken），其程式只按時間／APR mint 給市場自己；operator、keeper、deployer 均無 USDT minter 權限。其他 minter 由 owner 指派。 |
| 92 個模擬資產 | `script/testnet/TestnetAssets.sol`。**主網仍然只有 38 個**（`AtpMainnetSpecs`、`DeployAtpMainnet` 沒有改）。<br>① 前 38 個是上線資產（#30）：清單、順序、secondary 的選擇與 `maxSlippageBps` 分級和主網的 `AtpMainnetSpecs` 相同（#25：USDC、DAI 50 bps；WBNB、BTCB、ETH、QQQB、XAUt、NVDAB 100 bps；其餘 300 bps；`test_specs_matchMainnetTiersAndFeedChoice` 逐一比對）；symbol、decimals、fee tier、`uiMultiplier` 取自主網區塊 133542361（只讀）。<br>② 40 個是測試網 16 檔展示基金（Leopold Aschenbrenner、Gavin Baker、Ken Griffin、AI Buildout、Ray Dalio、Lyn Alden、David Einhorn、Berkshire、Pelosi、Mag7、Bill Ackman、Druckenmiller、Treasury Reserve、郭明錤、Raoul Pal、Multi-Asset Balanced）用到、但不在上線清單的 token（#39）：cre8-app `funds.json` 這 16 檔 `backtest.targets[]` 中 `weight > 0` 的聯集，主網代幣地址查 `assets.json`。<br>③ 14 個加密貨幣（#39）：ADA、LINK、BCH、NEAR、UNI、ZEC、TONCOIN（CoinGecko 2026-11-15 排除穩定幣的市值前 30 名中，在 BSC 有 Binance-Peg 或官方 BEP20、且還沒上的；BCH、NEAR、UNI 也是目錄 crypto 類還沒上的）；DOT、SHIB、PEPE、AAVE、Cake、FIL、ATOM（issue 點名）。<br>②③ 只在測試網：`maxSlippageBps` 一律 300、沒有 secondary；symbol、名稱、decimals、`uiMultiplier` 取自主網區塊 133693735（只讀；所以 TON 的 symbol 是 `TONCOIN`、9 decimals，CAKE 是 `Cake`）。`test_specs_testnetExtension_exactList` 逐一比對這 54 個 symbol。<br>44 個 bStock（24＋20）用 `TestnetBStock`，讀取介面和主網 bStock 一樣（`uiMultiplier`、`toUIAmount`、`fromUIAmount`、`balanceOfUI`）；池子與 oracle 一律用 raw 價格，倍率只給畫面換算。 |
| 92 個 Pancake V3 池 | 每個資產對測試 USDT 各一個池。起始價取 6 位有效數字（固定基準，不是即時行情）。①：fee tier 與起始價取自主網池（38 個）。②③：主網對 USDT 的 V3 池在 USDT 那邊有 1,000 USDT 以上的，用 USDT 最多那個池的 fee 與現價（8 個：LLYB、ADA、LINK、NEAR、UNI、ZEC、PEPE、Cake）；其他主網池大多是空池、報價離譜（例如 DOT 有個池報 3.4e38 USDT），不採用，改用 fee 2500，價格用目錄最後收盤（股票／ETF，2026-11-09，USD 每股，bStock 再乘 `uiMultiplier`；Ondo 代幣的累積配息沒加上；39 個）或 CoinGecko 現價（加密貨幣，2026-11-15；7 個：BCH、TONCOIN、DOT、SHIB、AAVE、FIL、ATOM）。每一筆的來源寫在該行註解。全區間流動性每邊 500 萬 USDT 等值。`observationCardinalityNext` 設為 600。 |
| registry／oracle router／executor | 參數和 `DeployAtpMainnet` 相同：TWAP 30 分鐘、近期均值 5 分鐘、`maxOracleAge` 1 小時、`maxBuyBps` 10000、secondary 偏差 200 bps。venue 只有 Pancake V3 Universal Router（建構時登錄）。KyberSwap 不支援 97，所以不加入。 |
| 模擬價格源（secondary） | `TestnetPriceFeed`，AggregatorV3 介面，8 decimals。用在和主網同樣的 11 個資產（WBNB、BTCB、ETH、DOGE、AVAX、SOL、TRX、XRP、USDC、DAI、LTC），另有一個 USDT/USD。只有 keeper 能推價；`maxAge` **不照主網**（主網是 Chainlink heartbeat 的 3 倍，WBNB 81 秒、DOGE 141 秒、BTCB／ETH 180 秒），而是配合測試網價格 keeper：資產 1 小時（AVAX 1 天），USDT/USD 依 #25 有自己的時限 1 小時（`USDT_USD_MAX_AGE`）。見下方註。 |

| GasPolicy | 補上 ZeroDev `toGasPolicy` 使用的 `0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23`，見第 5 節。 |
| 自有 paymaster | eth-infinitism account-abstraction **v0.7.0** 的 `VerifyingPaymaster`，commit `7af70c8993a6f42973f520ae0752386a5032abe7`，原檔照抄在 `src/testnet/aa/`。由 paymaster signer 在鏈下簽代付，部署時存 0.5 tBNB 到 EntryPoint v0.7。不使用 ZeroDev 的付費 bundler／paymaster（docs#48）。 |

> **註（cre8-contracts#25、#33）：** `DeployTestnet` 已對齊 #25 的 oracle 與 #33 的 executor：router 與每個 oracle 都是 #25 的版本（池子超過 `maxOracleAge` 1 小時沒有新的 observation 就 fail closed、secondary 只要和 30 分鐘或 5 分鐘均價其中一個相符即可），executor 有每批次最低手續費 `minBatchFee` 0.30 USDT。feed 時限不照主網，原因是 mock feed 沒有 heartbeat，只有 keeper 的推價間隔：backend 的價格 keeper 每 60–300 秒推一次，而且會逐一核對每個 secondary 的 `maxAge` 是否等於 1 小時／1 天，改成 81–180 秒會讓 keeper 拒絕啟動、WBNB 等資產在推價間隔較長時停止交易。secondary 由 router 以 CREATE 部署，這些時限不影響任何地址；之後要改，由 owner `clearSecondary` 再 `setSecondary` 即可（secondary 地址會變）。

頂層合約以 CREATE2 部署；生息登記器由 executor 以 CREATE nonce 1 建立，Aave aToken／debt 由 Pool 建立，子合約地址同樣由父合約與固定 nonce 決定。其餘部署方式：模擬資產、價格源與 executor 走 deterministic deployer `0x4e59…956C`；registry、router 與 paymaster 這類由建構子把 owner 設為 `msg.sender` 的合約，走 `TestnetOwnedDeployer`（salt 綁定呼叫者，部署後把 owner 交回呼叫者）。所以：

- 地址只由「deployer、salt、init code」決定。本機 fork 算出的地址就是公開鏈上的地址，`deployments/testnet-97.json` 可以先在 fork 上產生。
- 腳本可以重跑：第二次跑時已完成的步驟全部略過，印出 `No transactions to broadcast`。
- 合約程式碼或建構參數一改，地址就會換（新部署會在舊部署旁邊）。要刻意重開一套，就改 `TestnetBook.SALT_NAMESPACE`。
- **地址只在乾淨的 main 上可重現。** init code 含編譯 metadata，也就是每個原始檔內容的 hash，所以只要工作目錄有任何沒 commit 的改動，或 HEAD 不是 `origin/main`，部署出來的地址就會和 `deployments/testnet-97.json` 不同；就算那些改動是別的 session 留在同一個 clone 裡的半成品也一樣。2026-11-14 X1 複製了主 clone 的工作目錄，裡面有 #25 尚未 commit 的 oracle 改動，結果 router、executor 與 38 個 oracle 的地址都對不上（backend#69）。
  - 現在 `deploy-97.sh` 遇到這兩種情況都會拒絕部署並說明原因。要部署，請另開一個乾淨的 worktree：`git worktree add <目錄> origin/main`。
  - 只有 fork 模式可以設 `TESTNET_ALLOW_UNMERGED=1`，在未合併的分支上測試；工作目錄必須乾淨這一條仍然不能跳過。
  - 原始檔放在哪個目錄不影響地址：metadata 記的是相對路徑。已驗證：在另一個目錄的乾淨 main 上，用全新 fork 部署，157 個地址全部等於 manifest。

## 2. 角色

金鑰都放在 `~/.cre8-testnet/`（權限 600，只用於 chain 97，不進任何 repo）。公開地址寫死在 `script/testnet/TestnetBook.sol`。使用者只需要把 tBNB 打給 deployer，其他角色的 tBNB 由部署腳本從 deployer 分發。

| 角色 | 地址 | 權限 | 部署時分到的 tBNB |
| --- | --- | --- | --- |
| deployer | `0x55662B4183fcA1230694D5D57F56E4F2E0e3008a` | 部署全部合約；建市場期間擁有模擬資產與價格源、持有 LP 部位；部署完成後全部移交 owner，自己不留任何權限（#47，見下方） | 使用者打入 |
| owner | `0x09BBB9A06a0C49Ad24bddB18808944041783054e` | 代替主網 Safe：registry、router、paymaster 的 owner；也是 executor 的管理者（executor 以 registry owner 為管理者）；#47 起也是測試 USDT、92 個模擬資產、12 個價格源的 owner，並持有全部 LP NFT | 0.01 |
| operator | `0xd8CE3295e05cA138e0d0d7214C4FD630c43F9d7F` | registry operator（後端 relayer，負責第一次 enroll）；測試 USDT 的 faucet（`claimFor`、`welcomeFor`，有上限，不能 `mint`，#47） | 0.05 |
| keeper | `0xa38dDFB9FDF0043Cf61B00E1a8d12FA1431f92d5` | 唯一能推價的地址；92 個模擬資產的 minter（調池用）；**不是** USDT minter，USDT 庫存由部署時一次撥 2,000,000（`KEEPER_USDT_STOCK`，#47） | 0.3 |
| paymaster-signer | `0xF5645Ff8Fa773246010F7C9DDDFF8e590e800495` | 鏈下簽 `VerifyingPaymaster` 代付 | 0（不送交易） |
| fee-recipient | `0x3b5EDE5aF574e7d8f3B72143E09DC242dD1F0462` | 收 executor 手續費 | 0 |
| bundler-executor | `0xcc0ea01356d75aa5295d364344753f136b77ee28` | alto `--executor-private-keys`，送 `handleOps`，gas 由 EntryPoint 從 paymaster 存款補回 | 0.1 |
| bundler-utility | `0x6735c14bf84c8cB0d64BF2FB51b7587AdE7b2960` | alto `--utility-private-key` | 0.02 |

registry、router 用兩步移交：deployer 提議、owner 接受，兩步都在同一次部署內完成。paymaster 是 OpenZeppelin `Ownable`，一步移交。移交之後重跑腳本，需要管理權限的設定改由 owner 送出，所以公開鏈上要同時提供 deployer 和 owner 兩把金鑰。

deployer 建的東西也全部移交（#47）：先撥 keeper 的 USDT 庫存（deployer 最後一次 mint），再對 USDT 和 92 個模擬資產撤銷自己的 minter、把 owner 移給 owner 角色；12 個價格源的 owner 移給 owner 角色；deployer 持有的全部 LP NFT 轉給 owner 角色。這一步只在「這一輪沒有建池、也沒有對任何池子 mint」時執行，因為補 observation 的 poke mint 需要 deployer 的 mint 權限；否則印 `PENDING_HANDOVER`，`deploy-97.sh` 等幾秒重跑。完成後 `_verify` 會檢查 deployer 沒有任何 minter、owner 或 LP NFT 殘留。移交後要再 mint（例如補 keeper 的 USDT），由 owner 指派 minter。分發規則是「餘額低於目標一半才補到目標」，所以重跑不會重複轉帳。paymaster 存款目標可以用 `TESTNET_PAYMASTER_DEPOSIT`（單位 wei）覆寫。

## 3. 需要多少 tBNB

以下是 #39 未含生息市場版本的歷史量測。#40–#42 新增生息登記器、三種 adapter 與逐列 30 個模擬市場，最新部署驗收與估算見第 10 節及 [生息手冊](yield-97.zh-TW.md)。不可沿用下表的「1.18 tBNB」作為新版完整需求。

在本機 fork 上實測（2026-11-15，#39 的 92 個資產，全新 fork，區塊 142839927）：一次部署由 `deploy-97.sh` 自動跑四輪。forge 會把整個 `run()` 當成一次呼叫來模擬，資產多了會在模擬階段 out of gas，所以每輪最多部署 40 個還沒完成的市場（`TESTNET_MARKETS_PER_RUN`），印出 `PENDING_MARKETS <n>`，腳本看到就重跑，直到沒有剩下的才分發 tBNB、移交、驗證、寫 manifest。

| 輪 | 內容 | 交易數 | gas |
| --- | --- | --- | --- |
| 1 | 核心合約＋前 40 個市場 | 516 | 875,144,038 |
| 2 | 再 40 個市場 | 555 | 863,880,944 |
| 3 | 最後 12 個市場、分發、paymaster 存款、移交 | 245 | 267,921,669 |
| 4 | 自動重跑：補 `observationCardinality < 2` 的池子 | 3 | 419,660 |
| **合計** | | **1,319** | **2,007,366,311** |

第 1–3 輪每次也會因為「哪些池子的第一筆流動性和建池落在同一秒」而差幾筆 poke；三次全新 fork 的合計是 2,007,366,311–2,010,944,828 gas。每輪在本機約 1.5–3 分鐘。

| 項目 | tBNB（gas price 0.1 gwei） |
| --- | --- |
| 部署 gas | 0.20–0.21（最大單筆 13,351,414 gas，是 `increaseObservationCardinalityNext(600)`；97 的區塊 gas 上限約 9,845 萬） |
| 分發給角色 | 0.48（owner 0.01、operator 0.05、keeper 0.3、bundler-executor 0.1、bundler-utility 0.02） |
| paymaster 的 EntryPoint 存款 | 0.5（`TESTNET_PAYMASTER_DEPOSIT` 預設，沒有改） |
| **合計** | **約 1.18** |

當時未含生息的版本，在 0.1 gwei 假設下合計在 1.2 tBNB 以內。新版與即時 gas price 必須重算，不能據此認定 deployer 的 1.343 tBNB 足夠。要多留一點餘裕，可以部署時設 `TESTNET_PAYMASTER_DEPOSIT=400000000000000000`（0.4），合計約 1.08；之後再由任何人呼叫 paymaster 的 `deposit()` 補。如果 deployer 的餘額不夠，腳本會在分發前停下，告訴你還差多少 wei，不會只轉一半。如果只想先把合約部署上去，最少約 0.21 tBNB：把 `TESTNET_PAYMASTER_DEPOSIT` 設為 0，角色的分發也要先調低（目前寫在 `DeployTestnet` 的 `FLOAT_*` 常數）。

**keeper 的持續成本（#39）：** 每個池子每小時至少要有一筆會動 tick 的成交（見第 6 節第 3 點）。`fork-e2e.sh` 第 4 步量的穩態是每小時 92 筆 swap、10,953,177 gas（平均每筆約 11.9 萬），一天 24 輪約 2.63 億 gas，gas price 0.1 gwei 時**每天約 0.026 tBNB**，在 0.05 以內，所以 `maxOracleAge` 維持 1 小時、不另外加長。keeper 分到的 0.3 tBNB 只算調池（不含推價）大約夠 11 天，之後要補。第一輪另外要 mint 庫存、approve（278 筆、20,243,660 gas，約 0.002 tBNB，只有一次）。

在 fork 上實測的代付成本（#39，2026-11-15）：owner 的 approve UserOp（4 筆）用了 277,473 gas；session key 的 rebalance UserOp（3 筆買入）用了 1,257,325 gas。0.1 gwei 時 0.5 tBNB 的存款約可代付 4,000 筆這樣的 rebalance，或約 3,200 組「approve＋rebalance」（`DeployTestnet` 的 `PAYMASTER_DEPOSIT` 註解與參數表 §4 用同一個數字，#47）。

## 4. 本機 fork 驗收（不碰公開鏈）

上游 RPC 要保留夠長的歷史。data-seed 節點只保留幾分鐘的 state，部署跑到一半就會出現 `missing trie node`；drpc 免費版會逾時。目前可用的是 `bsc-testnet.publicnode.com`。

```bash
anvil --fork-url https://bsc-testnet.publicnode.com --chain-id 97 --port 8547 --hardfork cancun \
  --retries 15 --fork-retry-backoff 1500 --timeout 90000
```

```bash
mkdir -p /tmp/alto && (cd /tmp/alto && npm init -y && npm i @pimlico/alto@0.0.18 --ignore-scripts)
```

```bash
ALTO_DIR=/tmp/alto bash scripts/testnet/fork-e2e.sh
```

fork 不在 8547 時加 `FORK_RPC=http://127.0.0.1:<埠>`；在還沒合併的分支上驗收要加 `TESTNET_ALLOW_UNMERGED=1`（見第 1 節）。

`fork-e2e.sh` 依序做這些事：

1. 跑兩次 `deploy-97.sh fork`。第二次必須沒有交易，manifest 也不能變。
2. 把 fork 的時間往前推 30 分鐘做 TWAP 暖機，再由 keeper 推一次價。
3. `SmokeTestnet`（#45 起）：一個策略版本包含 USDT＋全部 92 個資產（共 93 個），一個新帳戶由 operator 發迎新 10,000 USDT（`welcomeFor`，#47）、enroll，每個資產經 executor 用 100 USDT 買入（合計 9,200，在 executor 每 24 小時「帳戶價值 100%」的買入上限內）、全部賣回，最後把 USDT 領回 EOA。買和賣都照後端的做法分批，每批最多 16 步（`SMOKE_STEPS_PER_BATCH` 可改），每一步都要過 oracle 地板。最後印出發版本、每一批與領出的 gas（見第 8 節）。
4. `PokePoolsTestnet` 兩輪（#39）：keeper 經 Pancake V3 SwapRouter（和 backend 價格 keeper 同一個）在每個池子做一筆會動 tick 的 swap（1,000 USDT 等值，約 4 bps）。第一輪順便 mint 庫存、approve；第二輪把時間往後推 1 小時再做，就是「每小時每池一筆」的穩定成本，腳本印出總 gas（見第 3 節）。之後再推一次價。
5. `kernel-smoke`：
   - 在本機起 alto（埠 3047），建立 Kernel v3.3 帳戶；
   - 帳戶由 operator 部署，部署時一併安裝 session key 權限；
   - operator 做 enroll，水龍頭領 USDT；
   - owner 送 approve（自有 paymaster 代付）；
   - session key 送 `executeRebalance`（代付）；
   - 再確認三種情況都被拒：超出 CallPolicy、paymaster 簽章錯、沒用我們的 paymaster（GasPolicy 的 `enforcePaymaster`）。
   - paymaster 簽章的 `validUntil`、session key 的時間限制、executor 的 deadline 都以鏈上最新區塊的時間為準：前面兩步把 fork 的時鐘推快了 1.5 小時，用電腦時間算會 `AA32 paymaster expired`（#39）。

`deploy-97.sh` 會用 `eth_getCode` 核對 manifest 裡的每一個合約地址，也會確認每個池子的 `observationCardinality ≥ 2`（見第 6 節），全部通過才寫入 `deployments/testnet-97.json`。

## 5. GasPolicy 從哪裡來

- `@zerodev/permissions@5.5.11` 的 `toGasPolicy` 用的地址是 `0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23`，這個地址在 97 上沒有 code（docs#42）。
- ZeroDev 在 Ethereum 上是用 deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`、salt 0 部署它的。部署交易是 `0x40a559cddebb29ebaf6807ef4c6fab55c5a2860f45bdbd4503a1ea4d371cac26`（區塊 19633995，一筆經 EntryPoint v0.6 的 UserOp）。
- 從那筆交易的 calldata 取出 init code，與 Blockscout 的 `getcontractcreation` 回傳的內容完全相同；keccak256 是 `0x45a4db46…e12c`。
- 這個 deployer 在 97 上也有，所以在 97 上用同樣的 init code 和 salt，會得到同一個地址。
- `DeployTestnet` 部署後會核對 runtime codehash，必須等於 BSC 主網上同一個地址的 codehash：`0x906572ca…50be`。

session key 的 GasPolicy 要設 `enforcePaymaster: true`、`allowedPaymaster: <自有 paymaster>`，這一段由後端（X1）產生 initConfig；做法可參考 `kernel-smoke.ts`。

## 6. 公開 chain 97 部署（要等使用者授權並打入 tBNB）

```bash
scripts/testnet/deploy-97.sh public     # 預設 RPC: data-seed-prebsc-1-s1；可用 BSC_TESTNET_RPC_URL 覆寫
```

1. 腳本會在本機讀取 deployer 與 owner 的私鑰，並核對它們對應的地址；私鑰不會印出，也不出現在任何命令列參數（#47）：`deploy-97.sh` 把 deployer、owner 的私鑰放在 forge 的環境變數 `TESTNET_DEPLOYER_KEY`、`TESTNET_OWNER_KEY`，`DeployTestnet` 用 `vm.rememberKey` 載入，並核對它們推得出 deployer、owner 的地址，不符就停下；`kernel-smoke/run-fork.sh` 僅用 Anvil 公開測試身份，bundler 金鑰透過 alto 的 `ALTO_EXECUTOR_PRIVATE_KEYS`、`ALTO_UTILITY_PRIVATE_KEY` 傳入；本機 fork 驗收不讀真金鑰。forge 的 log 暫存檔在腳本結束時刪除。
2. 某個池子的第一筆流動性如果和建池落在同一秒，就不會寫入新的 observation（`observationCardinality` 停在 1，TWAP 不能用）。`DeployTestnet` 每一輪都從鏈上讀，遇到這種池子就補一筆很小的 mint，並印 `PENDING_HANDOVER`；`deploy-97.sh` 等幾秒自動重跑（最多 3 次），直到某一輪不必再 mint、完成移交。
2a. 池子現價要在 spec 起始價 ±1% 以內（#47）：token 地址可以從公開 repo 算出來，別人可以先用任意價格建池。`DeployTestnet` 在加流動性之前、以及 `_verify` 時都會檢查，不符就停下（要換 fee tier 或先由 keeper 把價格推回）。
3. **TWAP 暖機**：部署完成後至少等 30 分鐘，`previewSwap` 才會有報價；在那之前會回 `TwapUnavailable`，這是 fail-closed 的正常行為。#25 之後還有另一邊的時限：池子最新的 observation 超過 1 小時（`maxOracleAge`），報價也會 `TwapUnavailable`。所以部署完成後的第 30 到 60 分鐘之間，價格 keeper 就要開始讓每個池子成交，之後每個池子至少每小時要有一筆會動到 tick 的成交，否則那個資產會照設計停止交易。
4. **keeper 要定期推價**：有 secondary 的 11 個資產，價格源超過 1 小時（AVAX 是 1 天）沒更新，就會 `StaleFeed`，那個資產停止交易。在價格重播 keeper（X1，T3）接手之前，可以先用 `PushFeedsTestnet` 推回固定的基準價：

   ```bash
   forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url <97> --broadcast --private-key <keeper>
   ```

5. 部署完成後，用 `deploy-97.sh` 產生的 manifest 取代 fork 版本，再 commit。`mode` 會變成 `public`。

## 7. 已知限制

- 這是模擬行情：價格固定在基準價，池子由我們自己提供流動性，價格源也由我們自己推。它驗證的是操作流程，不代表主網的深度、MEV 或真實成交。
- 92 個池子每個 observation slot 有 600 個。約 0.45 秒一個區塊，如果某個池子平均每 3 秒以內就有一筆 swap，30 分鐘的 TWAP 會讀不到最舊的 observation（`TwapUnavailable`）。keeper 調池的頻率要遠低於這個。
- `src/testnet/aa/` 是 GPL-3.0 的上游原檔（eth-infinitism），只給測試網使用；`src/atp/` 沒有任何檔案引用它。
- KyberSwap、OpenOcean 都不支援 97，所以測試網只有 Pancake V3 這一個 venue。

## 8. 一檔基金不設資產數上限（#45）

`AtpRegistry` 原本把一個版本限制在 16 個資產（`MAX_VERSION_ASSETS`），#45 拿掉了（使用者 2026-11-15 決定），常數與 `TooManyAssets` 一起刪除。剩下的檢查：至少一個資產、長度相符、沒有重複、權重加總 10000；#47 另外要求每個資產地址都有 code、權重 0 只允許 numeraire（見第 9 節）。`AtpMainnetSpecs`、`DeployAtpMainnet` 沒有改。

**主網已部署的 registry 仍有 16 檔上限（#47 #11）**：#45 只影響之後的新部署。`deployments/mainnet.json` 裡那份 registry 是 #45 之前的程式碼，發佈超過 16 個資產的版本會 revert `TooManyAssets`。在主網重新部署 registry 之前，backend 對 chain 56 保留 16 檔上限。

**哪些流程會在一筆交易內走過全部資產：**

| 流程 | 是否走過全部資產 | 能不能分批 |
| --- | --- | --- |
| 發版本 `publishVersion` | 是（寫入、檢查重複） | 不需要：93 個資產 340 萬 gas |
| 買入、賣出、再平衡、退出 `executeRebalance` | 否，步驟由呼叫者決定 | 可以，後端每批最多 16 步 |
| 每一步的 `isAssetAllowed` | 線性掃描版本清單，每步兩次 | 每步固定成本，隨資產數線性成長 |
| 買入上限的帳戶估值 `_accountValue`（批次裡有任何一筆買入就跑一次） | 是：每個資產 `balanceOf`，有持有的再問 oracle | **不能分批**，每個買入批次都付一次；只賣出的批次（退出）不估值 |
| `buyAllowance`（view） | 是 | 鏈下呼叫，不受每筆交易 gas 上限限制 |

估值是唯一拆不掉的整檔迴圈。它只對「有持有」的資產問 oracle（每個約 6.6 萬 gas），而能買到手的資產只有 oracle router 已上架的（測試網 92 個、主網 38 個），所以估值的成本由上架資產數決定，不由版本長度決定；版本裡沒上架的資產只多一次 `balanceOf`。因此不需要另設技術上限。

**實測（本機 chain 97 fork，2026-11-15，區塊 142,886,688 起，直接交易 gasUsed，不是 Kernel UserOp）：** 版本 = USDT＋92 個資產，每個資產買 100 USDT。

| 流程 | gas |
| --- | --- |
| `publishVersion`（93 個資產） | 3,399,965 |
| 一筆買完 92 個 | 22,476,909 |
| 一筆賣完 92 個 | 21,464,495 |
| 分批買入：第 1–6 批（16、16、16、16、16、12 步；估值時已持有 0、16、32、48、64、80 個） | 4,509,335／5,562,391／6,696,864／7,664,557／8,641,023／8,857,830，合計 41,932,000 |
| 分批賣出（退出）：第 1–6 批（同上步數） | 3,933,785／3,976,929／4,003,808／3,966,173／4,228,677／3,170,657，合計 23,280,029 |
| 退出最後一步：帳戶把 USDT 轉回主人 | 50,894 |

怎麼讀：

- **一筆做完全部 92 個不行**：買 2,248 萬、賣 2,146 萬，都超過 BSC 每筆交易 16,777,216 gas 的上限（EIP-7825，測試網 2026-03-24 啟用；anvil 用 cancun 不會擋，所以 fork 上能跑出數字）。一定要分批，executor 本來就支援（步驟由呼叫者決定），合約不用改。
- **每批 16 步可行**：最貴的買入批次是持有越多時（估值越貴）。持有全部 92 個時再買 16 個，依上表線性推估約 1,060 萬 gas；換成 Kernel UserOp 約 ×1.3（docs `research/2026-11-15-perf-fee-and-asset-cap`）約 1,380 萬，仍在 1,678 萬以內，但餘裕約 18%。只賣出的批次每批約 400 萬。
- **每日 gas 預算要依資產數放大**：一個帳戶把 92 個資產全部買一次要約 4,190 萬 gas、全部退出約 2,330 萬。參數表 §4 已把測試網的每帳戶每日預算改成 100M gas，兩者都在預算內。這是後端與參數表的事，合約不處理。

## 9. 部署前審查修正（#47）

**手續費（#1、#2、#9）**
- 測試網 registry 的預設換幣費設為 10 bps（`DEFAULT_FEE_BPS`），加上 executor 的 `minBatchFee` 0.30 USDT，就是參數表 §3 的 max(0.1%, 0.30 USDT)；`_verify` 檢查。主網 `DeployAtpMainnet` 沒有改，仍要求預設費率為 0，主網費率由人決定（部署時設或由 Safe 事後設）。
- **最低費每個帳戶每個時間窗只收一次**：參數表的「批」是使用者同一時間到期的一次投入，不是技術上拆出的 UserOp（後端每批最多 16 步）。executor 對每個帳戶記一個固定 1 小時的時間窗（`MIN_FEE_WINDOW`，由該帳戶第一筆有 swap 的批次開啟），把窗內所有批次當成一批：窗內累計成交量 c 的一批應補 T(c) = max(0, min(0.30, 1%×c) − 0.1%×c)，每一批只補「T(c) − 窗內已補」。所以：
  - 一筆 100 USDT 拆成 4 批 25：以前補 0.225×4 = 0.90，現在合計 0.25（加上比例費 0.10，共 0.35）；
  - 先送一筆 1 USDT 的小批次不能把最低費用掉：之後同窗再買 99，窗內合計補到 0.20，和一次買 100 一樣；
  - 一個時間窗補的錢永遠不超過一個 0.30，也不低於「把整窗當一批」該補的；每一批也不會比它單獨成批時補得多（差 1 wei 的捨入）；
  - 帳戶 USDT 不夠時少收的部分，同一個窗內的下一批補收；窗過了就不追。
  - 取捨：拆得很碎時，前幾批先補的 1% 上限部分，之後累計變大也不退，所以可能比「理想的一批」多收（上例多 0.05），但不會超過一個 0.30。同一個小時內兩次不同的投入也只收一次最低費。`minFeeDue(account, notional)` 給後端預估下一批要補多少。
  - 這是核心合約改動：之後主網新部署的 executor 也是這個行為（`DeployAtpMainnet` 一字未改，但它部署的是 `src/atp/AtpExecutor.sol`）；主網已部署的 executor 不受影響。
- **最低費上限 1%（#9）**：補收的最低費不超過該批（#47 起是該時間窗累計）成交量的 1%（`MIN_FEE_MAX_BPS`），所以 30 USDT 以下收不到 0.30。例如每個資產最少 1 USDT 的定期定額、零碎的出場。參數表 §3 由 C3 補上。

**資產驗證（#4）**：`publishVersion` 要求每個資產地址有 code（EOA 會讓含買入的批次全部 revert），權重 0 只允許 numeraire。registry 不知道 numeraire 是誰，所以新增 owner 只能設一次的 `setNumeraire`；沒設之前任何資產都不能是權重 0（fail closed）。測試網部署時設為測試 USDT。**主網之後若重新部署 registry，Safe 要呼叫 `setNumeraire(USDT)`，否則後端以權重 0 送 USDT 的版本會 revert**（`DeployAtpMainnet` 不能改，所以這一步不在腳本裡）。executor 估值時對每個資產的 `balanceOf` 改用 staticcall，revert 或回傳不足 32 bytes 都當 0（fail closed，只會降低買入上限）。不設資產數上限（使用者決定）。

**水龍頭與權限（#3、#6、#7）**：見第 1、2 節。

**搶先建池（#8）**：見第 6 節第 2a 點。

## 10. 第二批生息（#40／#41／#42）

設計、ABI／事件、風控／退出、主網准入界線與本機驗收方法見 [生息手冊](yield-97.zh-TW.md)。C3 最新表格實際為 30 列（表頭稱 32），全部 20 個資產存在；依逐列內容部署，不補未知市場。

2026-11-16 審查修正後完整 fork 驗收（腳本 `84e70fd`）：部署 1,916 筆／2,105,225,790 gas，2／11 tBNB 各自冪等重跑 0 交易且 manifest／餘額不變；92 資產買賣、30 市場完整退出及 Kernel session＋paymaster 存領全過。按 deployer 1.343 tBNB，含既有 0.98 分發／存款，0.1／0.2 gwei 需求為 1.190522579／1.401045158；詳細 ABI、地址、gas、餘裕與先失敗證據見生息手冊「審查修正後驗收」，不能沿用 §3 的歷史數字。
