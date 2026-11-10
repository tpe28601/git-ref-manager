Git Ref / Origin / Worktree 管理工具（CLI + Web 控制台，支援 Submodule）
=====================================================================

內容：
  GitRefCore.ps1                共用核心函式（CLI 與 Web 使用同一套邏輯）
  Git-Ref-Manager.ps1           CLI 選單版 / 命令列 Auto 模式
  Git-Ref-Manager-Web.ps1       本機 Web 控制台伺服器（純 PowerShell）
  ui\                           Web 前端（index.html / app.js / style.css）
  tool.json                     Dev-Toolbox 工具描述檔（版本、入口、port）
  tests\                        Pester 測試（Invoke-Pester -Path tests）
  使用者資料（3.1 起不再放在工具資料夾）：
    %LOCALAPPDATA%\DevToolbox\git-ref-manager\history.jsonl   Web 版工作歷史（最近 100 筆）
    %LOCALAPPDATA%\DevToolbox\git-ref-manager\profiles\       Web 版設定檔（<名稱>.json 與 _last.json）
    第一次啟動會自動從工具資料夾複製舊的 profiles\ 與 job-history.jsonl（舊檔保留）。
    可用 -DataDir 或環境變數 DEVTOOLBOX_DATA 改位置。
  Run-Git-Ref-Manager.bat       雙擊啟動 CLI 選單
  Run-Git-Ref-Manager-Web.bat   雙擊啟動 Web 控制台並自動開瀏覽器

環境需求：
  - Git for Windows（PowerShell 可執行 git --version）
  - Windows PowerShell 5.1 或 PowerShell 7+（不需安裝任何其他東西）
  - 不需要管理者權限（Web 版用 TcpListener，不走 HTTP.sys）

