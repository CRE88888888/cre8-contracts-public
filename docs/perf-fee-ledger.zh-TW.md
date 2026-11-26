# 績效費 ledger（#52）

`AtpPerfFeeLedger` 是可在核心之後獨立部署的選用記帳路徑，沒有改 executor、registry、Kernel 或 session policy。USDT 與投資資產仍放在使用者的基金 Kernel 帳戶，ledger 每次只經手當筆提領的 USDT，不持有長期資產、沒有任意提款／sweep 或管理員搬錢功能。

## 帳戶與本金

1. 創作者透過 registry 的 `publishSettingsVersion` 發布設定，`performanceFeeBps` 必須是 500–2000 bps（5%–20%），且包含在整份 `configHash`。ledger 直接讀 `version(strategyId,0)`，遵守 P11 的改版 24 小時通知期（第一版立即生效，#58）、7 天發版間隔與取消規則；只有其餘設定完全相同的純降費可立即生效。不需在 ledger 登記費率或同步資產，也沒有即時覆寫入口。
2. 基金帳戶透過主人 sudo UserOp 呼叫 `start()`；必須已 enroll 且策略已有生效版本。初始本金為 0，既有餘額不補登本金。重複 start 不會洗掉有效本金。
3. 現金帳戶 approve 剛好的 USDT，再 `deposit(fundAccount, amount)`。ledger 核對實際入帳與付款方實際扣款相等後加本金。任意外部付款人可存入 ACTIVE 帳戶；禁止基金帳戶自己對自己存入，避免同一筆餘額反覆製造本金。前端的測試幣 welcome／每日額度也必須經這條路；直接打進基金不會算本金。
4. 原樣 ERC20 轉入不增加本金；在服務估值集合中的資產因此算獲利。合約無法攔截或對外部 ERC20 的直接轉帳自行發事件；後端需索引原 ERC20 `Transfer`。不在策略歷史資產集合的代幣，以及未經 executor 建立的外送生息收據，不屬於此服務的估值集合（與既有 yield registry 的 tracked claim 語意一致）。它們不會補本金；主人可直接原樣領回。
5. 提領前先透過 executor 將足夠資產／收據換成 USDT。帳戶 sudo UserOp 原子執行 `USDT.approve(ledger, W)`、`withdraw(W, recipient, minNet, deadline)`。recipient 不可為基金帳戶自己、ledger 或零地址。session key **不可**新增 ledger 的 start／withdraw 權限。

提領時 W 是含費的 USDT 總扣款，V 為提領前保守總價值，P 為本金：

- profit = `floor(W * max(V - P, 0) / V)`。
- fee = `floor(profit * performanceFeeBps / 10000)`，費率取當下生效版本。
- platformFee = `floor(fee * platformShareBps / 10000)`；創作者得 `fee - platformFee`，用戶得 `W - fee`。
- remainingPrincipal = `ceil(P * (V - W) / V)`，V≤P 也用此式。W=V 時本金必為 0。
- W=0、W 超過 USDT 餘額／V、低於 minNet、逾期、allowance 不足、非等額轉帳都回滾整筆（本金與已轉出的費用一起回滾）。profit／fee 向下、剩餘本金向上捨入，不多收用戶。
- 例 P=100、V=150、W=60、費率 20% → profit=20、fee=4、平台=0.4、創作者=3.6、用戶=56、P'=60。

平台從 fee 裡分成，初值 1000 bps（10%）；registry owner 可以 `schedulePlatformShare` 調成 0–2000 bps（最高 20%，集中於 `MAX_PLATFORM_SHARE_BPS`），7 天後才對後續提領生效。使用者已於 2026-11-16 確認 20% 上限；重新排程會重新等 7 天。它不會提高用戶支付的創作者費率。收款地址在部署時固定，owner 隨 registry 的二階段交接走。

## 保守估值與失敗出口

