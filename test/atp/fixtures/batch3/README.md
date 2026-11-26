# CT-1 本機價格與成交 fixture

只供本機 Foundry EVM 使用，`vm.chainId(97)` 不會連線或廣播到公開測試網。不需要 RPC、金鑰、anvil 或額外依賴。

## 重跑

```bash
forge test --match-contract 'AtpExecutorBatch3.*' -vv
forge test --match-contract 'AtpExecutorBatch3.*' --gas-report
forge test --match-contract 'AtpExecutor(BuyLimit|MinFee|GlobalPause|YieldEntrypoints)Test|AtpYield.*'
```

`Batch3Fixture.sol` 建立兩個 `TestnetToken`、官方 V3 pool、LP／成交 venue，以及原有的 `AtpMultiPoolOracle`、`PancakeV3TwapOracle`、`AtpExecutor`。pool 以真實 mint／swap 寫觀測，不直接設定均價、累積 tick 或歷史；`_advance` 推進時間及區塊，`_warm` 暖滿 1800 秒。另驗 5400 秒與 18／6 decimals。`_movePrice` 是改變資產相對 USDT 價格的 tick，並處理 token0／token1 方向。

venue 只收輸入代幣與數量，從真 pool 收到多少就付多少，沒有 `amountOutMin` 參數、不按測試期望 mint 輸出。`_realOutput` 用 snapshot 執行真 swap 後還原，只用來算獨立的成交預期；正式測試呼叫依然經原 executor 檢查。背景 LP 與 yield 資金不屬於跟隨者 NAV。固定深度是回歸條件，不能當主網資產准入或容量證據。

## 給 BE-4 的介面與覆蓋

- `executeRebalance(account, SwapStep[], deadline)` 已可處理雙向批次與較緊 gross `amountOutMin`；無須新增策略 selector。executor 不驗訊號、TP／SL、個人成本、closed、策略版本 hash 的內容或自動重啟規則，這些仍由 backend 實作。
- `previewSwap` 的 `quoted` 是 TWAP，`minimum` 是兩窗口的較高地板；`previewSwapWindows` 額外回傳近期均價。限價買入應由含分攤補差的最低 net token 數 gross-up，再與 oracle floor 取較嚴界線；TP 由最低 net USDT 加補差再 gross-up。測試覆蓋等號／少 1 raw、忽略補差會誤成交，以及訊號已觸發仍因地板待退。
- `SwapExecuted(account, tokenIn, tokenOut, amountIn, gross, fee, net, oracleFloor)` 與真 ERC20 `Transfer` 可核對 side 與實收；注意最後欄位名雖為 `oracleFloor`，現行實作回傳已 gross-up 的 `minGross`，不是原始 net floor。`MinFeeCharged` 另記補差。16 步混合批次逐事件／Transfer 對帳，末步失敗會回滾前面 transfers、pool、fee 與買窗。16 步是 backend 拆單政策，executor 沒有 16 步上限。
- BuyLimit 原 suite 已涵蓋 24h 前 1 秒／等號；新增真 pool 的 cap 等額／超 1 raw／0 與不計銷售。MinFee 原 suite 已涵蓋 N=30／300／301、短缺與 1h 等號；新增 N=10+20+270 實收 0.57、兩帳戶不同開窗與 UTC 午夜不重設、1h 重設不影響 24h。
- 三協議 mock 的領回不是買單：receipt NAV 不可直接花；全領回、流動性失敗／部分領回、領回確認後換幣失敗與重試，都核對實收、receipt／capacity、buy／fee 窗。純存領不收 swap fee。GlobalPause 保持阻擋 executor 存領／換幣，owner 仍能直接領回。
- `CT51-mixed-replay-v1` 從同一 snapshot 重播兩次，比對完整事件、兩幣餘額、fee 與視窗 digest。

本單沒有發現所測合約執行／receipt 介面不足。多 worker、DB／RPC／bundler 未知、canonical receipt／reorg、每個策略完整價格劇本、17 步拆單、paymaster ordinary／exit 分類及完整 UserOp gas 仍屬 BE-4 的跨系統驗收，不以此合約測試宣稱完成。gas report 是合約呼叫 gas，包含 revert 路徑與測試預熱影響，不等於完整 UserOp 或每日代付預算。

## 官方 pool bytecode 來源

`PancakeV3PoolCode.sol` 僅包裝未修改的 creation bytecode，保留原 solc metadata；不重編上游、不改 `lib/`。由於 repo 預設禁止測試讀取外部 JSON，使用 Solidity 載入器，無須放寬檔案權限。

- 套件：[`@pancakeswap/v3-core@1.0.2`](https://www.npmjs.com/package/@pancakeswap/v3-core/v/1.0.2)，artifact `artifacts/contracts/PancakeV3Pool.sol/PancakeV3Pool.json` 的 `bytecode`。
- 上游 commit：[`d6fa5610c55d09d931912d42b84a726d0299c0e0`](https://github.com/pancakeswap/pancake-v3-contracts/blob/d6fa5610c55d09d931912d42b84a726d0299c0e0/projects/v3-core/contracts/PancakeV3Pool.sol)，SPDX `GPL-2.0-or-later`；載入器沿用相同授權，其他自寫 fixture 為 MIT。
- npm tarball integrity：`sha512-9aZU8I1J6SbZOSW7NcNxuyaAC17tGkOaZJM9aJgvl6MMUOExpq0i0EC/jc3HxWbpC8sbZL+8eG544NEJs8CS+w==`。
- creation bytecode：23,566 bytes；SHA-256 `034ffaf7180fa30ebc95543ff0496c2ca5e1b3621c7aeb000285b9812662c6c6`，每次 fixture 部署前都核對。

可獨立下載並驗來源，不需安裝 npm 套件：

```bash
python3 - <<'PY'
import base64, hashlib, io, json, pathlib, re, tarfile, urllib.request
meta = json.load(urllib.request.urlopen('https://registry.npmjs.org/@pancakeswap/v3-core/1.0.2'))
raw = urllib.request.urlopen(meta['dist']['tarball']).read()
assert 'sha512-' + base64.b64encode(hashlib.sha512(raw).digest()).decode() == meta['dist']['integrity']
archive = tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz')
artifact = json.load(archive.extractfile('package/artifacts/contracts/PancakeV3Pool.sol/PancakeV3Pool.json'))
source = pathlib.Path('test/atp/fixtures/batch3/PancakeV3PoolCode.sol').read_text()
code = bytes.fromhex(re.search(r'hex"([0-9a-f]+)"', source)[1])
assert code == bytes.fromhex(artifact['bytecode'][2:])
assert len(code) == 23566
assert hashlib.sha256(code).hexdigest() == '034ffaf7180fa30ebc95543ff0496c2ca5e1b3621c7aeb000285b9812662c6c6'
print('official bytecode + tarball integrity: 1 pass / 0 skip / 0 fail')
PY
```
