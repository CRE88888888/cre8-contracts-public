# AGENTS.md — cre8-contracts

給 AI agent 與新工程師的工作規則。內容皆從本 repo 程式碼、README 與 commit 歷史查證；不確定的地方會寫明。

**Claude 與 Codex 分工**：規則見 [docs/AGENT_COLLABORATION](https://github.com/CRE8Finance/docs/blob/main/docs/AGENT_COLLABORATION.zh-TW.md)。本 repo 的程式碼（合約、測試、部署腳本、fork 預演）只有 Claude 寫。開工前先看本 repo 有沒有標 `agent:claude` 或 `agent:codex` 的進行中 issue，有就排隊；分支前綴 Claude 用 `claude/*`、Codex 用 `codex/*`。

## 這個 repo 是什麼

CRE8 ATP（Automated Token Portfolio）的 BSC 智慧合約，Foundry 專案。自 bnb-agent-vaults 的 pooled-vault 架構遷出：每人一個 non-custodial smart account，平台只做「權重＋排程」的執行與分發。核心不變式與 spec 見 README（spec 檔在 bnb-agent-vaults repo）。

與其他 repo 的介面（已確認的部分）：
- backend：透過環境變數 `REGISTRY_ADDRESS`、`EXECUTOR_ADDRESS` 指向本 repo 部署出的 `AtpRegistry` / `AtpExecutor`；backend 的 `scripts/refresh-anvil.sh`、`scripts/deploy-elon-oracles.sh` 假設本 repo 與 backend 是同層目錄（`../cre8-contracts`），會在這裡跑 `forge inspect` 取 bytecode。
- cre8-app：`docs/architecture.md` 以 `src/atp/*.sol` 為對照來源，沒有直接 import 本 repo。
- db、cre8-landing：本 repo 沒有直接介面。

## 目錄地圖

- `src/atp/`：`AtpRegistry`（策略版本、fee、enroll）、`AtpExecutor`（唯一搬錢的合約）、`PancakeV3TwapOracle`（per-pair TWAP 地板）、`AtpMultiPoolOracle`（asset → per-pair oracle 的 router，numeraire = USDT）、`interfaces/`
- `test/atp/`：單元測試；`test/atp/fork/`：BSC mainnet fork 測試（需要 RPC）
- `script/DeployAtp.s.sol`：部署腳本，內含 fork（chain 56）的位址簿常數，可重複執行
- `scripts/deploy-fork.sh`：起 anvil fork 並部署、寫 `deployments/fork.json`
- `deployments/`：位址紀錄（見下）
- `lib/`：`openzeppelin-contracts`（5.4.0）與 `forge-std`，**直接 commit 進來（vendored），不是 git submodule**

## 常用指令

工具鏈：solc 0.8.37、via_ir、optimizer 200、evm cancun（見 `foundry.toml`）。本機驗證用 forge 1.8.3，CI 釘同版本。不需要另外安裝依賴（lib 已 vendored）。

```bash
forge build                      # 編譯 src/test/script
FOUNDRY_PROFILE=ci forge test    # 與 CI 相同（fuzz 2000 runs）；fork 測試在沒有 BSC_RPC_URL 時顯示 skipped
forge test                       # 預設 profile
forge fmt --check                # 格式檢查（目前全部通過，未列入 CI）
```

需要環境變數的：
- fork 測試：`cp .env.example .env`，填 `BSC_RPC_URL`（BSC mainnet RPC）。未設時 `vm.skip(true)`，報 skipped 而非 passed。
- `scripts/deploy-fork.sh`：需要 `anvil`/`cast`/`jq` 與網路；讀 `BSC_MAINNET_RPC`（預設 publicnode）、`ANVIL_PORT`，用 anvil 預設測試私鑰。

## 部署與 deployments/

- fork 部署：`bash scripts/deploy-fork.sh`，或手動 `forge script script/DeployAtp.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`。`DeployAtp` 對位址簿常數「有 code 就重用並重新驗證 pin、沒有才重新部署」；`new` 的順序決定 nonce，不可調換。
- `deployments/fork.json`：anvil fork 上的權威位址，由 `broadcast/.../run-latest.json` 對照鏈上 `eth_getCode` 產生；`fork-state.json` 是同時間點的狀態快照。**fork 重啟後兩份都要重新產生，不可手改。** 細節（publicnode 約 75 分鐘歷史窗口、刷新方式）見 `deployments/README.md`。
- `deployments/mainnet.json`：BSC 主網（chain 56）位址、部署者、池子與流動性紀錄，部署後手動寫入，commit 訊息附上位址與 `cast code` 驗證結果（見 `d1f94ff`、`1014063`）。DOGE oracle 是後來單獨部署＋`setOracle` 的。
- **`DeployAtp` 的位址簿常數是 fork 位址，不是主網位址**（已用 `cast codesize` 確認這些位址在主網沒有 code）。對主網 RPC 重跑它不會重用既有部署，而是整套重新部署出第二個 registry/executor。
- `broadcast/`、`.env` 被 gitignore，不進版控。

## 主網部署前的安全注意

- 私鑰只放環境變數或 `--private-key`／keystore，**不進任何檔案**；`foundry.toml` 的 `rpc_endpoints` 只能用 `${ENV}`，不得寫帶憑證的 RPC URL。
- `AtpRegistry`、`AtpMultiPoolOracle` 的 owner 在 v1 是單一 key，程式碼 TODO 寫明主網前要換 multisig / timelock；`AtpExecutor` 的 `feeRecipient` 在 `DeployAtp` 裡是 `msg.sender`，註解要求主網前改為 treasury。
- oracle 一旦部署就永久綁定一個池子：上主網前要實測池子流動性與雙向報價（DOGE 曾因 fee=500 死池、fee=2500 報價差 20 倍而改用 fee=10000），且池子的 observation cardinality 要能服務 30 分鐘 TWAP 與 5 分鐘近期均值兩個窗口。
- 換 oracle 只能 `clearOracle` 再 `setOracle`，`setOracle` 不會覆寫。
- `AtpExecutor` 在 chain 56/97 會強制 canonical Permit2 位址。
- publicnode 對 archive 查詢與 `cast send` 會回 403，主網交易改用官方 dataseed RPC。
- 任何主網交易（部署、`setOracle`、`transferOwnership`、`setFeeRecipient`）都要先在 fork 上跑過，並由人確認後才送出。

## 開 PR 前必跑（與 CI 一致）

```bash
forge build
FOUNDRY_PROFILE=ci forge test
```

改合約時有 RPC 的話再跑一次帶 `BSC_RPC_URL` 的 fork 測試，並在 PR「怎麼驗證」寫明。

## 規則與地雷

- 改動只做被要求的部分，不順手重構。
- 不確定就問，不要猜；尤其是任何會動到主網資金或 owner 權限的事。
- 不要升級或改動 `lib/` 內容；OpenZeppelin 刻意 pin 在 5.4.0。
- `scripts/deploy-fork.sh` 寫死了 `/Users/jareklin/.foundry/bin/*` 路徑，其他機器要自行調整後再跑（不要把個人路徑改成另一個個人路徑 commit 進來）。
- `deploy-fork.sh` 產生的 `fork.json` 欄位比目前檔案少（多池欄位是依 `DeployAtp` 輸出補上的），重跑前先確認要保留什麼。
- 合約內的 `TODO` 是已知限制（如 account → executor 仍走 `safeTransferFrom` 而非 Permit2），不要在無關 PR 順手處理。

## Commit / PR 慣例

- commit 標題用繁體中文一句話，動詞開頭（「新增…」「補…」「主網新增…」）；body 條列改了什麼、測試數量，主網操作要附位址與驗證結果。
- PR 依 `.github/pull_request_template.md` 填寫；「風險」要寫明是否影響主網資金或部署。
