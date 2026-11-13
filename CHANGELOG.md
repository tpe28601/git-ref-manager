# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本遵循 SemVer。

## [Unreleased]

### 變更

- 「功能說明」本地同步內容重新排版：原本 13 條項目清單改為「執行原則／兩種執行方式／防護與衝突／畫面解讀／重整與重開頁」五個小節，長条目拆分；粗體比照 Fetch Origin 的用法，僅保留風險提醒，資訊不變。

## [1.2.5] - 2026-11-13

### 新增

- 本地 Branch 備份的命名空間可自訂：勾選框旁新增輸入框（預設 `refs/sync/source-heads`，清空＝採預設），Web 與 CLI 皆適用，並存入「上次設定」。預覽與套用之間改動命名空間會以 planStale 要求重新預覽（plan 內的目標 ref 依預覽時的命名空間計算）。非法名稱（`..`、保留字 `refs/heads`、`HEAD`、`refs/bisect` 等）在預覽階段即拒絕；換命名空間後舊路徑的備份 ref 不再更新、也不會自動刪除。
- 開關「自動接續同步」（預設關，存設定）：一鍵同步進行中重整頁面、且尚未送出套用时，畫面還原、驗證全綠後自動接續送出——複用完整一鍵流程（origin 不同仍彈窗確認，不硬同步）。套用本身在伺服器執行，重整不會中斷進行中的套用。
- 套用完成後自動重掃一輪預覽，差異表格直接顯示同步後的最新狀態，不必再手動按「預覽差異」（失敗不自動掃，保留錯誤畫面；一鍵流程結尾自然接掃；重整後才結束的套用會等表格還原後再掃）。

### 修復

- 重整後同步流程要等 30 秒才還原：「上次設定」回填後只有來源框自動驗證，目的列驗證燈永遠停在未驗證，還原條件（全部驗證到終態）只能靠 30 秒兜底達成，畫面長時間看似無反應。現在重整後目的列也自動驗證（搭配 1.2.4 驗證快取），通常 2～4 秒內即還原預覽表格與按鈕狀態。

## [1.2.4] - 2026-11-13

### 效能

- 驗證摘要短效快取（TTL 8 秒）：重整頁面瞬間四個輸入框對同一批 Repo 同時驗證，重複路徑直接以主程式記憶體中的摘要回覆，不再每筆都開子行程掃 git（實測同波次重複驗證約 800ms → 90ms）。子行程掃完的結果自動餵回快取；驗證失敗的摘要不緩存，紅燈重試仍是即時重掃。
- Repo 摘要單趟掃描 Submodule：原本計數與清單要跑兩次 `git submodule status`，改為單一趟 `--recursive`（計數僅列頂層，與舊版一致；差異僅 `U` 衝突狀態改採與勾選清單相同的「不算已初始化」），並把 common dir 一併放入摘要，快取命中時比對來源／目的同一倉庫不用再跑 git。遞迴掃描失敗（例如某顆子模块工作樹損壞）會退回舊的非遞迴計數，不會靜默報 0 顆。
- 路徑輸入框按 Enter = 強制重驗（請求帶 `force` 繞過快取）：外部用指令動過 Repo 狀態後，不需改路徑即可取得最新值。「從 A 初始化 Submodule」完成後伺服器主動淘汰該目的 Repo 的快取摘要，重整或立即驗證都會取得初始化後的最新狀態。

### 修復

- 反向 D/F 衝突漏判：同步前檢查「目的端已有子分支」時，因 PowerShell 運算子優先序把 `BinarySearch` 的回傳值解析錯（`-not $idx - 1` 實為 `(-not $idx) - 1`），目的端清單無同名精確條目時該衝突永遠查不到，可能被推到執行同步才失敗。
- 重整後流程快照競態：續追的預覽工作先完成、「上次設定」尚未回填表單時，快照的來源／目的路徑會被空表單覆寫，導致下一輪重整無法比對還原。改為僅表單有值時才寫入快照。

### 開發

- tests/Core.Tests.ps1 新增 Get-RepoSummary 單趟掃描與 TTL 快取的 Pester 5 案例（本機僅有 Pester 3.4，另以等價 ad-hoc 腳本驗證 18 項全過）。

## [1.2.3] - 2026-11-13

### 新增

