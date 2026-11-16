# P11 策略版本與加入同意（cre8-contracts#28）

本規格對應產品架構 §7.3、C3 在 #28 的定案留言。合約不可升級；既有部署不會自動取得本功能，部署新 registry／executor 後，backend、app 必須遷移 ABI、重新由帳戶本人同意。沒有送公開鏈交易。

## 發版與完整設定

- `publishVersion(uint256 id,address[] assets,uint16[] weightsBps,bytes32 scheduleHash,uint64 activeAt)` 保留為簡單設定入口：額外規則雜湊為零、績效費為 500 bps。
- `publishSettingsVersion(uint256 id,address[] assets,uint16[] weightsBps,bytes32 scheduleHash,bytes32 settingsHash,uint16 performanceFeeBps,uint64 activeAt)` 發布完整設定。
- `settingsHash` 是規範化、完整鏈下設定（各資產的策略與參數、基金規則）的承諾；backend／app 應共同訂定編碼並在送交易前核對內容。鏈上將它與資產、權重、排程、費率一起保存：
  `configHash = keccak256(abi.encode(assets,weightsBps,scheduleHash,settingsHash,performanceFeeBps))`。
- `Version` 原先四欄不變，依序追加 `bytes32 settingsHash,uint16 performanceFeeBps,bytes32 configHash`。需要同步更新回傳 tuple 的 ABI 解碼。
- **第一版也要等 24 小時。** `activeAt=0` 表示選擇合約允許的最早時間；其他值必須 ≥ `block.timestamp+86400`。owner 和創作者都不能繞過。
- 唯一例外：與上一個**已生效版本**相比，資產（包含順序）、權重、scheduleHash、settingsHash 全相同，且績效費嚴格更低，允許 `activeAt=block.timestamp`。相同費率、調高或混合變更仍等 24 小時。績效費限制 500–2000 bps。
- 所有發版（含費率調降與已取消的發版）都占用 7 天間隔；取消不重設時間。這是對「兩次發版至少 7 天」的保守解讀。
- 同時只有一個尚未生效版本。`cancelVersion(id)` 只准 provider／owner 在 `timestamp < activeAt` 取消；恰好生效時不能取消。編號 append-only，不因取消而重用；`versionCount` 包含取消紀錄，`cancelledVersion(id,n)` 可查。
- `pendingVersion(id)` 回傳尚未生效版本（無則 0）；`activeVersion(id)`／`version(id,0)` 即時解析最新生效版，不需要 keeper 發 activation 交易。`VersionScheduled` 含生效時間與整份設定雜湊。

## 帳戶加入與 operator

**舊 `enroll(address,uint256)` 已移除。** 新 ABI：`enroll(address account,uint256 id,uint16 expectedVersion)`。

`expectedVersion` 必須是當下最新**已生效**的非零版本，否則 revert；pending 不搶走原本的有效版本，provider 搶先發布／生效也不能把使用者加入到未接受的版本。

最簡單的串接：Kernel owner 用 sudo UserOp 由帳戶呼叫 `enroll(account,id,expectedVersion)`。此方法本身就是接受 `FOLLOW_VERSIONS_TERMS` 的動作：

> I agree to follow future strategy versions; changes require at least 24 hours notice during which I can exit. Fee-only decreases may take effect immediately.

app 必須顯示這份同意以及費率調降的立即生效例外，再由 owner 簽署；不可把 registry 加入 session key 的 CallPolicy。現有 smoke 的 session 仍只能呼叫 executor 的三個執行方法。

若 backend 要讓 operator 代送第一次 enroll：帳戶 owner 先用 sudo 呼叫 `approveEnrollment(id,expectedVersion)`，再由 operator 呼叫三參數 enroll。授權綁策略、版本、configHash 與上述條款，不能用另一個版本消耗；可由帳戶 `revokeEnrollmentApproval()` 撤銷，成功 enroll 後立即清除。operator 不能重新 enroll 已加入的帳戶，即使有暫停也不能藉此解除。owner／其他地址不能代替帳戶同意。

`enrollments(account).version` 保留本人當時接受的版本；swap 不再用它釘住版本。生息 policy 的原版本比對保持原樣：自動跟隨不授予新的生息權限，帳戶重新 enroll 後仍須重新同意 yield policy。`executeSupply`／`executeWithdraw` 及 YieldView 的規則不變。

## 賣出與估值

