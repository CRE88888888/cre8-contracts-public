# BSC 測試網（chain 97）部署手冊

cre8-contracts#30（測試網 T1）。這份文件說明整套合約怎麼部署到 chain 97、怎麼在本機 fork 驗收，以及上線後 keeper 要做什麼。依據是 docs `research/2026-11-14-testnet-plan.zh-TW.md` 的推薦方案，以及使用者 2026-11-14 的授權（ROADMAP「T 段授權」、docs#47、docs#48）。

**只用在 chain 97。** 每支腳本開頭都檢查 `block.chainid == 97`。`DeployAtp`、`DeployAtpMainnet` 對 chain 56 的防護都沒有改動。

## 1. 部署了什麼

| 項目 | 內容 |
| --- | --- |
| 測試 USDT | `TestnetUSDT`，18 decimals，是計價資產。內建水龍頭：每個地址每 24 小時最多領 10,000（`claim`）；minter 可以代領（`claimFor`），同樣受這個上限；minter 另外可以不限量 `mint`。 |
| 38 個模擬資產 | 清單、順序與 `maxSlippageBps` 和 #25 之前的 `DeployAtpMainnet` 相同（#25 把主網的穩定幣改 50 bps、深池改 100 bps，測試網沒有跟著改，見下方註）。symbol、decimals、Pancake V3 fee tier、bStock 的 `uiMultiplier` 取自主網（`script/testnet/TestnetAssets.sol`，主網區塊 133542361，只讀）。26 個 bStock 用 `TestnetBStock`，讀取介面和主網 bStock 一樣（`uiMultiplier`、`toUIAmount`、`fromUIAmount`、`balanceOfUI`）；池子與 oracle 一律用 raw 價格，倍率只給畫面換算。 |
| 38 個 Pancake V3 池 | 每個資產對測試 USDT 各一個池，fee tier 和主網相同。起始價是主網當時的現價取 6 位有效數字（固定基準，不是即時行情）。全區間流動性每邊 500 萬 USDT 等值。`observationCardinalityNext` 設為 600。 |
| registry／oracle router／executor | 參數和 `DeployAtpMainnet` 相同：TWAP 30 分鐘、近期均值 5 分鐘、`maxOracleAge` 1 小時、`maxBuyBps` 10000、secondary 偏差 200 bps。venue 只有 Pancake V3 Universal Router（建構時登錄）。KyberSwap 不支援 97，所以不加入。 |
| 模擬價格源（secondary） | `TestnetPriceFeed`，AggregatorV3 介面，8 decimals。用在和主網同樣的 11 個資產（WBNB、BTCB、ETH、DOGE、AVAX、SOL、TRX、XRP、USDC、DAI、LTC），另有一個 USDT/USD。只有 keeper 能推價；`maxAge` 是 #25 之前的主網值（AVAX 1 天，其餘 1 小時，USDT/USD 沿用資產的值）。 |

> **註（cre8-contracts#25）：** 主網部署腳本在 #25 改了 oracle：池子超過 `maxOracleAge` 沒成交就 fail closed、feed 時限改為約 3 倍 heartbeat 且 USDT/USD 有自己的時限、穩定幣與深池的 `maxSlippageBps` 收緊。chain 97 上已部署的合約是 #25 之前的版本，`DeployTestnet` 只做編譯需要的最小調整（USDT/USD 時限 = 資產時限），重跑仍驗證現有部署。測試網要換成 #25 的 oracle 時要重新部署 router 與 oracle，而且 keeper 必須讓每個池子至少每小時成交一次，否則閒置資產會照設計停止交易；這件事由總管另外決定。
| GasPolicy | 補上 ZeroDev `toGasPolicy` 使用的 `0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23`，見第 5 節。 |
| 自有 paymaster | eth-infinitism account-abstraction **v0.7.0** 的 `VerifyingPaymaster`，commit `7af70c8993a6f42973f520ae0752386a5032abe7`，原檔照抄在 `src/testnet/aa/`。由 paymaster signer 在鏈下簽代付，部署時存 0.5 tBNB 到 EntryPoint v0.7。不使用 ZeroDev 的付費 bundler／paymaster（docs#48）。 |

全部合約都用 CREATE2 部署：模擬資產、價格源與 executor 走 deterministic deployer `0x4e59…956C`；registry、router 與 paymaster 這類由建構子把 owner 設為 `msg.sender` 的合約，走 `TestnetOwnedDeployer`（salt 綁定呼叫者，部署後把 owner 交回呼叫者）。所以：

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
| deployer | `0x55662B4183fcA1230694D5D57F56E4F2E0e3008a` | 部署全部合約；擁有模擬資產與價格源（可指派 minter 與 keeper）；持有 LP 部位 | 使用者打入 |
| owner | `0x09BBB9A06a0C49Ad24bddB18808944041783054e` | 代替主網 Safe：registry、router、paymaster 的 owner；也是 executor 的管理者（executor 以 registry owner 為管理者） | 0.01 |
| operator | `0xd8CE3295e05cA138e0d0d7214C4FD630c43F9d7F` | registry operator（後端 relayer，負責第一次 enroll）；測試 USDT 的 minter（水龍頭 `claimFor`） | 0.05 |
| keeper | `0xa38dDFB9FDF0043Cf61B00E1a8d12FA1431f92d5` | 唯一能推價的地址；所有模擬資產的 minter（調池用） | 0.3 |
| paymaster-signer | `0xF5645Ff8Fa773246010F7C9DDDFF8e590e800495` | 鏈下簽 `VerifyingPaymaster` 代付 | 0（不送交易） |
| fee-recipient | `0x3b5EDE5aF574e7d8f3B72143E09DC242dD1F0462` | 收 executor 手續費 | 0 |
| bundler-executor | `0xcc0ea01356d75aa5295d364344753f136b77ee28` | alto `--executor-private-keys`，送 `handleOps`，gas 由 EntryPoint 從 paymaster 存款補回 | 0.1 |
| bundler-utility | `0x6735c14bf84c8cB0d64BF2FB51b7587AdE7b2960` | alto `--utility-private-key` | 0.02 |

