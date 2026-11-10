# Git Ref / Origin / Worktree Manager (CLI 選單版)
# Windows PowerShell 5.1 或 PowerShell 7+
# Features:
# 1. 本機 A -> B 同步 refs/remotes/origin/*（可含 Submodule）
# 2. 兩份獨立 Clone 各自 Fetch origin
# 3. 建立 Worktree（共用 refs/heads、refs/remotes/origin）
# 4. Auto：A -> B 一鍵同步 origin/* + 所有已初始化 Submodule（一次確認）
# 非互動排程： -Src <A> -Dst <B>（或 -DstList "B1;B2"）-Auto -Yes
#   exit code（Dev-Toolbox TOOL-SPEC 第 4 節）：
#     0 成功、1 失敗、2 成功但有略過項（D/F 衝突或跳過 Submodule）、
#     3 參數不正確、5 環境不符（找不到 git）
# 其他： -Version 印出版本；-Help 顯示用法
# 本腳本永不執行 git push / git reset，也不刪除 Git Ref。

param(
    [string]$Src,
    [string]$Dst,
    [string]$DstList,
    [switch]$Auto,
    [switch]$Yes,
    [switch]$BackupHeads,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'GitRefCore.ps1')

function Pause-End {
    [void](Read-Host "`n按 Enter 結束")
}

function Confirm-Yes([string]$Question) {
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(?i:y|yes)$')
}

function Select-Folder([string]$Title) {
    # GUI 資料夾選取；失敗時退回手動輸入路徑。
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Title
        $dialog.ShowNewFolderButton = $true
        $result = $dialog.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
        throw '已取消選取資料夾。'
    }
    catch {
        if ($_.Exception.Message -eq '已取消選取資料夾。') { throw }
        Write-Warning ('無法開啟資料夾視窗：' + $_.Exception.Message)
        $path = Read-Host "$Title（請輸入完整路徑）"
        if ([string]::IsNullOrWhiteSpace($path)) { throw '未輸入資料夾路徑。' }
        return $path.Trim('"')
    }
}

function Choose-Repo([string]$Prompt) {
    Write-Host "`n$Prompt" -ForegroundColor Cyan
    $chosen = Select-Folder $Prompt
    $root = Get-GitRoot $chosen
    Write-Host "已選擇：$root" -ForegroundColor Green
    return $root
}

