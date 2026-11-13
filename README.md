# Git Ref Manager

**Git Ref Manager 1.2.4** 是 Windows 上的 Git ref／origin／worktree 管理工具，附 CLI 選單與本機 Web 控制台，支援 Submodule。

它主要解決一件事：**同一個專案在電腦上有好幾份 Clone，卻不想每一份都連網路 fetch 一次。** 只要其中一份（A）fetch 過，就能把 A 的 `origin/*` 離線同步到其他 Clone（B、C…），連同所有 Submodule 一起處理。

> 它是 [Dev-Toolbox](https://github.com/tpe28601/Dev-Toolbox) 的工具之一，可以從 Hub 啟動並嵌入顯示，也可以單獨使用。

## 功能

| 功能 | 說明 |
|---|---|
| **本地同步** | A → 一個或多個 B，離線同步 `refs/remotes/origin/*`。可選擇要不要備份 A 的本地 Branch，也可以遞迴處理 Submodule。 |
| **Fetch Origin** | 讓兩份 Clone 各自連線 fetch origin，可以加 `--prune`、遞迴 Submodule。 |
| **Worktree** | 建立新資料夾加新 Branch 的 linked worktree。建立前會檢查名稱、路徑、Branch、起始 Ref，並提出 `.gitmodules` 相關警告。 |
| **Auto 模式** | 非互動的一鍵同步，適合排程或腳本：同步 `origin/*` 加上所有已初始化的 Submodule，一次判斷衝突。 |

### 安全原則

- **只更新 Git Ref 與必要的 Commit 物件。** 不 push、不 reset、不 checkout、不刪除目的端多出來的 Ref，也不改工作目錄的內容。
- 更新 `refs/remotes/origin/*` 只影響本機，遠端伺服器不會收到任何 push。
- 目的端的 origin URL 和 A 不同時，一定會先提醒你，確認後才執行。Auto 模式遇到這種情況會直接中止。
- 唯一會寫入工作目錄的操作，是 Web 版的「從 A 初始化」Submodule，而且只有你主動按下才會執行（詳見下方）。

## 需求

- Windows 10／11
- Windows PowerShell 5.1 或 PowerShell 7+
- [Git for Windows](https://git-scm.com/download/win)（可以在 PowerShell 執行 `git --version`）
- 不需要管理者權限，不需要安裝其他套件

## 快速開始

```bat
git clone https://github.com/tpe28601/git-ref-manager.git
cd git-ref-manager
```

| 想做的事 | 執行 |
|---|---|
| 開 Web 控制台（推薦） | 雙擊 `Run-Git-Ref-Manager-Web.bat`，瀏覽器會自動開啟 |
| 用 CLI 選單 | 雙擊 `Run-Git-Ref-Manager.bat` |
| 排程或腳本 | 見下方<Auto 模式> |

第一次使用，建議先拿一份壞了也沒關係的 Clone 測試。

## Web 控制台

啟動後，瀏覽器會開啟 `http://127.0.0.1:8756`。

- 8756 不能用時，會往上找可用的 port（最多找 20 個）。都不行就請系統分配一個空的 port。實際網址會印在視窗上。
- 只綁定 `127.0.0.1`，不對外開放。要停止就關掉視窗，或按 `Ctrl+C`。
- 只接受本機頁面送出的請求，會檢查 `Host`、`Origin` 與 `X-Toolbox-Request` 標頭，所以其他網站的網頁無法替你觸發同步。
- 主題可以切換淺色、深色、跟隨系統。

### 本地同步

1. 填入來源 Repo A，再按「新增目的 Repo」加入一個或多個 B。每個路徑框右側有驗證燈：
   - 轉圈：驗證中
   - ✓：通過，點一下可以看分支、origin、未提交變更、Submodule 明細
   - ✗：失敗，原因顯示在框下方
   - 路徑框按 Enter = 強制重新驗證（繞過伺服器數秒的短效快取，外部動過 Repo 時取最新）
2. 勾選要同步的項目：`origin/*`、本地 Branch 備份、Submodule。在 Submodule 清單可以逐顆勾選，還沒初始化的會灰顯並略過。
3. 選一種方式執行：
   - **預覽差異**：每個目的 Repo 一個區塊，列出新增、更新、衝突略過的數量，確認後再按「執行同步」。
   - **一鍵同步**：自動驗證、預覽，有差異就直接套用（只需確認一次）。

**從 A 初始化 Submodule**：B 的某個 Submodule 還沒初始化、但 A 已經初始化時，會出現這個按鈕（只有一個目的 Repo 時才有）。它會用 A 的本機複製在 B 裡 clone 並 checkout 這個 Submodule，全程離線。完成後，這個 Submodule 的 origin 會暫時指向 A 的本機路徑，需要時請用 `git submodule sync` 或 `git remote set-url` 改回來。

### 其他

- **設定檔**：可以把三個分頁的路徑、選項和 Submodule 勾選存成具名設定檔，下次直接載入。任何變更也會自動記成「上次設定」，重新打開頁面時自動還原。
- **工作面板**：即時顯示 log 和進度。預覽、同步、Fetch、Worktree 這類工作一次只跑一個。Repo 驗證在背景執行，最多 3 個同時進行。
- **歷史紀錄**：保留最近 100 筆工作，重開伺服器後還查得到，可以唯讀瀏覽當時的 log。
- 每個分頁右上角都有「功能說明」，裡面有完整說明和注意事項。

## CLI 選單

```
[1] 本機 A → 多個目的 Repo 同步 Ref（可含遞迴 Submodule，離線）
[2] 兩份 Repo 各自 Fetch origin（可含遞迴 Submodule，需網路）
[3] 建立 Worktree（共用 origin/*）
[4] Auto：同步 origin/* ＋ 所有 Submodule（可多個目的，彙總預覽，一次確認）
```

## Auto 模式（排程／腳本）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Git-Ref-Manager.ps1 `
  -Src C:\src\sample -Dst C:\src\sample_2 -Auto -Yes

# 多個目的端（分號分隔，可與 -Dst 併用，會自動去重）
powershell -NoProfile -ExecutionPolicy Bypass -File Git-Ref-Manager.ps1 `
  -Src C:\src\sample -DstList "C:\src\sample_2;C:\src\sample_3" -Auto -Yes
```

| 參數 | 說明 |
|---|---|
| `-Src` | 來源 Repo A |
| `-Dst`／`-DstList` | 目的 Repo；`-DstList` 用分號分隔多個 |
| `-Auto -Yes` | 非互動執行（兩個一起用，而且一定要指定 `-Src` 和目的端） |
| `-BackupHeads` | 一併把 A 的本地 Branch 備份到 `refs/sync/source-heads/*` |
| `-Version`／`-Help` | 顯示版本／用法 |

**Exit code**

| 代碼 | 意義 |
|---|---|
| 0 | 全部成功 |
| 1 | 失敗 |
| 2 | 成功，但有略過的項目（D/F 衝突、跳過的 Submodule） |
| 3 | 參數不正確 |
| 5 | 環境不符（找不到 git） |

排程範例（每天 09:00）：

```bat
schtasks /Create /TN "SyncRepoRefs" /SC DAILY /ST 09:00 /F ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Tools\git-ref-manager\Git-Ref-Manager.ps1 -Src C:\src\sample -Dst C:\src\sample_2 -Auto -Yes"
```

## Web 伺服器參數

```powershell
.\Git-Ref-Manager-Web.ps1 [-Port 8756] [-OpenBrowser] [-DataDir <路徑>] [-ParentPid <pid>] [-HubOrigin <url>]
```

| 參數 | 說明 |
|---|---|
| `-Port` | 指定 port；有指定時只試這一個 |
| `-OpenBrowser` | 啟動後自動開瀏覽器 |
| `-DataDir` | 資料夾位置（見下方） |
| `-ParentPid` | 父行程（例如 Dev-Toolbox Hub）結束時，自動關閉 |
| `-HubOrigin` | Hub 的實際網址，允許它嵌入本頁 |

啟動成功時，stdout 第一行會印出 `READY http://127.0.0.1:<port>`。

## 資料存放位置

使用者資料不會放在工具資料夾裡：

```
%LOCALAPPDATA%\DevToolbox\git-ref-manager\
├─ profiles\        Web 版設定檔（<名稱>.json、_last.json）
└─ history.jsonl    工作歷史（最近 100 筆）
```

位置的優先順序：`-DataDir`，其次是 `%DEVTOOLBOX_DATA%\git-ref-manager`，最後才是上面的預設位置。

## 已知限制

- **Submodule**：只處理兩邊都已初始化、而且路徑對得上的 Submodule。沒初始化、或兩邊 origin URL 不同的會跳過並回報。同步流程不會自動 clone 或切換版本。
- **D/F 衝突**：同一個名字在 A 是資料夾、在 B 是分支（例如 A 有 `feature/x`，B 有 `feature`）時，會略過那個 Ref 並回報。要解決，請手動刪掉目的端過時的追蹤 Ref。
- **只差大小寫的 Ref**（例如 `Alice` 和 `alice`）在 Windows 上沒辦法穩定比對，會一律略過並回報。這是固定的現象，不是操作失敗。
- `refs/remotes/origin/HEAD` 這類 symbolic ref 一律略過。

## 疑難排解

| 狀況 | 處理 |
|---|---|
| 瀏覽器連不上 | 確認啟動視窗還開著，並看視窗上印的實際 port |
| 啟動時顯示「存取被拒」 | port 可能被 Windows 保留，用 `netsh interface ipv4 show excludedportrange protocol=tcp` 查看；不指定 `-Port` 會自動改用別的 port |
| 介面更新後沒變 | 按 `Ctrl+F5` 強制重新整理 |
| git 指令失敗 | 錯誤訊息都會顯示在工作面板的 log 裡 |

## 專案結構

```
Git-Ref-Manager.ps1          CLI 選單／Auto 模式
Git-Ref-Manager-Web.ps1      Web 控制台伺服器（HttpListener）
GitRefCore.ps1               共用核心（CLI 與 Web 用同一套邏輯）
cli-kit.ps1                  CLI 樣式（Dev-Toolbox 同步的複本）
ui\                          Web 前端（ui-kit 3.0、Lucide 圖標）
tests\Core.Tests.ps1         Pester 測試
tool.json                    Dev-Toolbox 工具描述檔
```

執行測試：

```powershell
Invoke-Pester -Path tests
```

## 授權

[MIT](LICENSE)。介面圖標來自 [Lucide](https://lucide.dev)（ISC 授權）。
