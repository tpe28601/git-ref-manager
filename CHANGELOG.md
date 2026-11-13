# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本遵循 SemVer。

## [Unreleased]

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