registry、router 用兩步移交：deployer 提議、owner 接受，兩步都在同一次部署內完成。paymaster 是 OpenZeppelin `Ownable`，一步移交。移交之後重跑腳本，需要管理權限的設定改由 owner 送出，所以公開鏈上要同時提供 deployer 和 owner 兩把金鑰。分發規則是「餘額低於目標一半才補到目標」，所以重跑不會重複轉帳。paymaster 存款目標可以用 `TESTNET_PAYMASTER_DEPOSIT`（單位 wei）覆寫。

## 3. 需要多少 tBNB

在本機 fork 上實測（2026-11-14，全新 fork）：第一次跑 `deploy-97.sh` 共兩輪。第一輪 503 筆交易、829,608,157 gas；第二輪是自動重跑、補池子 observation 的那一輪，75 筆交易、10,197,716 gas。合計約 8.4 億 gas。

| 項目 | tBNB（gas price 0.1 gwei） |
| --- | --- |
| 部署 gas | 0.084（最大單筆約 1,335 萬 gas，主要花在 `increaseObservationCardinalityNext(600)`；97 的區塊 gas 上限約 9,900 萬） |
| 分發給角色 | 0.48（owner 0.01、operator 0.05、keeper 0.3、bundler-executor 0.1、bundler-utility 0.02） |
| paymaster 的 EntryPoint 存款 | 0.5 |
| **合計** | **約 1.06** |

建議 deployer 總共準備 **1.2 tBNB**，多出來的部分是應付 gas price 波動。2026-11-14 deployer 在公開 97 上已經有 0.3 tBNB，所以**還要再補約 0.9**。如果 deployer 的餘額不夠，腳本會在分發前停下，告訴你還差多少 wei，不會只轉一半。如果只想先把合約部署上去，最少約 0.1 tBNB：把 `TESTNET_PAYMASTER_DEPOSIT` 設為 0，角色的分發也要先調低（目前寫在 `DeployTestnet` 的 `FLOAT_*` 常數）。

在 fork 上實測的代付成本：owner 的 approve UserOp（4 筆）用了 277,473 gas；session key 的 rebalance UserOp（3 筆買入）用了 1,151,634 gas。

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

`fork-e2e.sh` 依序做這些事：

1. 跑兩次 `deploy-97.sh fork`。第二次必須沒有交易，manifest 也不能變。
2. 把 fork 的時間往前推 30 分鐘做 TWAP 暖機，再由 keeper 推一次價。
3. `SmokeTestnet`：38 個資產各經 executor 用 100 USDT 買入、全部賣回，每一步都要過 oracle 地板。
4. `kernel-smoke`：
   - 在本機起 alto（埠 3047），建立 Kernel v3.3 帳戶；
   - 帳戶由 operator 部署，部署時一併安裝 session key 權限；
   - operator 做 enroll，水龍頭領 USDT；
   - owner 送 approve（自有 paymaster 代付）；
   - session key 送 `executeRebalance`（代付）；
   - 再確認三種情況都被拒：超出 CallPolicy、paymaster 簽章錯、沒用我們的 paymaster（GasPolicy 的 `enforcePaymaster`）。

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

1. 腳本會在本機讀取 deployer 與 owner 的私鑰，並核對它們對應的地址；私鑰不會印出。
2. 某個池子的第一筆流動性如果和建池落在同一秒，就不會寫入新的 observation（`observationCardinality` 停在 1，TWAP 不能用）。`deploy-97.sh` 會在鏈上檢查，遇到這種池子就等幾秒自動重跑（最多 3 次），重跑時只補一筆很小的 mint。
3. **TWAP 暖機**：部署完成後至少等 30 分鐘，`previewSwap` 才會有報價；在那之前會回 `TwapUnavailable`，這是 fail-closed 的正常行為。
4. **keeper 要定期推價**：有 secondary 的 11 個資產，價格源超過 1 小時（AVAX 是 1 天）沒更新，就會 `StaleFeed`，那個資產停止交易。在價格重播 keeper（X1，T3）接手之前，可以先用 `PushFeedsTestnet` 推回固定的基準價：

   ```bash
   forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url <97> --broadcast --private-key <keeper>
   ```

5. 部署完成後，用 `deploy-97.sh` 產生的 manifest 取代 fork 版本，再 commit。`mode` 會變成 `public`。

## 7. 已知限制

- 這是模擬行情：價格固定在基準價，池子由我們自己提供流動性，價格源也由我們自己推。它驗證的是操作流程，不代表主網的深度、MEV 或真實成交。
- 38 個池子每個 observation slot 有 600 個。約 0.45 秒一個區塊，如果某個池子平均每 3 秒以內就有一筆 swap，30 分鐘的 TWAP 會讀不到最舊的 observation（`TwapUnavailable`）。keeper 調池的頻率要遠低於這個。
- `src/testnet/aa/` 是 GPL-3.0 的上游原檔（eth-infinitism），只給測試網使用；`src/atp/` 沒有任何檔案引用它。
- KyberSwap、OpenOcean 都不支援 97，所以測試網只有 Pancake V3 這一個 venue。