USDT 直接讀餘額。非 USDT 先以固定 **`1e18` 個資產原始單位**呼叫 router `previewSwap`，保留 pool／第二價格來源的完整有效性、過期與偏離檢查。這與 `PushFeedPriceSource.price()` 的尺度相同，讓 secondary quote 等於其價格值，避免拿實際 1 wei 持倉比較時，健康來源因向下／向上取整成 0／1 而被誤判偏離；基準量不隨持倉或 token decimals 改變，也不會被當成 NAV。再從同一個 `oracleOf(asset).pool()` 讀長窗與 5 分鐘累積 tick，對**實際持倉**走 ledger 專用的向下報價路徑並取較低者：token0 賣出用 floor(mean tick)，token1 賣出用 ceil(mean tick) 後反向；原始單位價格直接以 `1.0001^saleTick` 的定點有理數乘方計算，每次乘除及最終金額換算都向下取整，不沿用向上捨入的 sqrt／execution quote。價格 ≥1 用 Q128，<1 用 Q192，涵蓋 ±887272 tick 及不同 decimals，無需再乘 decimals 因子。**不能拿 router 取較高者的 execution floor 當 NAV**。預期部署仍使用 30 分鐘長窗；既有 oracle 允許 30–90 分鐘。通過來源有效性檢查後，金額合法向下取整為 0 的資產貢獻 0 NAV，包含第三方轉入的雙向 1 wei dust；任一持有資產無法讀餘額、缺來源、過期或讀取失敗仍拒絕結算，不把失敗當成 0。偏離上限仍為含等號的檢查；相關錯誤的報價數字現在對應基準量。空持倉不要求 oracle，因此賣光後只持 USDT 時不依賴價格源。

整數 tick 的保守折價是 C3 已接受的設計，**只允許低估，不允許高估**，並非「費用誤差 ≤1 wei」。對每一價格窗，令真實 sale tick 為 s、n=floor(s)、原始持倉為 A、未取整參考價值 T=A×1.0001^s。tick 折價小於 T/10001（約 1 bp）；定點乘方的單位價格誤差上界可取 ε(n)=(2|n|−1)×max(1,1.0001^n)/Q，n=0 時 ε=0，Q 為該方向的 2^128 或 2^192。因此最終 q 滿足 `0 <= T-q < T/10001 + A*ε(n) + 1`，最後的 1 是金額向下取整；各窗取低、各資產加總仍維持向下方向。這是隨價格與持倉變動的上界，不是固定的 USDT／wei 容差。ε 的界來自冪展開至多 |n| 個基底取整與 |n|−1 次乘法取整；正次方用相對誤差、負次方用絕對誤差界。

同一筆本金 P／領出 W 下，令參考 NAV 為 R、ledger NAV 為 L（L>0）、Δ=R−L、費率為 r（例如 20%=0.2），費用只會少收，其差額上界為 `ceil(r*W*P*Δ/(R*L))+2` 個原始 USDT 單位，涵蓋 profit／fee 兩次取整；剩餘本金也較低，差額至多 `ceil(W*P*Δ/(R*L))+1`。後續賣出資產會實現先前低估的價值，因此下一筆費用可能較高，不能把「同本金下不多收」誤寫成「每一筆後續費用都不高於另一條本金路徑」。測試用獨立的整數平方根精確計算 ±0.5 sale tick，涵蓋 token0／token1：P=100、USDT=50、資產=50、sale tick=+0.5、W=50、費率20%，第一筆少收 **249,987,500,781,195 wei**、本金少記 **1,249,937,503,905,977 wei**；負向向量 P=99 時分別為 **247,487,625,464,055／1,237,438,127,320,274 wei**。兩者均驗證上述上界，並在同價誠實清算的第二筆提領後，累計費用不超過高精度參考的兩筆費用及實際總獲利×費率；這些向量不是對所有未來價格路徑的證明。

