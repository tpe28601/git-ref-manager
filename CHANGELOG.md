# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本遵循 SemVer。

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