- 買入只准當下已生效版本的資產；未生效、取消與僅曾發布的資產不取得交易權限。
- 賣回 USDT 可使用此策略任一曾經生效版本的資產；不要求新版再次列出 USDT 才能退出。
- `historicalAssets(id)` 是全部已生效資產的去重聯集；`wasAssetAllowed(id,asset)` 是歷史賣出准入。pending 剛到期也立即可查，不依賴狀態整理交易。
- 買入額度的帳戶估值納入歷史資產；同一代幣跨版本只算一次。普通歷史資產持倉為零時，只讀 `balanceOf`、不呼叫價格源；無法報價的普通資產仍以零估值、降低買入額度。賣出仍須通過原 oracle 地板。收據不重複計值，原生息風險檢查保持。
- **每個策略的「已生效歷史＋新版」資產去重聯集最多 128 個**（`MAX_STRATEGY_ASSETS`，含有列入的 USDT）。兩個 publish 入口都檢查；會超過就 revert `StrategyAssetLimitExceeded(uint256 count)`，不寫入版本或推進發版時鐘。到期但尚未 materialize 的版本也計入，未生效即取消的版本不占名額；重複使用、調序或改權重不重複占名額。已生效資產永久占用歷史名額，滿額後只能重用既有資產。
- provider **只能發布 oracle 已支援的資產**，並在發版前確認雙向報價與流動性；registry 不會在鏈上驗證 oracle 覆蓋。128 上限用於限制歷史估值掃描，不能代替資產准入與 gas 預算；大量異常資產或價格源仍會提高成本。退出可分批賣，主人也可直接原樣轉出。

## #52 績效費 ledger 介面

ledger 應讀 `version(id,0).performanceFeeBps` 及 `configHash`，不可另開能即時調高費率的入口。registry 記錄費率並執行通知期；本單不實作本金、結算或分潤。ledger 估值若需要歷史普通資產，可讀 `historicalAssets`；生息估值應沿用自己的安全介面。請勿以 enrollment.version 當作當下費率版本。

## 本機驗證與時鐘

- `forge build`、`FOUNDRY_PROFILE=ci forge test`、`forge fmt --check`。
- #54 審查回歸：`FOUNDRY_PROFILE=ci forge test --match-path test/atp/AtpHistoricalAssetLimit.t.sol -vv`。128 資產聯集（含 USDT）、所有非 USDT 歷史資產皆有持倉，以正式 oracle router／TWAP 合約及模擬池、冷 storage 量測單步買入 **7,105,243 gas**，斷言 <12,000,000；不含 fixture 部署及 Kernel UserOp。原審查的兩輪各 90 個耗盡 `balanceOf` gas 的資產，第二輪聯集 183 個在發版時被拒絕；回到乾淨版本後單步買入 **10,259,895 gas**，在 16,777,216 預算內完成。另以呼叫次數驗證零持倉歷史資產不讀價格。
- `scripts/rehearse-mainnet-fork.sh`、`scripts/drill-ops-fork.sh` 只接受 anvil。版本 fixture 在凍結價格快照的一天前發布，再推進 24 小時回到原價格快照；此期間沒有 quote／swap，不改 oracle／feed。這驗證真實通知期，同時不把 fork 上不會更新的 Chainlink 價格推到過期。只能在自己埠使用。
- chain 97 的 `scripts/testnet/deploy-97.sh fork` 驗證固定延遲與費率上下限，manifest 追加 `versioning` 介面資訊。部署本身不建立策略，因此不需跳過通知期。
- `SmokeTestnet` 以 `TESTNET_SMOKE_PREPARE=true` 首次執行發布策略，印 `SMOKE_PENDING`，不執行買賣。等待 ≥24 小時、刷新模擬價格與池子近期 observation，再以 `TESTNET_SMOKE_STRATEGY_ID=<id>` 重跑完成交易；`fork-e2e.sh` 已同步為兩階段流程，在前一天準備兩份策略，回到原價格快照後進行原本的暖機與 smoke。沒有即時生效捷徑。
- `SmokeYieldTestnet` 以 `TESTNET_YIELD_PHASE=prepare` 首輪印 `YIELD_PENDING`；待生效後用 `TESTNET_YIELD_STRATEGY_ID=<id>` 重跑 supply，再照原流程進行 exit。兩支腳本都核對既有策略的資產與權重。
- `kernel-smoke.ts` 已確認是本機 anvil 才操作時間 fixture，並由 owner 的 sudo UserOp 呼叫三參數 enroll；沒有 operator 代替用戶同意。

### 本次主網 fork 演練的既有部署限制（#50）

`DeployAtpMainnet` 原始呼叫會因 Foundry 先隱式部署 YieldView 而使預期 deployer nonce 多一筆，部署檢查在廣播前拒絕；這是 #50 的主網部署設計範圍，本單沒有改主網部署腳本。此處驗收先以另一個 anvil 公開測試帳戶部署 `src/atp/yield/YieldView.sol:YieldView`，再設定 `DAPP_LIBRARIES=src/atp/yield/YieldView.sol:YieldView:<實際部署地址>` 執行 rehearse／drill，避免隱式 library 交易改變被檢查的 nonce。全部只對本機 RPC。

重跑 `rehearse-mainnet-fork.sh` 應用乾淨的 fork：若 cardinality 已完成、這輪是 0 筆交易，腳本會讀到上輪非零的 `run-latest.json` 而在 receipt 數檢查失敗。這次沒有修改／捏造 receipt；重跑前將 pool slot0 還原為 fork 區塊的實際 RPC 讀值，保留預熱快取，再真正執行 23 筆 cardinality 交易。此限制亦留給部署流程單處理。