- 同步流程進行中重整頁面後自動回復上一輪流程：預覽表格以服務端仍存活的 job 重現，執行同步按鈕依套用 job 實際狀態顯示「套用進行中…／本輪已套用；最新差異請重新預覽／本輪套用失敗；請重新預覽後再執行」並維持停用——重整不會自動續送套用，使用者永遠在回復好的畫面上親按下一個動作。進行中的工作 log 續追由 1.2.1 的重整續追機制承擔。1.2.2 後未列的頂部 port 顯示亦併入本版。
- 頂部標題列顯示實際使用的本機服務 port，放在連線狀態左側。分頁列保留設定檔和功能說明。

### 修正

- 重整後「兩邊皆已初始化」的 Submodule 反而未預設勾選：「上次設定」可能在勾選清單尚未建好時存下空選取清單，還原時把預設全選清光且每次重整重複自我污染。現在清單未建時存 null、空清單視為無記錄不覆寫預設；上次因未初始化被略過的 Submodule 轉為可處理時採預設勾選，不再沿用舊的未勾狀態。

## [1.2.1] - 2026-11-11

### 新增
- 重整續追進行中的工作：正在追蹤的 job id 記入 localStorage（`grm.watch.v1`），頁面重新載入（F5、Hub 重建 iframe 等）後自動探測該 job 狀態，仍在進行中就重新接上輪詢，log 從頭重現；工作結束或伺服器已無此 job 時自動清除記錄。

## [1.2.0] - 2026-11-11

### 新增
- 分頁選擇與 Job log「自動捲動」偏好存入 localStorage，重整後維持上次狀態。

### 修正
- 「上次設定」自動記錄的 1 秒 debounce 遺失窗口：重整或關閉視窗時（pagehide）立即以 keepalive POST 補存，輸入後立刻重整也不再遺失設定。

## [1.1.1] - 2026-11-10

### 新增
- Dev-Toolbox 嵌入支援：辨識網址參數 `?theme=dark|light`（優先於本機儲存的主題）與 `?embedded=1`（隱藏本工具頂部列）。
- 介面改用 ui-kit 3.0：`tb-theme.js`（淺色／深色／跟隨系統三態主題、接收 Hub 的主題同步）、`tb-icons.js`（Lucide 圖標）；分頁列改成與 Opencode-Cfg-Manager 相同樣式。
- 導入 Dev-Toolbox 設計系統：`ui/ui-kit.css`（正本在 Dev-Toolbox，`Sync-UiKit.ps1` 同步），連結於 `style.css` 之前。

## [1.1.0] - 未發布

### 修正
- D/F 衝突漏檢：目的端 ref 清單原本用 `Sort-Object -Unique`（依地區設定排序、大小寫不敏感去重），
  與 `BinarySearch` 的 Ordinal 比對不一致，部分衝突要到 git 執行時才報錯。改為兩邊都用 Ordinal。
- 子行程錯誤回應的 `ConvertTo-Json` 補上 `-Depth`。

### 安全
- Web：檢查 `Host` 標頭（防 DNS rebinding）。
- Web：POST 必須帶 `X-Toolbox-Request: 1`、`Content-Type: application/json`，`Origin` 只接受自己與 Dev-Toolbox Hub；body 上限 1 MB。
- Web：回應加上 `X-Content-Type-Options`、`Content-Security-Policy: frame-ancestors`、`Referrer-Policy`。

### 新增（Dev-Toolbox 規格 specVersion 1）
- `tool.json`。
- Web：`GET /api/health`、`GET /api/info`；啟動時印出 `READY http://127.0.0.1:<port>`。
- Web：`-ParentPid`（父行程結束時自動關閉）、`-DataDir`；沒指定 `-Port` 時若 8756 被占用，自動往上找空 port。
- CLI：`-Version`、`-Help`；exit code 新增 3（參數不正確）、5（找不到 git）。
- `tests/Core.Tests.ps1`（Pester）。

### 變更
- 設定檔與工作紀錄改放 `%LOCALAPPDATA%\DevToolbox\git-ref-manager\`（`profiles\`、`history.jsonl`）。
  第一次啟動時會自動從工具資料夾複製舊的 `profiles\` 與 `job-history.jsonl`，舊檔保留不刪。

## [1.0] - 2026-11

- 先前版本（CLI 選單、Web 控制台、多目的 Repo、Submodule 初始化、Job 歷史）。