function Split-DstArg([string]$ListArg) {
    # 解析 -DstList "B1;B2;..." -> 路徑陣列（去空、去重）
    $seen = @{}
    $out = @()
    foreach ($tok in ($ListArg -split ';')) {
        $t = $tok.Trim().Trim('"')
        if (-not $t) { continue }
        $k = $t.ToLowerInvariant().TrimEnd('\')
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $t
    }
    return $out
}

function Ask-ExtraDst {
    # 互動追加更多目的 Repo，直到輸入空白為止；回傳已驗證的 Git Root 清單。
    $extra = @()
    while ($true) {
        $line = Read-Host '其他目的 Repo 路徑（可多個，留空代表結束）'
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        try {
            $root = Get-GitRoot $line.Trim().Trim('"')
            Write-Host "已加入：$root" -ForegroundColor Green
            $extra += $root
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
    return $extra
}

function Build-SyncPairs($SrcRoot, [string[]]$DstRoots, $Options) {
    # 逐目的 Repo 產生 @{ Dst=; Plan= }；Fatal 的只警告並列入 Skipped。
    $pairs = @()
    $dead = @()
    foreach ($d in @($DstRoots)) {
        if (-not $d) { continue }
        $plan = New-SyncPlan -Src $SrcRoot -Dst $d -Options $Options -OnLog { param($m) Write-Host "  $m" }
        if ($plan.Fatal) {
            Write-Warning "[$d] $($plan.Fatal)"
            $dead += $d
            continue
        }
        $pairs += @{ Dst = $d; Plan = $plan }
    }
    return @{ Pairs = $pairs; Dead = $dead }
}

function Show-PlansPreview($Pairs) {
    $grand = @{ Add = 0; Upd = 0; Conf = 0 }
    foreach ($pair in $Pairs) {
        $plan = $pair.Plan
        Write-Host "`n== 同步預覽 -> $($pair.Dst) ==" -ForegroundColor Yellow
        Write-Host ("A：{0}" -f $plan.Entries[0].Src)
        Write-Host ("B：{0}" -f $plan.Entries[0].Dst)
        foreach ($e in $plan.Entries) {
            Write-Host ("  [{0}] 新增 {1}、更新 {2}、衝突略過 {3}" -f $e.Label, $e.Add, $e.Update, @($e.Conflicts).Count)
            foreach ($c in @($e.Conflicts) | Select-Object -First 5) {
                Write-Host ("      衝突略過：{0}（{1}）" -f $c.To, $c.Reason) -ForegroundColor DarkYellow
            }
        }
        foreach ($s in $plan.Skipped) {
            Write-Host ("  跳過 Submodule：{0}（{1}）" -f $s.Path, $s.Reason) -ForegroundColor DarkYellow
        }
        Write-Host ("小計：新增 {0}、更新 {1}、衝突略過 {2}" -f $plan.TotalAdd, $plan.TotalUpdate, $plan.TotalConflict)
        $grand.Add += [int]$plan.TotalAdd; $grand.Upd += [int]$plan.TotalUpdate; $grand.Conf += [int]$plan.TotalConflict
    }
    Write-Host ("`n合計（{0} 個目的 Repo）：新增 {1}、更新 {2}、衝突略過 {3}" -f $Pairs.Count, $grand.Add, $grand.Upd, $grand.Conf) -ForegroundColor Cyan
    return $grand
}

function Run-SyncLocalRefs {
    Write-Host "`n=== A -> 多個目的 Repo 本地 Ref 同步（含可選 Submodule） ===" -ForegroundColor Yellow
    $src = Choose-Repo '選擇來源 Repo A（將從這裡讀取 Ref）'
    $dsts = @(Choose-Repo '選擇目的 Repo B（將更新這裡的 Ref）')
    $dsts += Ask-ExtraDst
    $includeOrigin = Confirm-Yes '同步 refs/remotes/origin/* 嗎？'
    $includeHeads  = Confirm-Yes '備份 A 的本地 Branch 到目的端的 refs/sync/source-heads/* 嗎？'
    $recurse = Confirm-Yes '也同步所有已初始化的 Submodule（包含巢狀）嗎？'
    $built = Build-SyncPairs $src $dsts @{ IncludeOrigin = $includeOrigin; IncludeHeads = $includeHeads; Recurse = $recurse }
    $pairs = $built.Pairs; $dead = $built.Dead
    if ($pairs.Count -eq 0) { Write-Warning '沒有可用的目的 Repo。'; return }
    $mismatch = @($pairs | Where-Object { $_.Plan.OriginMismatch })
    if ($mismatch.Count -gt 0) {
        foreach ($mp in $mismatch) {
            Write-Warning ("[B -> {0}] 兩邊 origin URL 不同：`n  A: {1}`n  B: {2}" -f $mp.Dst, $mp.Plan.OriginA, $mp.Plan.OriginB)
        }
        Write-Host '複製 origin/* 可能造成誤認遠端狀態。'
        if (-not (Confirm-Yes '確定上述目的端與 A 是同一個 Git Repository，仍要繼續嗎？')) { return }
    }
    $grand = Show-PlansPreview $pairs
    if ($grand.Add + $grand.Upd -eq 0) { Write-Host '全部已一致，不需更新。'; return }
    if (-not (Confirm-Yes "確定對 $($pairs.Count) 個目的 Repo 執行全部 $($grand.Add + $grand.Upd) 筆 Ref 更新嗎？")) {
        Write-Host '已取消。'
        return
    }
    $applied = 0; $failedAll = @()
    foreach ($pair in $pairs) {
        foreach ($e in $pair.Plan.Entries) {
            if (@($e.UpdateList).Count -eq 0) { Write-Host "[B -> $($pair.Dst)] [$($e.Label)] 已一致。" -ForegroundColor Green; continue }
            $res = Invoke-RefPairSync -Src $e.Src -Dst $e.Dst -Updates $e.UpdateList -OnLog { param($m) Write-Host $m }
            $applied += $res.Applied
            $failedAll += @($res.Failed)
            Write-Host ("[B -> {0}] [{1}] 完成 {2} 筆，失敗 {3} 筆。" -f $pair.Dst, $e.Label, $res.Applied, @($res.Failed).Count) -ForegroundColor Green
        }
    }
    Write-Host ("`n本地同步作業結束：套用 {0} 筆、失敗 {1} 筆" -f $applied, $failedAll.Count) -ForegroundColor Green
    if ($dead.Count -gt 0) { Write-Warning "有 $($dead.Count) 個目的 Repo 未處理（見上方警告）。" }
    Write-Host '僅同步 Ref 與必要 Commit 物件，不更新 Submodule Checkout 版本。' -ForegroundColor Green
}

function Run-AutoSync($srcArg, $dstArgList, $assumeYes) {
    Write-Host "`n=== Auto：A -> 一個或多個目的 Repo 同步 origin/* + 所有 Submodule ===" -ForegroundColor Yellow
    $src = if ($srcArg) { Get-GitRoot $srcArg } else { Choose-Repo '選擇來源 Repo A' }
    $dsts = @()
    foreach ($d in @($dstArgList)) {
        if ($d) { $dsts += (Get-GitRoot $d) }
    }
    if ($dsts.Count -eq 0) {
        $dsts += (Choose-Repo '選擇目的 Repo B（第 1 個）')
        $dsts += Ask-ExtraDst
    }
    $built = Build-SyncPairs $src $dsts @{ IncludeOrigin = $true; IncludeHeads = [bool]$BackupHeads; Recurse = $true }
    $pairs = $built.Pairs; $dead = $built.Dead
    if ($pairs.Count -eq 0) { throw '沒有可用的目的 Repo。' }
    $mismatch = @($pairs | Where-Object { $_.Plan.OriginMismatch })
    if ($mismatch.Count -gt 0) {
        if ($assumeYes) {
            throw ("有 {0} 個目的 Repo 的 origin URL 與 A 不同（例如 {1}），Auto+Yes 模式中止，避免誤同步。" -f $mismatch.Count, $mismatch[0].Dst)
        }
        foreach ($mp in $mismatch) {
            Write-Warning ("[B -> {0}] 兩邊 origin URL 不同：`n  A: {1}`n  B: {2}" -f $mp.Dst, $mp.Plan.OriginA, $mp.Plan.OriginB)
        }
        if (-not (Confirm-Yes '確定上述目的端與 A 是同一個 Repo，仍要繼續嗎？')) { return 0 }
    }
    $grand = Show-PlansPreview $pairs
    if (-not $assumeYes -and -not (Confirm-Yes "確定對 $($pairs.Count) 個目的 Repo 執行全部 $($grand.Add + $grand.Upd) 筆更新嗎？")) {
        Write-Host '已取消。'
        return 0
    }
    $applied = 0; $failedAll = @()
    $confAll = 0; $skipAll = 0
    foreach ($pair in $pairs) {
        $confAll += [int]$pair.Plan.TotalConflict
        $skipAll += @($pair.Plan.Skipped).Count
        foreach ($e in $pair.Plan.Entries) {
            if (@($e.UpdateList).Count -eq 0) { Write-Host "[B -> $($pair.Dst)] [$($e.Label)] 已一致。" -ForegroundColor Green; continue }
            $res = Invoke-RefPairSync -Src $e.Src -Dst $e.Dst -Updates $e.UpdateList -OnLog { param($m) Write-Host $m }
            $applied += $res.Applied
            $failedAll += @($res.Failed)
            Write-Host ("[B -> {0}] [{1}] 完成 {2} 筆。" -f $pair.Dst, $e.Label, $res.Applied) -ForegroundColor Green
        }
    }
    Write-Host ("`nAuto 同步完成：套用 {0} 筆、衝突略過 {1} 筆、跳過 Submodule {2} 個、失敗 {3} 筆。" -f $applied, $confAll, $skipAll, $failedAll.Count) -ForegroundColor Green
    if ($dead.Count -gt 0) { Write-Warning "有 $($dead.Count) 個目的 Repo 未處理（見上方警告）。" }
    if ($failedAll.Count -gt 0) { return 1 }
    if ($confAll -gt 0 -or $skipAll -gt 0 -or $dead.Count -gt 0) { return 2 }
    return 0
}

function Run-FetchOrigins {
    Write-Host "`n=== 兩份 Clone 各自 Fetch origin（含可選 Submodule） ===" -ForegroundColor Yellow
    $repoA = Choose-Repo '選擇 Repo A'
    $repoB = Choose-Repo '選擇 Repo B'
    if ((Get-CommonDir $repoA) -eq (Get-CommonDir $repoB)) {
        Write-Host '兩邊共用 Git Repository，只需 Fetch 主 Repo。'
        $repoB = $null
    }
    $urlA = Get-OriginUrl $repoA
    if (-not $urlA) { throw 'Repo A 沒有名為 origin 的 Remote。' }
    Write-Host "Repo A origin：$urlA"
    if ($repoB) {
        $urlB = Get-OriginUrl $repoB
        if (-not $urlB) { throw 'Repo B 沒有名為 origin 的 Remote。' }
        Write-Host "Repo B origin：$urlB"
        if ($urlA -ne $urlB) {
            Write-Warning '兩邊 origin URL 不完全相同，Fetch 後不能保證 origin/* 相同。'
            if (-not (Confirm-Yes '仍要各自 Fetch 嗎？')) { return }
        }
    }
    $prune = Confirm-Yes '加上 --prune 清理遠端已刪除的追蹤 Ref 嗎？'
    $recurse = Confirm-Yes '也逐一 Fetch 已初始化的所有 Submodule（包含巢狀）嗎？'
    if (-not (Confirm-Yes '確定開始連線至 Origin 進行 Fetch 嗎？')) { return }
    $repos = @($repoA)
    if ($repoB) { $repos += $repoB }
    foreach ($r in $repos) {
        foreach ($t in @(Get-FetchTargets $r $recurse)) {
            if (-not (Get-OriginUrl $t.Path)) {
                Write-Warning "[$($t.Label)] 沒有 origin，已略過：$($t.Path)"
                continue
            }
            Write-Host "`n[$($t.Label)] Fetch：$($t.Path)" -ForegroundColor Cyan
            $ga = @('fetch','--no-recurse-submodules')
            if ($prune) { $ga += '--prune' }
            $ga += 'origin'
            $r2 = Invoke-Git -Repo $t.Path -GitArgs $ga -AllowFail
            if ($r2.Code -ne 0) { throw "Fetch 失敗：$($t.Path)（exit $($r2.Code)）。請檢查網路或權限。" }
        }
    }
    Write-Host "`n完成：已更新主 Repo 與所選已初始化 Submodule 的遠端追蹤 Ref。" -ForegroundColor Green
}

function Run-Worktree {
    Write-Host "`n=== 新增 Git Worktree（共享 refs/heads、refs/remotes/origin） ===" -ForegroundColor Yellow
    $source = Choose-Repo '選擇現有 Repo（共用 Git 的來源）'
    Write-Host "`n選擇新 Worktree 的「上層資料夾」（將在裡面新建一個資料夾）。"
    $parent = Select-Folder '選擇 Worktree 的上層資料夾'
    $folderName = Read-Host "新資料夾名稱（預設：(來源名稱)-worktree）"
    $branch = Read-Host '新 Branch 名稱（例如 feature/task-001）'
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Branch 名稱不可為空。' }
    $startingPoint = Read-Host '起始 Commit / Ref（預設：HEAD）'
    if ([string]::IsNullOrWhiteSpace($startingPoint)) { $startingPoint = 'HEAD' }
    $chk = Test-WorktreeRequest -Source $source -Parent $parent -FolderName $folderName -Branch $branch -StartingPoint $startingPoint
    foreach ($it in $chk.Items) {
        if ($it.Ok) { Write-Host ("  [OK] {0}：{1}" -f $it.Check, $it.Msg) -ForegroundColor Green }
        else { Write-Host ("  [X]  {0}：{1}" -f $it.Check, $it.Msg) -ForegroundColor Red }
    }
    foreach ($w in $chk.Warnings) { Write-Warning $w }
    if (-not $chk.AllOk) { Write-Warning '有檢查項目未通過，已中止。' ; return }
    if (-not (Confirm-Yes "確定在 $($chk.Target) 建立 Worktree（Branch：$branch）嗎？")) { return }
    $r = Invoke-Git -Repo $chk.Source -GitArgs @('worktree','add','-b',$branch,$chk.Target,$startingPoint) -AllowFail
    if ($r.Code -ne 0) { throw "建立 Worktree 失敗：$($r.Text)" }
    Write-Host "`nWorktree 建立成功：$($chk.Target)" -ForegroundColor Green
    Write-Host '所有 Worktree 共用 Ref（包含 refs/remotes/origin/*），不需要互相 Fetch。'
    Write-Host 'Worktree 列表：git worktree list'
}

# ---------------- 進入點 ----------------
if ($Version) {
    $ver = '0.0.0'
    try { $ver = ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tool.json')) | ConvertFrom-Json).version } catch { }
    Write-Output $ver
    exit 0
}
if ($Help) {
    Write-Output @'
Git Ref Manager CLI
  互動選單：      Git-Ref-Manager.ps1
  排程（非互動）：Git-Ref-Manager.ps1 -Auto -Yes -Src <A> -Dst <B> [-DstList "B1;B2"] [-BackupHeads]
  其他：          -Version、-Help
exit code：0 成功、1 失敗、2 成功但有略過項、3 參數不正確、5 找不到 git
'@
    exit 0
}
$dstsCmd = @()
if (-not [string]::IsNullOrWhiteSpace($Dst)) { $dstsCmd += $Dst.Trim() }
if (-not [string]::IsNullOrWhiteSpace($DstList)) { $dstsCmd += Split-DstArg $DstList }
# 去重（大小寫不敏感、忽略結尾分隔符）
$seenCmd = @{}; $dstsTmp = @()
foreach ($d in $dstsCmd) {
    $k = $d.ToLowerInvariant().TrimEnd('\')
    if ($seenCmd.ContainsKey($k)) { continue }
    $seenCmd[$k] = $true; $dstsTmp += $d
}
$dstsCmd = @($dstsTmp)
$interactive = -not ($Auto -and $Src -and $dstsCmd.Count -gt 0)
if ($Auto -and $Yes -and $interactive) {
    # -Auto -Yes 表示排程，不能退回互動選單（會卡在 Read-Host）
    Write-Host '錯誤：-Auto -Yes 需要同時指定 -Src 與 -Dst（或 -DstList）。' -ForegroundColor Red
    exit 3
}
$exitCode = 0
try {
    try { Assert-Git } catch {
        Write-Host "`n錯誤：$($_.Exception.Message)" -ForegroundColor Red
        exit 5   # 互動模式下 finally 仍會先暫停，讓使用者看到訊息
    }
    if (-not $interactive) {
        # 非互動排程模式
        $exitCode = Run-AutoSync $Src $dstsCmd $Yes.IsPresent
        exit $exitCode
    }
    Write-Host '===============================================' -ForegroundColor Cyan
    Write-Host '    Git Ref / Origin / Worktree 管理工具' -ForegroundColor Cyan
    Write-Host '===============================================' -ForegroundColor Cyan
    Write-Host '[1] 本機 A -> 多個目的 Repo 同步 Ref（可含遞迴 Submodule，離線）'
    Write-Host '[2] 兩份 Repo 各自 Fetch origin（可含遞迴 Submodule）'
    Write-Host '[3] 建立 Worktree，共用 origin/*（新資料夾）'
    Write-Host '[4] Auto：同步 origin/* + 所有 Submodule（可多個目的，彙總預覽，一次確認）'
    Write-Host '[0] 離開'
    $choice = Read-Host "`n請選擇 [0/1/2/3/4]"
    switch ($choice) {
        '1' { Run-SyncLocalRefs }
        '2' { Run-FetchOrigins }
        '3' { Run-Worktree }
        '4' { [void](Run-AutoSync $null $null $false) }
        '0' { Write-Host '已結束。' }
        default { Write-Warning '無效選項。' }
    }
}
catch {
    Write-Host "`n錯誤：$($_.Exception.Message)" -ForegroundColor Red
    if (-not $interactive) { exit 1 }
}
finally {
    if ($interactive) { Pause-End }
}
if (-not $interactive) { exit $exitCode }