資產集合直接讀 registry 的 `historicalAssets(strategyId)`，是所有曾生效版本的去重聯集，包含到期但尚未有交易 materialize 的最新版本；pending 與取消且未生效版本永久排除，即使取消版原 activeAt 已過。帳戶 enrollment 保留舊版本時仍跟隨新的生效資產，換版刪除的舊資產仍計價；不另維護 ledger 快取、cursor、去重 mapping 或同步入口。集合內也可能包括未曾持有版本的已列資產禮物。registry 將歷史聯集限制在 128 個不同資產（含有列入的 USDT），同一資產重複發版只讀一次。生息收據跳過普通 token 路徑，另讀 `accountMarkets`、`market`、`receiptAssets`，同時涵蓋 retired／停存市場；沿用 registry 的 identity／非零 rate 檢查、持有量與 tracked units 較小者、異常匯率保守 cap。`receiptAssets` 檢查成功後合法回傳 0 的 claim 貢獻 0 NAV，不再要求 underlying 的 oracle；例如 6 位 underlying 的 Lista 正常部分贖回後剩 1 receipt raw、tracked=1。identity、rate 或來源讀取真正失敗仍回滾整筆提領，不能用零 claim 跳過這些檢查。ledger 不觸發 accrue／同步，不改 yield 的 state；後端可先透過既有 executor 的 preview／交易同步，未同步的儲存匯率會低估而延後收費。

**ledger 的任何錯誤都不能卡住本金。** 主人可用 Kernel sudo 直接 ERC20 transfer（收據也可原樣轉回），完全不呼叫 ledger、executor 或 oracle。ledger 沒有 Kernel hook，不可讓 session policy 或前端把這個逃生出口拿掉。正常經 ledger 的設定變更退出／registry paused 退出仍收獲利費。

提領 gas 隨歷史去重後的資產數與生息倉位數增加，相同資產重複發版不再增加掃描成本；鏈上沒有任意截斷或跳過失敗資產。測試覆蓋同一組 93 資產 ×20 版，對所有讀取使用冷狀態後，完整 `withdraw` 呼叫須在 12,000,000 gas 內成功，為 BSC 單筆 16,777,216 gas 上限保留 Kernel／UserOp 空間；這不是實際 Kernel UserOp 成本保證，也不涵蓋 20 組各不相同的 93 資產。更接近 registry 上限的資產聯集或更多收據仍須另量測退出 gas，必要時走主人直接出口；外部審計仍是上主網前置。

## reporter 與後端對接（C3 最新定案）

- registry owner `setReporter(address, bool)`，可多個、可撤。owner 不會自動擁有 reporter 權限。
- 後端監看 ERC20 `Transfer`、executor `SwapExecuted`／`SupplyExecuted`／`WithdrawExecuted`、ledger `Deposited`／`Withdrawn`，按**整筆交易實際流量**核對，排除正常換幣、交易費、yield、投資虧損、直接轉入。
- 確認繞過服務後，由 reporter 呼叫 `stopService(account, epoch, evidence)`。evidence 建議用鏈上交易與核對報告的 hash；鏈上只記錄，不驗證其真偽。每個 epoch 只能停用一次，發 `ServiceStopped`；不能改本金、費率、餘額、allowance、registry 暫停或阻止 Kernel 直接提款。
- 停用後存／領記帳都拒絕；reporter 不能恢復。只有帳戶本人 `start()` 開新 epoch、本金清 0。舊 epoch 的延遲報告不得停用新 epoch；前端應提示既有餘額全部沒有本金保護。
- reporter 有誤報停服務的信任風險，**不具備純鏈上完整偵測能力**。餘額或 V<P 都不是自動退出條件。後端監測與簽送由後續 backend issue 實作，本 PR 沒改 backend。

## P11／#28 生效設定介面

#54 已合併，ledger 已完成 #28 整合：`registry.enrollments(account).strategyId` 識別基金，`registry.version(id,0).performanceFeeBps` 與 `.configHash` 讀當下生效的完整設定；`historicalAssets(id)` 提供曾生效資產聯集。`enrollments(account).version` 仍是最初本人同意的版本，供既有 yield policy 比對；ledger 不改 enrollment 或 yield policy。原本的 `registerCreatorFee`／`creatorFeeBps` bridge 及 `syncAssets`／`assetsThroughVersion` 等自有歷史狀態均已移除。

`configHash = keccak256(abi.encode(assets, weightsBps, scheduleHash, settingsHash, performanceFeeBps))`。`previewWithdraw`／`withdraw` 回傳的 `Withdrawal` 在既有欄位後附加 `uint16 performanceFeeBps, bytes32 configHash`；`Withdrawn` 事件也在原參數後附加同兩欄，讓 backend 按本次結算實際採用的費率與設定 hash 對帳，不把舊 enrollment 當報價版本。這是新 ledger 的 ABI，尚未對外部署；backend／app 應使用本版 ABI。