============================================
一、Web 控制台（Run-Git-Ref-Manager-Web.bat）
============================================
  啟動後瀏覽器自動開啟 http://127.0.0.1:8756
  （8756 被占用時會自動改用 8757～8776 中第一個空的埠，實際位址印在視窗上；
    也可以用 powershell -File Git-Ref-Manager-Web.ps1 -Port 其他埠 指定）
  安全：只接受本機頁面送出的請求（檢查 Host、Origin 與 X-Toolbox-Request 標頭），
    其他網站的網頁無法替你觸發同步或建立 Worktree。
  只綁定 127.0.0.1，不對外網開放；停止＝關閉視窗或 Ctrl+C。

  [本地同步] A -> 一個或多個目的 Repo 離線同步 Ref：
    1. 輸入（或用資料夾圖示按鈕瀏覽／掃描）Repo A，並在「Repo B」區按
       「新增目的 Repo」加入一個或多個目的端（每列可單獨瀏覽；只剩一列時
       不出現移除鈕）。每個路徑框右內緣有驗證燈：空白＝未驗證、
       轉圈＝驗證中、綠 ✓＝通過、紅 ✗＝失敗（錯誤顯示在框下）。
       按 Enter、移到別處或選完資料夾會觸發驗證；打字途中不會發請求；
       移到別處時同一路徑不重複驗證（超大 Repo 驗證一趟可能要幾十秒），
       按 Enter 則一律強制重驗。若在工具外變動過 Repo 狀態（例如手動
       submodule update），可用 Submodule 清單工具列右側的「重新驗證」
       讓來源與所有目的 Repo 一次全部重驗並更新清單。目的 Repo 增列、
       刪列或換路徑後，清單改用各列已驗證的資料在本地重組，不會再補
       跑驗證；送出預覽／一鍵同步前另做一次輕量比對（只讀初始化狀態），
       工具外動過 submodule init 時自動刷新勾選清單並保留你的勾選。
       點綠 ✓ 可展開／收合分支／origin／未提交變更／Submodule 明細
       （預設收合）。驗證來源 Repo 通過後才會出現 Submodule 勾選清單。
       A 與 B 不能同路徑：目的列與來源相同會彈窗提示並擋下；兩條目的
       列路徑重複時，後面那條以紅旗標記驗證失敗（比對已忽略大小寫與
       斜線方向的差異）。
    2. 勾選要同步的項目（origin/*、本地 Branch 備份、Submodule 遞迴）。
       「Submodule 勾選」清單：預設全選兩邊都已初始化者，未初始化者灰顯
       並標示會略過；取消勾選者會列進預覽的「跳過的 Submodule」。
       清單預設收合，標題直接顯示「已選 x／可處理 y、略過 z」，不用
       展開就能確認勾選狀態。
       變更勾選後舊預覽作廢，需重新預覽。
       （勾選功能為 Web 版專屬；CLI Auto 一律處理全部已初始化者。）
       B 側「未初始化」但 A 側已初始化的項目（僅單一目的 Repo 時）會出現
       「從 A 初始化」按鈕：以 A 工作目錄的本機複製在 B 初始化該 Submodule
       （離線，不連網路），完成後自動重新驗證。注意這會寫入 B 的工作目錄
       與 .git/config，且該 Submodule 的 origin 會暫時指向 A 的本機路徑，
       需要時請自行以 git submodule sync／set-url 改回。
       巢狀 Submodule 請先初始化外層、重新驗證後再逐顆處理。
    3. 兩種執行方式：
       - 「一鍵同步」：自動補驗證未驗證的 Repo -> 自動預覽 -> 若無差異
         提示後結束；有差異直接套用（一次確認，全部目的端一起執行）。
         目的端 origin URL 與 A 不同時會先彈窗列出差異來源，確定才以
         forceOrigin 執行，取消則不執行。「一鍵同步」右側的 force 勾選＝
         預先同意 forceOrigin：勾了之後一鍵同步不再彈窗，「執行同步」也
         直接套用（與預覽面板內的 forceOrigin 核取方塊擇一即可）。
       - 「預覽差異」：每個目的 Repo 一個區塊，列出主 Repo 與每個
          Submodule 的新增/更新數量、衝突略過數量與跳過的 Submodule
          清單；衝突明細點該列的 chevron 按鈕才展開。區塊預設全部
          收合，點目的 Repo 的標題列可展開／收合整個區塊（收合仍看得到
          數量統計）；兩個以上目的 Repo 時合計列右側有「全部收合／
          全部展開」。確認後在預覽結果內按「執行同步」（沒按預
          覽就不會有這顆按鈕）；origin 不同者勾選 forceOrigin
          核取方塊後才能執行。

  [Fetch Origin]：兩份 Clone 各自連線 fetch origin（可 --prune、可遞迴
    Submodule）；按鈕按下去後還有一次確定。

  [Worktree]：建立新資料夾＋新 Branch 的 linked Worktree；
    「檢查」會逐項驗證名稱／路徑／Branch／起始 Ref 與 .gitmodules 警告。

  三個分頁右上角都有「功能說明」按鈕，點開該功能的完整說明與安全注意事項。

  [設定檔]（分頁列「設定檔」按鈕）：
    - 點分頁列的「設定檔」鈕開啟彈出面板（點外面或按 Esc 關閉）。
      「儲存新設定」把三個分頁的路徑、選項與 Submodule 勾選存成一個具名
      設定檔（存於資料夾 profiles\<名稱>.json，可存多個，重啟伺服器
      仍在）；下拉選單選取後立即載入並自動重新驗證各 Repo，另有覆寫／刪除。
    - 任何欄位變更都會自動記錄「上次設定」（profiles\_last.json），重新
      開啟頁面時自動還原並重新驗證；面板關著時這些訊息以右下角提示顯示。

  下方「工作面板」即時顯示 log 與進度；預覽／同步／Fetch／Worktree 等
  「工作」一次只執行一個，期間新觸發的工作會被擋下。
  面板不會因開始執行而自動展開，狀態看徽章：待機 -> 等待指令中（送出／
  驗證／排隊中，一鍵同步跨預覽與套用的空隙也算）-> 進行中 -> 整個流程
  全部跑完才寫完成／失敗（中途不會先跳完成再跳執行中）。面板收合時工作
  結束，標題列會亮小圓點（展開即消失）；只有被「已有工作進行中」擋下或
  查看歷史紀錄時才會自動展開。
  Repo 驗證採背景子行程，最多 3 筆同時進行（超出的自動排隊）；Submodule
  「從 A 初始化」同時限一筆，與其他工作互斥。頂部徽章與排隊提示會顯示目前狀態。
  Log 預設自動捲到最新（面板上「自動捲動」可關閉）；往上翻閱時不會被
  拉回，右下角出現「到最新」按鈕可一鍵跳回。
  面板高度可用標題與 Log 之間的手把拖拉調整（會記在瀏覽器，雙擊手把
  還原預設）。
  面板時鐘圖示「歷史紀錄」：列出最近 100 筆工作（編號／類型／狀態／
  時間／摘要），點一筆即可在工作面板唯讀瀏覽該筆 Log，按「返回即時」
  回到目前工作；工作進行中也能瀏覽，即時進度在背景更新。歷史會寫入
  資料夾的 history.jsonl（保留最近 100 筆），重啟伺服器後
  仍可查詢。
  介面隨視窗寬度調整：窄視窗單欄排版、按鈕換行，預覽表格可橫向捲動。

====================================
二、CLI 選單版（Run-Git-Ref-Manager.bat）
====================================
  [1] 本機 A -> 多個目的 Repo 同步 Ref（可含遞迴 Submodule，離線）
  [2] 兩份 Repo 各自 Fetch origin（可含遞迴 Submodule，需網路）
  [3] 建立 Worktree（共用 origin/*）
  [4] Auto：同步 origin/* + 所有 Submodule（可多個目的，彙總預覽，一次確認）

====================================
三、命令列 Auto 模式（排程／腳本用）
====================================
  powershell -NoProfile -ExecutionPolicy Bypass -File Git-Ref-Manager.ps1 `
    -Src D:\RepoA -Dst D:\RepoB -Auto -Yes

  多個目的端用 -DstList（分號分隔；與 -Dst 可併用，自動去重）：
    ... -File Git-Ref-Manager.ps1 -Src D:\RepoA -DstList "D:\RepoB;D:\RepoC" -Auto -Yes

  - 自動：origin/* 同步 + 遞迴所有已初始化 Submodule + 一次判斷衝突。
  - exit code：0 全部成功；1 失敗；2 成功但有略過項（D/F 衝突、
    跳過 Submodule）。
  - 任一目的端 origin URL 與 A 不同時，-Auto -Yes 會直接中止（防呆）。
  - 加 -BackupHeads 可一併備份 A 本地 Branch 到 refs/sync/source-heads/*。

  排程範例（每天 09:00）：
    schtasks /Create /TN "SyncRepoRefs" /SC DAILY /ST 09:00 /F ^
      /TR "powershell -NoProfile -ExecutionPolicy Bypass -File D:\Tools\Git-Ref-Manager\Git-Ref-Manager.ps1 -Src D:\MyProject -Dst D:\MyProject_2 -Auto -Yes"

================
共同行為與限制
================
  - 同步本身只更新 Git Ref 與必要的 Commit 物件：不 push、不 reset、不
    checkout、不刪除目的端多餘的 Ref、不修改工作目錄內容。
    唯一例外是 Web 版「從 A 初始化」Submodule：它會在 B 克隆並 checkout 該
    Submodule（離線、以 A 的本機複製為來源），並寫入 B 的 .git/config；
    此後該 Submodule 的 origin 暫時指向 A 的本機路徑，請自行改回。
  - Submodule 同步：只處理兩邊都「已初始化」且路徑可配對者；未初始化或兩邊
    origin URL 不同會跳過並回報，同步流程絕不自動 clone 或切換版本
    （自動 clone 只發生在上條使用者主動點擊的「從 A 初始化」）。
  - D/F 衝突（同一名字在 A 是資料夾、在 B 是分支）會自動略過該 Ref 並在
    結果中回報；要解決請手動刪除目的端過時的舊追蹤 Ref 後再同步。
  - 大小寫重複的 ref（如 LeoLi / Leoli）在 Windows 上無法穩定比對，
    一律略過並回報，每次預覽都會重現，屬固定現象而非操作失敗。
  - symbolic ref（refs/remotes/origin/HEAD）一律略過。
  - 更新 refs/remotes/origin/* 不代表遠端伺服器收到任何 Push。
  - 首次操作建議先在可還原的 Clone 上測試。

疑難排解：
  - 瀏覽器連不上：確認 Run-Git-Ref-Manager-Web.bat 視窗還開著、埠號正確。
  - 介面更新沒生效：瀏覽器重新整理（Ctrl+F5）。
  - 所有 git 錯誤訊息都會顯示在「工作面板」log 裡。