生效前 1 秒仍用舊費率與舊資產，精確等於 activeAt 自動跟隨新版，不需重新 enroll、登記費率、同步資產或先呼叫 registry 寫入。純降費在符合 7 天發版間隔後立即套用；調高費率仍至少等待 24 小時。取消不改目前費率／NAV，也不會讓取消版獨有資產進入之後歷史。來源／registry 讀取失敗都原子回滾；不因取消或讀取失敗遺失本金或先行付款。測試使用真實 P11 registry 驗證這些路徑，並保留有效 dust 與保守取整回歸。

#28 合約整合前置已完成；backend 的 reporter 監測、app／AA 存領接線與外部審計仍為對外啟用前置。

本金綁帳戶並 pin 住開始時的 strategyId；跨策略後拒絕繼續結算，避免把前創作者的獲利付給另一人。正常產品一策略一基金地址；換策略前應清算舊帳戶、在新基金地址投入。禁止平台補登、任意搬移本金或自動將舊獲利歸給新創作者。直接換策略者可走 Kernel 出口，或經 reporter 停服務後由本人本金 0 重新開始。

## 獨立測試網部署與 manifest

新增 `script/testnet/DeployPerfFeeLedger.s.sol`；只允許 chain 97，從 `PERF_LEDGER_EXECUTOR` 公開地址讀 registry／oracle／yieldRegistry／numeraire，驗證 yieldRegistry 屬於該 executor 及 registry，並在廣播前核對 registry 的 P11 常數（24 小時通知、7 天間隔、500–2000 bps、歷史聯集上限 128）。缺少 P11 API 或任一常數不符就拒絕部署；重跑亦核對。平台收款可設 `PERF_LEDGER_PLATFORM_RECIPIENT`，預設 TestnetBook 的 FEE_RECIPIENT。CREATE2 salt 獨立為 `perfFeeLedger.v1`，不改核心部署順序／地址；重跑驗證所有 pins，已存在就不發交易。腳本不讀私鑰或任何本機 key 檔。

本單僅做單元模擬，**沒有送任何公開鏈交易，也未更新真實已部署地址**。需要本機演練時僅限本單埠：

```bash
anvil --chain-id 97 --port 8612 --prune-history
# 先在同一個本機節點安裝核心（含 deterministic CREATE2 factory），使用 anvil 公開測試帳戶。
# 將腳本既有 TestnetBook.DEPLOYER 在本機 impersonate／fund；不讀測試網私鑰。
PERF_LEDGER_EXECUTOR=<local-executor> forge script script/testnet/DeployPerfFeeLedger.s.sol \
  --rpc-url http://127.0.0.1:8612 --unlocked --broadcast
pkill -f "anvil.*--port 8612"
```

未安裝核心／factory 會 fail closed。公開測試網廣播是另一次授權的工作，不要把上面的 RPC 改成公開鏈執行。

擴充欄位的可機讀定義在 `deployments/perf-fee-97.schema.json`。獨立部署後用腳本輸出的 PERF_FEE_* 和鏈上 getters／eth_getCode 核對，才在 manifest 加下列 `performanceFeeLedger` 欄位（省略表示未部署；本 PR 不編造地址、不改共用 `testnet-97.json`）：

```text
performanceFeeLedger: {
  address, registry, oracle, yieldRegistry, numeraire, platformRecipient,
  chainId: 97,
  initialPlatformShareBps: 1000,
  maxPlatformShareBps: 2000,
  platformNoticeSeconds: 604800,
  registryVersionDelaySeconds: 86400,
  registryPublicationIntervalSeconds: 604800,
  maxStrategyAssets: 128,
  minCreatorFeeBps: 500,
  maxCreatorFeeBps: 2000
}
```

部署本身不設 reporter、不發版、不 start 任一帳戶。公開上線前需由相應 owner／provider／帳戶本人分別完成 registry 設定發布、reporter 設定與帳戶 enroll／start，並串接 backend／app 的記帳路徑；不得把本金直接由資料庫匯入。
