# Git Ref Manager - 本機 Web 控制台
# 純 PowerShell（HttpListener／http.sys），不需要管理者權限。
# 只綁 127.0.0.1；不push、不刪 ref；Submodule 僅依請求從本機來源初始化。
# 用法： .\Git-Ref-Manager-Web.ps1 [-Port 8756] [-OpenBrowser] [-ParentPid <pid>] [-DataDir <路徑>] [-HubOrigin <url>]
#   -Port       指定 port；沒指定時從 8756 往上找（最多 +20），都不行就請系統配一個空的 port
#   -HubOrigin  Hub 的實際網址（例如 http://127.0.0.1:8700），允許它嵌入本頁
#   -ParentPid  父行程（例如 Dev-Toolbox Hub）結束時自動關閉
#   -DataDir    覆寫資料夾（預設 %LOCALAPPDATA%\DevToolbox\git-ref-manager）
# 啟動成功時 stdout 會印出一行：READY http://127.0.0.1:<port>（之前可能有其他訊息，Hub 只認 READY 開頭的行）
# 子行程模式（主程序自動派用，不啟監聽）：
#   -ValidateOnce -InFile <req.json> -OutFile <res.json>   跑一次 Repo 驗證
#   -SubInitOnce  -InFile <req.json> -OutFile <res.json>   跑一次 Submodule 從 A 初始化

param(
    [int]$Port = 8756,
    [switch]$OpenBrowser,
    [int]$ParentPid = 0,
    [string]$DataDir,
    [string]$HubOrigin,
    [switch]$ValidateOnce,
    [switch]$SubInitOnce,
    [string]$InFile,
    [string]$OutFile
)
$script:PortExplicit = $PSBoundParameters.ContainsKey('Port')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GitRefCore.ps1')
Assert-Git

# ---------------- 驗證／初始化結果（路由與子行程共用，僅依賴 GitRefCore） ----------------

function Get-ValidateResult([pscustomobject]$b, [scriptblock]$Fetcher) {
    # Fetcher 可注入摘要來源（主迴圈快取命中路徑）；預設即時掃描（子行程模式）
    if (-not $Fetcher) { $Fetcher = { param($p) Get-RepoSummary ([string]$p) } }
    $s = & $Fetcher ([string]$b.src)
    $errs = @()
    if (-not $s.ok) { $errs += "A：$($s.error)" }
    # 目的 Repo：dstList（陣列，可多個）或 dst（單一個，相容舊前端）
    $dstArr = @()
    if ($b.PSObject.Properties.Name -contains 'dstList') { $dstArr = @($b.dstList | ForEach-Object { [string]$_ }) }
    elseif (-not [string]::IsNullOrWhiteSpace($b.dst)) { $dstArr = @([string]$b.dst) }
    $dstResults = @()
    foreach ($dd in $dstArr) {
        if ([string]::IsNullOrWhiteSpace($dd)) { continue }
        $d = & $Fetcher $dd
        if (-not $d.ok) { $errs += "B（$dd）：$($d.error)" }
        $same = $null; $match = $null
        if ($s.ok -and $d.ok) {
            try {
                # 摘要已帶 commonDir（快取路徑免再跑 git）；舊形狀退回即時查詢
                $ca = if ($s.PSObject.Properties['commonDir'] -and [string]$s.commonDir) { [string]$s.commonDir } else { [string](Get-CommonDir $s.path) }
                $cb = if ($d.PSObject.Properties['commonDir'] -and [string]$d.commonDir) { [string]$d.commonDir } else { [string](Get-CommonDir $d.path) }
                $same = ($ca -eq $cb)
            } catch { $errs += "CommonDir 檢查失敗（$dd）：$($_.Exception.Message)" }
            $match = ($s.origin -eq $d.origin)
        }
        $dstResults += [pscustomobject]@{ summary = $d; sameCommonDir = $same; originMatch = $match }
    }
    $first = $null
    if ($dstResults.Count -gt 0) { $first = $dstResults[0] }
    return [pscustomobject]@{
        src = $s
        dsts = $dstResults
        dst = $(if ($first) { $first.summary } else { $null })
        sameCommonDir = $(if ($first) { $first.sameCommonDir } else { $null })
        originMatch = $(if ($first) { $first.originMatch } else { $null })
        errors = $errs
    }
}

function Resolve-SubmoduleEntry {
    # 在多層 .gitmodules 中找相對路徑（slash 分隔，自 Super 起算）的 submodule 註冊名稱。
    # 注意：path 本身可含斜線（如 Features/FeaturesPkg），故先以整段路徑比對，
    # 找不到才把已註冊的 path 當作外層 superproject 遞迴往下找（外層須已初始化）。
    param([string]$Super, [string]$RelN)
    $gm = Join-Path $Super '.gitmodules'
    if (-not (Test-Path -LiteralPath $gm)) { return $null }
    $cfg = Invoke-Git -Repo $Super -GitArgs @('config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.path$') -AllowFail
    if ($cfg.Code -ne 0) { return $null }
    $entries = @()
    foreach ($line in @($cfg.Lines)) {
        $v = ([string]$line).Trim()
        if ($v -notmatch '^submodule\.(.+)\.path\s+(.*)$') { continue }
        $entries += [pscustomobject]@{ Name = $matches[1]; Path = ([string]$matches[2]).Trim().Replace('\', '/') }
    }
    foreach ($e in $entries) {
        if ($e.Path -ieq $RelN) { return [pscustomobject]@{ Name = $e.Name; Super = $Super } }
    }
    foreach ($e in $entries) {
        if (-not $RelN.StartsWith($e.Path + '/', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $sub = Join-Path $Super ($e.Path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $sub -PathType Container)) { continue }   # 外層未初始化：無法再往下找
        $r = Resolve-SubmoduleEntry -Super $sub -RelN $RelN.Substring($e.Path.Length + 1)
        if ($r) { return $r }
    }
    return $null
}

function Get-SubInitResult([pscustomobject]$b) {
    # 於 B 以「-c 覆寫該 submodule URL 為 A 本地路徑」跑 update --init：本地複製、不需要網路。
    # 僅處理被點擊的這一顆（不含其巢狀層）；巢狀層初始化後重新驗證，清單會再列出可處理。
    try {
        $src = ([string]$b.src).Trim(); $dst = ([string]$b.dst).Trim(); $rel = ([string]$b.path).Trim()
        if (-not $src -or -not $dst -or -not $rel) { return [pscustomobject]@{ ok = $false; message = '缺少 src / dst / path' } }
        $relN = ($rel -replace '\\', '/').Trim('/')
        if ($relN -match '(^|/)\.\.(/|$)' -or $relN -match '[a-zA-Z]:') { return [pscustomobject]@{ ok = $false; message = "路徑不合法：$rel" } }
        $env:GIT_TERMINAL_PROMPT = '0'   # 任何情況下都不等待憑證輸入
        $rootA = $null; $rootB = $null
        try { $rootA = Get-GitRoot $src } catch { return [pscustomobject]@{ ok = $false; message = "A：$($_.Exception.Message)" } }
        try { $rootB = Get-GitRoot $dst } catch { return [pscustomobject]@{ ok = $false; message = "B：$($_.Exception.Message)" } }
        $entry = Resolve-SubmoduleEntry -Super $rootB -RelN $relN
        if (-not $entry) {
            return [pscustomobject]@{ ok = $false; message = "B 的 Submodule 註冊中找不到 $rel（若為巢狀層，請先初始化外層再重新驗證）" }
        }
        if ($entry.Super -ine $rootB) {
            # 巢狀層：update/config/status 都必須在直接所屬 superproject 執行，
            # 在 root 層跑會靜默不做事造成假成功。請使用者逐層初始化。
            return [pscustomobject]@{ ok = $false; message = "$rel 是巢狀 Submodule，請先初始化外層（$((Split-Path $entry.Super -Leaf))）後重新驗證，再逐顆處理" }
        }
        # 確認 B 目前未初始化（畫面顯示到點擊之間狀態可能已變）
        $stB = Invoke-Git -Repo $rootB -GitArgs @('submodule', 'status', '--recursive') -AllowFail
        $flagB = $null
        foreach ($line in @($stB.Lines)) {
            $v = [string]$line
            if ($v -notmatch '^([ +\-U])[0-9a-fA-F]{40,64}\s+(.+)$') { continue }
            $fl = $matches[1]
            $p = (($matches[2] -replace '\s+\([^)]*\)$', '')).Replace('\', '/')
            if ($p -ieq $relN) { $flagB = $fl; break }
        }
        if ($null -eq $flagB) { return [pscustomobject]@{ ok = $false; message = "B 的 Submodule 狀態沒有 $rel，請重新驗證" } }
        if ($flagB -ne '-') { return [pscustomobject]@{ ok = $false; message = "B 側 $rel 已是初始化狀態，請重新驗證" } }
        # A 必須已初始化，才有內容可複製（@() 要包住整條管線，否則無相符時得到 $null）
        $inA = @(Get-InitializedSubmodulePaths $rootA | Where-Object { $_.Replace('\', '/') -ieq $relN })
        if ($inA.Count -eq 0) { return [pscustomobject]@{ ok = $false; message = "A 側 $rel 也未初始化，無法作為初始化來源" } }
        $urlSrc = ((Join-Path $rootA ($relN.Replace('/', '\'))) -replace '\\', '/') -replace '/+$', ''
        $r = Invoke-Git -Repo $rootB -GitArgs @(
            '-c', 'protocol.file.allow=always',
            '-c', "submodule.$($entry.Name).url=$urlSrc",
            'submodule', 'update', '--init', '--', $relN
        ) -AllowFail
        $tail = (@($r.Lines) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 6) -join ' | '
        if ($r.Code -ne 0) { return [pscustomobject]@{ ok = $false; message = "git submodule update --init 失敗（exit $($r.Code)）：$tail" } }
        # -c 覆寫的 URL 不會寫入 .git/config（init 只把 .gitmodules 的 URL 持久化），
        # 未持久化時 submodule status 仍顯示 '-'（未初始化）。手動寫入 A 的本機 URL 完成註冊，
        # 順帶讓 s1 的 origin 指向 A（與提示訊息一致，使用者可自行改回）。
        $r2 = Invoke-Git -Repo $rootB -GitArgs @('config', "submodule.$($entry.Name).url", $urlSrc) -AllowFail
        if ($r2.Code -ne 0) {
            return [pscustomobject]@{ ok = $false; message = "已複製內容，但註冊 URL 寫入失敗（exit $($r2.Code)），請手動執行 git submodule init" }
        }
        # 最終確認：該 path 的狀態旗標不應再是 '-'
        $st2 = Invoke-Git -Repo $rootB -GitArgs @('submodule', 'status', '--', $relN) -AllowFail
        foreach ($line in @($st2.Lines)) {
            if ([string]$line -match '^-\s*[0-9a-fA-F]{40,64}') {
                return [pscustomobject]@{ ok = $false; message = "初始化後 $relN 仍偵測為未初始化，請重新驗證或手動檢查" }
            }
        }
        return [pscustomobject]@{ ok = $true; message = "已在 B 從 A 初始化 $relN（此 Submodule 的 origin 目前指向 A 的本機路徑，需要時可自行改回）" }
    } catch {
        return [pscustomobject]@{ ok = $false; message = "初始化異常：$($_.Exception.Message)" }
    }
}

# ---- 子行程模式：跑一次、結果寫檔後結束（驗證與初始化都是短命行程，不占主迴圈） ----
if ($ValidateOnce -or $SubInitOnce) {
    $result = $null
    try {
        $in = if ($InFile -and (Test-Path -LiteralPath $InFile)) { [System.IO.File]::ReadAllText($InFile) } else { '{}' }
        $body = ConvertFrom-Json $in
        $result = if ($ValidateOnce) { Get-ValidateResult $body } else { Get-SubInitResult $body }
    } catch {
        $result = [pscustomobject]@{ ok = $false; message = "子行程錯誤：$($_.Exception.Message)" }
    }
    try {
        [System.IO.File]::WriteAllText($OutFile, (ConvertTo-Json $result -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { exit 1 }
    exit 0
}

# ---------------- 工具資訊與資料夾（Dev-Toolbox 規格 specVersion 1） ----------------
$script:ToolInfo = $null
try {
    $script:ToolInfo = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tool.json')) | ConvertFrom-Json
} catch {
    $script:ToolInfo = [pscustomobject]@{ id = 'git-ref-manager'; name = 'Git Ref Manager'; version = '0.0.0' }
}
$script:StartedAt = Get-Date
# Hub（Dev-Toolbox）的位址：允許它嵌入本頁、也允許它送出的 Origin。
$script:HubPort = 8700
if ($env:DEVTOOLBOX_HUB_PORT -match '^\d{2,5}$') { $script:HubPort = [int]$env:DEVTOOLBOX_HUB_PORT }
if ($HubOrigin -match '^http://(127\.0\.0\.1|localhost):(\d{1,5})$') { $script:HubPort = [int]$matches[2] }
$script:HubOrigins = @("http://127.0.0.1:$($script:HubPort)", "http://localhost:$($script:HubPort)")
$script:MaxBodyChars = 1MB

function Resolve-DataDir([string]$Override) {
    # 優先順序：-DataDir > $env:DEVTOOLBOX_DATA\<id> > %LOCALAPPDATA%\DevToolbox\<id>
    $id = [string]$script:ToolInfo.id
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return [System.IO.Path]::GetFullPath($Override) }
    if (-not [string]::IsNullOrWhiteSpace($env:DEVTOOLBOX_DATA)) { return (Join-Path $env:DEVTOOLBOX_DATA $id) }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    return (Join-Path (Join-Path $base 'DevToolbox') $id)
}

function Copy-LegacyData([string]$Target) {
    # 舊版把 profiles\ 與 job-history.jsonl 放在工具資料夾。第一次啟動時複製到新位置（不刪舊檔）。
    $oldProfiles = Join-Path $PSScriptRoot 'profiles'
    $newProfiles = Join-Path $Target 'profiles'
    if ((Test-Path -LiteralPath $oldProfiles -PathType Container) -and -not (Test-Path -LiteralPath $newProfiles)) {
        Copy-Item -LiteralPath $oldProfiles -Destination $newProfiles -Recurse
        Write-Host "已把舊的設定檔複製到 $newProfiles（原檔保留，確認無誤後可自行刪除）" -ForegroundColor Gray
    }
    $oldHistory = Join-Path $PSScriptRoot 'job-history.jsonl'
    $newHistory = Join-Path $Target 'history.jsonl'
    if ((Test-Path -LiteralPath $oldHistory -PathType Leaf) -and -not (Test-Path -LiteralPath $newHistory)) {
        Copy-Item -LiteralPath $oldHistory -Destination $newHistory
        Write-Host "已把舊的工作紀錄複製到 $newHistory（原檔保留）" -ForegroundColor Gray
    }
}

$script:DataDir = Resolve-DataDir $DataDir
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
try { Copy-LegacyData $script:DataDir } catch { Write-Warning "舊資料複製失敗：$($_.Exception.Message)" }

$script:Jobs = @{}
$script:NextJobId = 1
$script:Previews = @{}
$script:Job = $null

# Job 歷史落盤：每筆工作結束時附加寫入 jsonl，重啟服務後仍可追溯
$script:HistoryFile = Join-Path $script:DataDir 'history.jsonl'
$script:HistoryMax = 100
$script:History = New-Object 'System.Collections.Generic.List[object]'

function New-ManagerJob([string]$Kind) {
    $j = [pscustomobject]@{
        Id = $script:NextJobId
        Kind = $Kind
        State = 'Running'
        Steps = New-Object System.Collections.Queue
        Lines = New-Object 'System.Collections.Generic.List[string]'
        Done = 0
        Total = 0
        Result = $null
        Error = $null
        FailedList = New-Object 'System.Collections.Generic.List[string]'
        Applied = 0
        StartedAt = (Get-Date).ToString('HH:mm:ss')
        StartedAtFull = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Meta = $null
        Saved = $false
    }
    $script:NextJobId++
    $script:Jobs[[int]$j.Id] = $j
    $script:Job = $j
    return $j
}

function Job-Log($j, [string]$Msg) {
    if ([string]::IsNullOrWhiteSpace($Msg)) { return }
    $t = (Get-Date).ToString('HH:mm:ss')
    foreach ($one in (@($Msg) | ForEach-Object { [string]$_ })) {
        if (-not [string]::IsNullOrWhiteSpace($one)) { $j.Lines.Add("[$t] $one") }
    }
    if ($j.Lines.Count -gt 8000) { $j.Lines.RemoveRange(0, ($j.Lines.Count - 6000)) }
}

function Invoke-JobStep($j) {
    $step = $j.Steps.Dequeue()
    try {
        & $step $j
    } catch {
        $j.State = 'Failed'
        $j.Error = $_.Exception.Message
        Job-Log $j "錯誤：$($_.Exception.Message)"
        foreach ($stLine in (($_.ScriptStackTrace -split "`n") | Select-Object -First 6)) { Job-Log $j "  at $stLine" }
    }
    if ($j.State -eq 'Running' -and $j.Steps.Count -eq 0) { $j.State = 'Done' }
    if ($j.State -ne 'Running' -and -not $j.Saved) {
        $j.Saved = $true
        Save-JobHistory $j
    }
}

function Get-ActiveJob {
    if ($script:Job -and $script:Job.State -eq 'Running') { return $script:Job }
    return $null
}

# ---- Job 歷史：落盤、載入 ----

function Save-JobHistory($j) {
    try {
        $logArr = @($j.Lines)
        if ($logArr.Count -gt 4000) { $logArr = $logArr[($logArr.Count - 4000)..($logArr.Count - 1)] }
        $rec = [ordered]@{
            id        = [int]$j.Id
            kind      = [string]$j.Kind
            state     = [string]$j.State
            startedAt = [string]$j.StartedAtFull
            endedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            meta      = $j.Meta
            result    = $j.Result
            error     = $j.Error
            log       = $logArr
        }
        $json = ConvertTo-Json -InputObject $rec -Depth 8 -Compress
        [System.IO.File]::AppendAllText($script:HistoryFile, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $script:History.Add($rec) | Out-Null
        if ($script:History.Count -gt $script:HistoryMax) {
            # 超過上限：整檔重寫（暫存檔 + 原子改名），只留最近 N 筆
            $script:History.RemoveRange(0, $script:History.Count - $script:HistoryMax)
            $tmp = "$script:HistoryFile.tmp"
            $all = foreach ($h in $script:History) { ConvertTo-Json -InputObject $h -Depth 8 -Compress }
            [System.IO.File]::WriteAllLines($tmp, [string[]]$all, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $script:HistoryFile -Force
        }
    } catch {
        Write-Warning "Job 歷史寫入失敗：$($_.Exception.Message)"
    }
}

function Read-JobHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryFile)) { return }
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($script:HistoryFile) }
    catch { Write-Warning "Job 歷史載入失敗：$($_.Exception.Message)"; return }
    $bad = 0
    foreach ($ln in $lines) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        # 單行損毀（壞 JSON、壞 id）只跳過該行，不影響其餘紀錄
        try {
            $o = ConvertFrom-Json -InputObject $ln
            if (-not $o) { continue }
            $id = 0
            if (-not [int]::TryParse([string]$o.id, [ref]$id)) { continue }
            $script:History.Add($o) | Out-Null
            # 重建唯讀 Job 物件，讓 /api/jobs/{id} 對歷史 id 也可用
            $j = [pscustomobject]@{
                Id = $id
                Kind = [string]$o.kind
                State = [string]$o.state
                Steps = New-Object System.Collections.Queue
                Lines = New-Object 'System.Collections.Generic.List[string]'
                Done = 0
                Total = 0
                Result = $o.result
                Error = [string]$o.error
                FailedList = New-Object 'System.Collections.Generic.List[string]'
                Applied = 0
                StartedAt = [string]$o.startedAt
                StartedAtFull = [string]$o.startedAt
                Meta = $o.meta
                Saved = $true
            }
            if ($o.log) { foreach ($l in @($o.log)) { if ($l) { $j.Lines.Add([string]$l) | Out-Null } } }
            $script:Jobs[$id] = $j
            if ($id -ge $script:NextJobId) { $script:NextJobId = $id + 1 }
        } catch { $bad++; continue }
    }
    if ($bad -gt 0) { Write-Warning "Job 歷史有 $bad 行格式異常已略過。" }
}

function Get-HistorySummary($rec) {
    $res = $rec.result
    $failedCount = 0
    if ($null -ne $res.failed) { $failedCount = @($res.failed).Count }
    $skippedCount = 0
    if ($null -ne $res.skippedSubmodules) { $skippedCount = @($res.skippedSubmodules).Count }
    $createdCount = 0
    if ($null -ne $res.created) { $createdCount = @($res.created).Count }
    [ordered]@{
        id             = $rec.id
        kind           = [string]$rec.kind
        state          = [string]$rec.state
        startedAt      = [string]$rec.startedAt
        endedAt        = [string]$rec.endedAt
        error          = [string]$rec.error
        meta           = $rec.meta
        applied        = $res.applied
        failedCount    = $failedCount
        conflictSkipped = $res.conflictSkipped
        skippedCount   = $skippedCount
        targets        = $res.targets
        created        = $createdCount
        target         = $res.target
        branch         = $res.branch
        totalAdd       = $res.totalAdd
        totalUpdate    = $res.totalUpdate
        totalConflict  = $res.totalConflict
    }
}

function Set-Preview([int]$Id, $Plan) {
    # 閉包內 $script: 會指向閉包模組作用域，必須經由此函式存取。
    $script:Previews[$Id] = $Plan
}

# ---------------- HTTP 基礎 ----------------

function Read-ClientRequest($hctx) {
    # HttpListener（Windows 內建 http.sys）已處理好連線；這裡只轉成路由使用的格式。
    # 不自己開 socket：有些電腦的端點防護會切斷 powershell.exe 自己開的連線（ERR_CONNECTION_RESET）。
    $r = $hctx.Request
    $headers = @{}
    foreach ($k in @($r.Headers.AllKeys)) { if ($k) { $headers[$k.ToLowerInvariant()] = [string]$r.Headers[$k] } }
    $body = ''
    if ($r.HasEntityBody) {
        $sr = New-Object System.IO.StreamReader($r.InputStream, [System.Text.Encoding]::UTF8)
        $buf = New-Object char[] 65536
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $n = $sr.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$sb.Append($buf, 0, $n)
            if ($sb.Length -gt $script:MaxBodyChars) { break }   # 超過上限：Test-RequestAllowed 會回 413
        }
        $sr.Dispose()
        $body = $sb.ToString()
    }
    [pscustomobject]@{ Method = [string]$r.HttpMethod; RawUrl = [string]$r.RawUrl; Headers = $headers; Body = $body }
}

function Send-Response($hctx, [int]$code, [string]$contentType, [byte[]]$bodyBytes) {
    if (-not $bodyBytes) { $bodyBytes = [byte[]]@() }
    # 安全標頭（TOOL-SPEC 第 5 節）：禁止 MIME 猜測、只允許自己與 Hub 嵌入、不送 Referer
    $csp = "frame-ancestors 'self' $($script:HubOrigins -join ' ')"
    $resp = $hctx.Response
    try {
        $resp.StatusCode = $code
        $resp.ContentType = $contentType
        $resp.KeepAlive = $false
        $resp.Headers.Add('Cache-Control', 'no-store')
        $resp.Headers.Add('X-Content-Type-Options', 'nosniff')
        $resp.Headers.Add('Content-Security-Policy', $csp)
        $resp.Headers.Add('Referrer-Policy', 'no-referrer')
        $resp.ContentLength64 = $bodyBytes.Length
        if ($bodyBytes.Length -gt 0) { $resp.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) }
    } finally {
        try { $resp.OutputStream.Close() } catch { }
        try { $resp.Close() } catch { }
    }
}

function Send-Text($ctx, [int]$code, [string]$text) {
    $ctx.Code = $code
    $ctx.Type = 'text/plain; charset=utf-8'
    $ctx.Bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
}

function Send-JsonRaw($ctx, $obj, [int]$code = 200) {
    $ctx.Code = $code
    $ctx.Type = 'application/json; charset=utf-8'
    $ctx.Bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $obj -Depth 10 -Compress))
}

function Read-JsonBody($req) {
    if ([string]::IsNullOrWhiteSpace($req.Body)) { return [pscustomobject]@{} }
    try { return ConvertFrom-Json $req.Body } catch { throw "JSON 格式錯誤：$($_.Exception.Message)" }
}

# ---------------- 背景待辦請求（validate／subinit：子行程＋延遲回覆） ----------------
# 主程序只負責接收與派工：長 git 操作交給短命子行程，連線保持開啟；
# 主迴圈每輪 Poll 子行程，結束後才把結果寫回對應連線，其間照常接新請求。
$script:PendingOps = New-Object 'System.Collections.Generic.List[object]'
$script:OpTmpDir = Join-Path $env:TEMP 'git-ref-mgr'
$script:ValMaxParallel = 3        # 驗證子行程併行上限（超出的排隊）
$script:ValTimeoutSec = 120
$script:InitTimeoutSec = 1200     # Submodule 初始化從本機複製，大顆也綽綽有餘
$script:SummaryCache = New-SummaryCache 8   # 驗證摘要短效快取：重整瞬間的重複驗證直接回覆（UI Enter 繞過）
$script:RepoMutation = [datetime]::MinValue  # 最近一次 Repo 狀態變更（subinit 結案）：之前派出的驗證不回灌快取

function Seed-ValidateCache($op, [string]$Json) {
    # 子行程跑完的摘要餵回主迴圈快取：同波次其他輸入框／數秒內的同路徑驗證
    # 不再重複開子行程；失敗摘要（ok=false）不進快取。
    # 掃描派工早於最後一次 Repo 變更（subinit）→ 資料已過期，晚到也不准覆寫。
    if ($null -ne $op -and $op.Issued -lt $script:RepoMutation) { return }
    try { $r = $Json | ConvertFrom-Json } catch { return }
    if ($null -eq $r) { return }
    Set-CachedSummary $script:SummaryCache $r.src
    foreach ($d in @($r.dsts)) { if ($null -ne $d -and $null -ne $d.summary) { Set-CachedSummary $script:SummaryCache $d.summary } }
}

function Test-PendingSubInit {
    foreach ($op in $script:PendingOps) { if ($op.Kind -eq 'subinit') { return $true } }
    return $false
}

function Get-PendingValidateCount {
    $n = 0
    foreach ($op in $script:PendingOps) { if ($op.Kind -eq 'validate') { $n++ } }
    return $n
}

function Start-PendingOp([string]$Kind, $ctx, [string]$payload) {
    if (-not (Test-Path -LiteralPath $script:OpTmpDir)) { New-Item -ItemType Directory -Path $script:OpTmpDir | Out-Null }
    $gid = [guid]::NewGuid().ToString('N')
    $op = [pscustomobject]@{
        Kind     = $Kind
        Ctx      = $ctx
        ReqFile  = (Join-Path $script:OpTmpDir "$gid.in.json")
        OutFile  = (Join-Path $script:OpTmpDir "$gid.out.json")
        Proc     = $null
        Deadline = $null
        Issued   = (Get-Date)   # 派工時間：與 RepoMutation 比對，淘汰跨越狀態變更的過期 seed
    }
    [System.IO.File]::WriteAllText($op.ReqFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
    [void]$script:PendingOps.Add($op)
    $ctx.Deferred = $true   # 註冊成功後才標記：Handle-Client 不回覆、不關閉
}

function Start-PendingProc($op) {
    $mode = if ($op.Kind -eq 'validate') { '-ValidateOnce' } else { '-SubInitOnce' }
    $timeoutSec = if ($op.Kind -eq 'validate') { $script:ValTimeoutSec } else { $script:InitTimeoutSec }
    $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" $mode -InFile `"$($op.ReqFile)`" -OutFile `"$($op.OutFile)`""
    $op.Proc = Start-Process powershell.exe $argLine -WindowStyle Hidden -PassThru
    $op.Deadline = (Get-Date).AddSeconds($timeoutSec)
}

function Complete-PendingOp($op, [int]$code, [string]$json) {
    if ($op.Kind -eq 'subinit') {
        # subinit 會動到 B 的 Submodule 初始化態（失敗/逾時也可能已部分寫盤）：
        # 標記 Repo 變更並淘汰 B 的快取摘要，不依賴前端 force 重驗補破洞。
        $script:RepoMutation = Get-Date
        try {
            $rq = [System.IO.File]::ReadAllText($op.ReqFile) | ConvertFrom-Json
            if ($null -ne $rq -and -not [string]::IsNullOrWhiteSpace([string]$rq.dst)) {
                Remove-CachedSummary $script:SummaryCache ([string]$rq.dst)
            }
        } catch { }   # 請求檔讀不到就只記 mutation，不影響結案
    }
    [void]$script:PendingOps.Remove($op)
    try {
        $bytes = if ($json) { [System.Text.Encoding]::UTF8.GetBytes($json) } else { [byte[]]@() }
        Send-Response $op.Ctx.Http $code 'application/json; charset=utf-8' $bytes
    } catch { }   # 客戶端可能已離線（Send-Response 會自己關閉回應）
    foreach ($f in @($op.ReqFile, $op.OutFile)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-PendingOps {
    if ($script:PendingOps.Count -eq 0) { return }
    # 1) 有缺口的排隊項啟動（subinit 同時只會有一筆，由路由把關）
    $running = 0
    foreach ($op in $script:PendingOps) { if ($op.Kind -eq 'validate' -and $op.Proc) { $running++ } }
    foreach ($op in $script:PendingOps.ToArray()) {   # PS 5.1：@() 包 List 會拋 Argument types do not match，必須 ToArray()
        if ($op.Proc) { continue }
        try {
            if ($op.Kind -eq 'validate' -and $running -ge $script:ValMaxParallel) { continue }
            Start-PendingProc $op
            if ($op.Kind -eq 'validate') { $running++ }
        } catch {
            Complete-PendingOp $op 500 (ConvertTo-Json ([pscustomobject]@{ error = "無法啟動子行程：$($_.Exception.Message)" }) -Depth 5 -Compress)
        }
    }
    # 2) 已結束（或逾時）者寫回回覆
    foreach ($op in $script:PendingOps.ToArray()) {   # PS 5.1：@() 包 List 會拋 Argument types do not match，必須 ToArray()
        if (-not $op.Proc) { continue }   # 仍在排隊，或已於步驟 1 失敗結案
        $exited = $true
        try { $exited = $op.Proc.HasExited } catch { $exited = $true }
        if (-not $exited) {
            if ((Get-Date) -gt $op.Deadline) {
                try { $op.Proc.Kill(); [void]$op.Proc.WaitForExit(5000) } catch { }
                Complete-PendingOp $op 504 (ConvertTo-Json ([pscustomobject]@{ error = '操作逾時，已終止子行程' }) -Depth 5 -Compress)
            }
            continue
        }
        $json = $null
        try { if (Test-Path -LiteralPath $op.OutFile) { $json = [System.IO.File]::ReadAllText($op.OutFile) } } catch { $json = $null }
        if ($json) {
            if ($op.Kind -eq 'validate') { try { Seed-ValidateCache $op $json } catch { } }   # 餵主迴圈快取（失敗/解析不了靜略過，絕不拖垮主迴圈）
            Complete-PendingOp $op 200 $json
        }
        else { Complete-PendingOp $op 500 (ConvertTo-Json ([pscustomobject]@{ error = '操作未產生結果（子行程異常結束）' }) -Depth 5 -Compress) }
    }
}

# ---------------- 設定檔（profiles\<名稱>.json；_last.json＝上次設定） ----------------
$script:ProfileDir = Join-Path $script:DataDir 'profiles'
$script:ProfileLast = '_last'

function Test-ProfileName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 60) { return $false }
    if ($Name -match '[\\/:*?"<>|]' -or $Name.Contains('..')) { return $false }
    if ($Name.StartsWith('.') -or $Name.StartsWith('_')) { return $false }   # 底線與點開頭保留（_last 等）
    if ($Name -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') { return $false }   # Windows 保留裝置名
    return $true
}

function Get-ProfilePath([string]$Name) {
    if ($Name -eq $script:ProfileLast) { return Join-Path $script:ProfileDir '_last.json' }
    Join-Path $script:ProfileDir "$Name.json"
}

function Read-ProfileFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $txt = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    try { return ConvertFrom-Json $txt } catch { return $null }
}

function Write-ProfileFile([string]$Path, $Obj) {
    if (-not (Test-Path -LiteralPath $script:ProfileDir)) { New-Item -ItemType Directory -Path $script:ProfileDir | Out-Null }
    $json = ConvertTo-Json $Obj -Depth 12
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-UiFile([string]$path) {
    $map = @{
        '/'          = 'index.html'
        '/index.html' = 'index.html'
        '/app.js'   = 'app.js'
        '/style.css' = 'style.css'
        '/ui-kit.css' = 'ui-kit.css'
        '/tb-theme.js' = 'tb-theme.js'
        '/tb-icons.js' = 'tb-icons.js'
        '/tb-dirpicker.js' = 'tb-dirpicker.js'
    }
    if (-not $map.ContainsKey($path)) { return $null }
    $file = Join-Path (Join-Path $PSScriptRoot 'ui') $map[$path]
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $type = switch ($map[$path]) {
        'index.html' { 'text/html; charset=utf-8' }
        'app.js'    { 'application/javascript; charset=utf-8' }
        'style.css' { 'text/css; charset=utf-8' }
        'ui-kit.css' { 'text/css; charset=utf-8' }
        'tb-theme.js' { 'application/javascript; charset=utf-8' }
        'tb-icons.js' { 'application/javascript; charset=utf-8' }
        'tb-dirpicker.js' { 'application/javascript; charset=utf-8' }
    }
    [pscustomobject]@{ Type = $type; Bytes = [System.IO.File]::ReadAllBytes($file) }
}

# ---------------- API 路由 ----------------

function Route-Request($req, $ctx) {
    $u = $req.RawUrl -split '\?'
    $path = $u[0]
    $query = @{}
    if ($u.Count -gt 1) {
        foreach ($kv in ($u[1] -split '&')) {
            $p = $kv -split '=', 2
            if ($p[0]) { $query[$p[0]] = [System.Uri]::UnescapeDataString($p[1]) }
        }
    }

    if ($req.Method -eq 'GET' -and $path -notlike '/api/*') {
        $f = Get-UiFile $path
        if ($f) { $ctx.Code = 200; $ctx.Type = $f.Type; $ctx.Bytes = $f.Bytes; return }
        Send-Text $ctx 404 'Not Found'
        return
    }

    switch ($path) {
        '/api/health' {
            Send-JsonRaw $ctx ([pscustomobject]@{
                ok = $true
                id = [string]$script:ToolInfo.id
                version = [string]$script:ToolInfo.version
                pid = $PID
                port = $Port
                uptimeSec = [int]((Get-Date) - $script:StartedAt).TotalSeconds
            })
            return
        }

        '/api/info' {
            Send-JsonRaw $ctx ([pscustomobject]@{ ok = $true; tool = $script:ToolInfo; dataDir = $script:DataDir })
            return
        }

        '/api/state' {
            $act = Get-ActiveJob
            Send-JsonRaw $ctx ([pscustomobject]@{
                server = 'Git-Ref-Manager'
                version = [string]$script:ToolInfo.version
                port = $Port
                busy = [bool]$act
                activeJobId = $(if ($act) { $act.Id } else { $null })
                activeValidations = Get-PendingValidateCount
                subInitBusy = Test-PendingSubInit
            })
            return
        }

        '/api/validate' {
            # 長驗證交子行程：註冊延遲回覆後立刻返回，主迴圈照常接 browse／其他驗證
            $body = Read-JsonBody $req   # 先檢查 JSON 格式（格式錯誤仍同步報錯）
            $payload = if ([string]::IsNullOrWhiteSpace($req.Body)) { '{}' } else { $req.Body }
            if (-not [bool]$body.force) {
                # 突發去重：src 與所有 dst 數秒內才掃過就同步回覆（重整瞬間多框
                # 同路徑不再重複開子行程）；任一缺摘要或 body.force 仍走子行程實扫。
                # 檢查與重建共用同一批取到的摘要（$map），不會因兩次查詢剛好跨過 TTL 而拿到空摘要。
                $map = @{}
                $srcSum = Get-CachedSummary $script:SummaryCache ([string]$body.src)
                $allHit = ($null -ne $srcSum)
                if ($allHit) { $map[(Get-NormalizedRepoKey ([string]$body.src))] = $srcSum }
                $pathsCheck = @()
                if ($body.PSObject.Properties.Name -contains 'dstList') { $pathsCheck = @($body.dstList | ForEach-Object { [string]$_ }) }
                elseif (-not [string]::IsNullOrWhiteSpace($body.dst)) { $pathsCheck = @([string]$body.dst) }
                foreach ($p in $pathsCheck) {
                    if ([string]::IsNullOrWhiteSpace($p)) { continue }   # 空 dst 驗證端本來就跳過
                    $sum = Get-CachedSummary $script:SummaryCache $p
                    if ($null -eq $sum) { $allHit = $false; break }
                    $map[(Get-NormalizedRepoKey $p)] = $sum
                }
                if ($allHit) {
                    $cached = Get-ValidateResult $body { param($p) $k = Get-NormalizedRepoKey ([string]$p); if ($map.ContainsKey($k)) { $map[$k] } else { $null } }
                    Send-JsonRaw $ctx $cached
                    return
                }
            }
            Start-PendingOp 'validate' $ctx $payload
            return
        }

        '/api/subs/status' {
            # 送出預覽／一鍵同步前的輕量比對：每個 Repo 只跑一次 git submodule status
            # （不掃分支、不算工作目錄狀態），單趟百毫秒級，直接在主迴圈同步回覆。
            # 上限 8 個路徑，避免極端情境卡住接單。
            $b = Read-JsonBody $req
            $paths = @($b.paths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 8
            if (-not $paths.Count) { Send-Text $ctx 400 '缺少 paths'; return }
            $items = @()
            foreach ($p in $paths) {
                try {
                    $root = Get-GitRoot ([string]$p)
                    $subs = Get-SubmoduleStatusList $root   # 失敗回 $null：對前端維持空清單（與舊行為一致）
                    if ($null -eq $subs) { $subs = @() }
                    $items += [pscustomobject]@{ path = [string]$p; ok = $true; subs = @($subs) }
                } catch {
                    $items += [pscustomobject]@{ path = [string]$p; ok = $false; error = $_.Exception.Message }
                }
            }
            Send-JsonRaw $ctx ([pscustomobject]@{ items = $items })
            return
        }

        '/api/submodule/init-from-a' {
            # 把 A 已初始化的 Submodule 以本地複製方式初始化到 B（離線；只處理點擊的這一顆）
            $b = Read-JsonBody $req
            $rel = ([string]$b.path).Trim()
            if ([string]::IsNullOrWhiteSpace([string]$b.src) -or [string]::IsNullOrWhiteSpace([string]$b.dst) -or -not $rel) {
                Send-Text $ctx 400 '缺少 src / dst / path'; return
            }
            if ($rel -match '(^|[/\\])\.\.([/\\]|$)' -or $rel -match '[a-zA-Z]:') { Send-Text $ctx 400 '路徑不合法'; return }
            if (Get-ActiveJob) { Send-Text $ctx 409 '有工作在進行中，請等它結束再初始化'; return }
            if (Test-PendingSubInit) { Send-Text $ctx 409 '已有 Submodule 初始化進行中，請稍候'; return }
            $payload = if ([string]::IsNullOrWhiteSpace($req.Body)) { '{}' } else { $req.Body }
            Start-PendingOp 'subinit' $ctx $payload
            return
        }

        '/api/profiles' {
            # 設定檔清單（不含 _last），依名稱排序
            $items = @()
            if (Test-Path -LiteralPath $script:ProfileDir) {
                foreach ($f in @(Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.json' | Sort-Object Name)) {
                    if ($f.Name -eq '_last.json' -or $f.Name -like '*.tmp') { continue }
                    $items += [pscustomobject]@{
                        name  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                        mtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    }
                }
            }
            Send-JsonRaw $ctx ([pscustomobject]@{
                items   = $items
                hasLast = Test-Path -LiteralPath (Get-ProfilePath $script:ProfileLast) -PathType Leaf
            })
            return
        }

        '/api/profiles/get' {
            if (-not $query.ContainsKey('name')) { Send-Text $ctx 400 '缺少 name'; return }
            $n = [string]$query['name']
            if (-not ($n -eq $script:ProfileLast) -and -not (Test-ProfileName $n)) { Send-Text $ctx 400 '設定檔名稱不合法'; return }
            $o = Read-ProfileFile (Get-ProfilePath $n)
            if (-not $o) { Send-Text $ctx 404 '找不到此設定檔'; return }
            Send-JsonRaw $ctx ([pscustomobject]@{ name = $n; savedAt = [string]$o.savedAt; data = $o.data })
            return
        }

        '/api/profiles/save' {
            $b = Read-JsonBody $req
            $n = [string]$b.name
            if (-not (Test-ProfileName $n)) {
                Send-JsonRaw $ctx ([pscustomobject]@{ error = '設定檔名稱不合法：不可為空白或包含 \ / : * ? " < > |，不可用底線或句點開頭' }) 400; return
            }
            if ($null -eq $b.data) { Send-Text $ctx 400 '缺少 data'; return }
            if ($req.Body.Length -gt 200000) { Send-Text $ctx 400 '設定資料過大'; return }
            $path = Get-ProfilePath $n
            $existed = Test-Path -LiteralPath $path -PathType Leaf
            Write-ProfileFile $path ([ordered]@{ savedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); name = $n; data = $b.data })
            Send-JsonRaw $ctx ([pscustomobject]@{ ok = $true; existed = $existed })
            return
        }

        '/api/profiles/last' {
            # GET 讀取上次設定；POST 由前端自動記錄（debounce）
            if ($req.Method -eq 'GET') {
                $o = Read-ProfileFile (Get-ProfilePath $script:ProfileLast)
                Send-JsonRaw $ctx ([pscustomobject]@{ data = $(if ($o) { $o.data } else { $null }) })
                return
            }
            $b = Read-JsonBody $req
            if ($null -eq $b.data) { Send-Text $ctx 400 '缺少 data'; return }
            if ($req.Body.Length -gt 200000) { Send-Text $ctx 400 '設定資料過大'; return }
            Write-ProfileFile (Get-ProfilePath $script:ProfileLast) ([ordered]@{ savedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); data = $b.data })
            Send-JsonRaw $ctx ([pscustomobject]@{ ok = $true })
            return
        }

        '/api/profiles/delete' {
            $b = Read-JsonBody $req
            $n = [string]$b.name
            if (-not (Test-ProfileName $n)) { Send-Text $ctx 400 '設定檔名稱不合法'; return }
            $path = Get-ProfilePath $n
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Send-Text $ctx 404 '找不到此設定檔'; return }
            Remove-Item -LiteralPath $path -Force
            Send-JsonRaw $ctx ([pscustomobject]@{ ok = $true })
            return
        }

        '/api/browse' {
            $b = Read-JsonBody $req
            if ($b.scan) {
                # 缺欄位時補預設（[int]$null 會轉成 0，會把掃描打成空清單）
                $dep = if ($b.depth) { [int]$b.depth } else { 2 }
                $lim = if ($b.limit) { [int]$b.limit } else { 50 }
                $r = Browse-Filesystem -Path ([string]$b.path) -Scan -Depth $dep -Limit $lim
                Send-JsonRaw $ctx ([pscustomobject]@{ repos = @($r.repos) })
                return
            }
            $r = Browse-Filesystem -Path ([string]$b.path)
            Send-JsonRaw $ctx $r
            return
        }

        '/api/sync/preview' {
            if (Get-ActiveJob) { Send-Text $ctx 409 'SERVER_BUSY'; return }
            if (Test-PendingSubInit) { Send-Text $ctx 409 'SUBINIT_BUSY'; return }
            $b = Read-JsonBody $req
            $src = [string]$b.src
            # 目的 Repo：dstList（陣列，可多個）或 dst（單一個，相容舊前端）
            $dstArr = @()
            if ($b.PSObject.Properties.Name -contains 'dstList') { $dstArr = @($b.dstList | ForEach-Object { ([string]$_).Trim() }) }
            elseif (-not [string]::IsNullOrWhiteSpace($b.dst)) { $dstArr = @(([string]$b.dst).Trim()) }
            $seenDst = @{}; $dstClean = @()
            foreach ($dd in $dstArr) {
                if ([string]::IsNullOrWhiteSpace($dd)) { continue }
                $k = $dd.ToLowerInvariant().TrimEnd('\')
                if ($seenDst.ContainsKey($k)) { continue }
                $seenDst[$k] = $true; $dstClean += $dd
            }
            $dstArr = @($dstClean)
            if ($dstArr.Count -eq 0) { Send-Text $ctx 400 '未指定任何目的 Repo'; return }
            $includeOrigin = [bool]$b.includeOrigin
            $includeHeads = [bool]$b.includeHeads
            # 本地 Branch 備份命名空間：空白＝core 預設 refs/sync/source-heads；非法直接 400（不進 job）
            $headsPrefix = ''
            if ($b.PSObject.Properties.Name -contains 'headsPrefix') {
                try { $headsPrefix = Test-RefPrefixFormat ([string]$b.headsPrefix) }
                catch { Send-Text $ctx 400 $_.Exception.Message; return }
            }
            $recurse = [bool]$b.recurse
            # Submodule 勾選過濾：body 有 submodules 陣列 -> 只處理被勾選者；沒有該欄位 -> 全部（CLI/舊行為）
            $hasSubFilter = ($b.PSObject.Properties.Name -contains 'submodules')
            $subSet = @{}
            if ($hasSubFilter) {
                foreach ($q in @($b.submodules)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$q)) { $subSet[[string]$q.ToLowerInvariant()] = $true }
                }
            }
            $subFilterKey = $null
            if ($hasSubFilter) { $subFilterKey = (@($subSet.Keys | Sort-Object) -join "`n") }
            $dstListKey = (@($dstArr | ForEach-Object { $_.ToLowerInvariant().TrimEnd('\') }) | Sort-Object) -join "`n"
            $j = New-ManagerJob 'sync-preview'
            # 注意：preview 不接受 forceOrigin（那是 apply 階段的事），Meta 不記此欄
            $j.Meta = [ordered]@{ src = $src; dsts = @($dstArr) }
            $j.Total = 1   # init 步驟；submodule worker 由 init 動態追加
            Job-Log $j "預覽：$src -> $($dstArr.Count) 個目的 Repo（origin=$includeOrigin heads=$includeHeads$(if ($includeHeads) { if ($headsPrefix) { "->$headsPrefix" } else { '->refs/sync/source-heads' } }) submodule=$recurse$(if ($hasSubFilter) { " 勾選=$($subSet.Count)" }))"
            # $box 為各步驟共享的可變容器（閉包捕獲 hashtable 是捕獲參考）。
            # 注意：所有閉包一律在 route 層建立；PS 5.1 在閉包內再 GetNewClosure 不可靠。
            $box = @{ Src = $src; DstArr = $dstArr; Namespaces = @(); Queue = (New-Object System.Collections.Queue); Worker = $null; Fin = $null; PerDst = @{} }
            $init = {
                param($j)
                $rootA = try { Get-GitRoot $src } catch { throw "A：$($_.Exception.Message)" }
                $namespaces = @()
                if ($includeOrigin) { $namespaces += 'refs/remotes/origin' }
                if ($includeHeads)  { $namespaces += 'refs/heads' }
                if (@($namespaces).Count -eq 0) { throw '未選擇任何要同步的 Ref 類型。' }
                $urlA = Get-OriginUrl $rootA
                $box.Namespaces = @($namespaces)
                $subsA = $null
                if ($recurse) {
                    $subsA = @(Get-InitializedSubmodulePaths $rootA)
                    Job-Log $j "A 已初始化 Submodule：$($subsA.Count) 個"
                }
                for ($di = 0; $di -lt $box.DstArr.Count; $di++) {
                    $dRaw = [string]$box.DstArr[$di]
                    $pd = @{ Dst = $dRaw; RootB = $null; Fatal = $null; OriginMismatch = $false; OriginA = $urlA; OriginB = $null
                             Entries = (New-Object 'System.Collections.Generic.List[object]'); Skipped = (New-Object 'System.Collections.Generic.List[object]') }
                    $box.PerDst[$di] = $pd
                    $tag = "[B$di] "
                    $rootB = $null
                    try { $rootB = Get-GitRoot $dRaw } catch { $pd.Fatal = $_.Exception.Message; Job-Log $j "$tag 無法讀取目的 Repo：$($_.Exception.Message)"; continue }
                    if ((Get-CommonDir $rootA) -eq (Get-CommonDir $rootB)) {
                        $pd.Fatal = 'A 與 B 共用同一個 Git Repository（Worktree），不需同步 Ref。'
                        Job-Log $j "$tag $($pd.Fatal)"
                        continue
                    }
                    $urlB = Get-OriginUrl $rootB
                    $pd.RootB = $rootB; $pd.OriginB = $urlB
                    $pd.OriginMismatch = ($includeOrigin -and ($urlA -ne $urlB))
                    if ($pd.OriginMismatch) { Job-Log $j "$tag 兩邊 origin 不同（A: $urlA / B: $urlB），執行需 forceOrigin" }
                    $m = Get-RefPairUpdates $rootA $rootB $box.Namespaces $headsPrefix
                    $pd.Entries.Add([pscustomobject]@{ Label = '主 Repo'; Src = $rootA; Dst = $rootB; UpdateList = $m.UpdateList; Add = $m.Add; Update = $m.Update; Conflicts = @($m.Conflicts) }) | Out-Null
                    Job-Log $j ("$tag 主 Repo：新增 {0}、更新 {1}、衝突略過 {2}" -f $m.Add, $m.Update, @($m.Conflicts).Count)
                    if (-not $recurse) { continue }
                    $subsB = @(Get-InitializedSubmodulePaths $rootB)
                    $bMap = @{}
                    foreach ($q in $subsB) { $bMap[$q.ToLowerInvariant()] = $q }
                    $aSet = @{}
                    foreach ($q in $subsA) { $aSet[$q.ToLowerInvariant()] = $true }
                    foreach ($p in $subsA) {
                        if ($p -like '*/.git/modules/*') { continue }
                        $key = $p.ToLowerInvariant()
                        if ($hasSubFilter -and -not $subSet.ContainsKey($key)) { $pd.Skipped.Add([pscustomobject]@{ Path = $p; Reason = '使用者未勾選此 Submodule' }) | Out-Null; continue }
                        if (-not $bMap.ContainsKey($key)) { $pd.Skipped.Add([pscustomobject]@{ Path = $p; Reason = 'Repo B 尚未初始化該 Submodule' }) | Out-Null; continue }
                        $subA = Join-Path $rootA $p
                        $subB = Join-Path $rootB $bMap[$key]
                        $ua = Get-OriginUrl $subA
                        $ub = Get-OriginUrl $subB
                        if ($ua -ne $ub) { $pd.Skipped.Add([pscustomobject]@{ Path = $p; Reason = "兩邊 origin URL 不同（$ua / $ub），避免誤覆蓋" }) | Out-Null; continue }
                        if ((Get-CommonDir $subA) -eq (Get-CommonDir $subB)) { $pd.Skipped.Add([pscustomobject]@{ Path = $p; Reason = '兩邊共用同一個 Submodule Repo，不需同步' }) | Out-Null; continue }
                        $box.Queue.Enqueue([pscustomobject]@{ Path = $p; SubA = $subA; SubB = $subB; DstIdx = $di }) | Out-Null
                        $j.Total++
                    }
                    foreach ($q in $subsB) {
                        if ($q -like '*/.git/modules/*') { continue }
                        if ($hasSubFilter -and -not $subSet.ContainsKey($q.ToLowerInvariant())) { continue }   # 未勾選且僅存在於 B：不列參考訊息
                        if (-not $aSet.ContainsKey($q.ToLowerInvariant())) { $pd.Skipped.Add([pscustomobject]@{ Path = $q; Reason = 'Repo A 沒有此 Submodule（僅供參考，不影響同步）' }) | Out-Null }
                    }
                }
                $nWork = $box.Queue.Count
                for ($k = 0; $k -lt $nWork; $k++) { $j.Steps.Enqueue($box.Worker) | Out-Null }
                $j.Steps.Enqueue($box.Fin) | Out-Null
                $j.Done++
            }.GetNewClosure()
            $worker = {
                param($j)
                $pair = $box.Queue.Dequeue()
                $sm = Get-RefPairUpdates $pair.SubA $pair.SubB $box.Namespaces $headsPrefix
                $box.PerDst[[int]$pair.DstIdx].Entries.Add([pscustomobject]@{ Label = "Submodule: $($pair.Path)"; Src = $pair.SubA; Dst = $pair.SubB; UpdateList = $sm.UpdateList; Add = $sm.Add; Update = $sm.Update; Conflicts = @($sm.Conflicts) }) | Out-Null
                Job-Log $j ("[B$($pair.DstIdx)] [$($pair.Path)] 新增 {0}、更新 {1}、衝突略過 {2}" -f $sm.Add, $sm.Update, @($sm.Conflicts).Count)
                $j.Done++
            }.GetNewClosure()
            $fin = {
                    param($j)
                    $perDstFull = @()
                    $perDstJson = @()
                    $gAdd = 0; $gUpd = 0; $gConf = 0
                    for ($di = 0; $di -lt $box.DstArr.Count; $di++) {
                        $pd = $box.PerDst[$di]
                        # PS 5.1 陷阱：@() 直接包 List[object] 會拋 Argument types do not match，须经管道展開
                        $entries = @($pd.Entries | ForEach-Object { $_ })
                        $skipped = @($pd.Skipped | ForEach-Object { $_ })
                        $tAdd = 0; $tUpd = 0; $tConf = 0
                        if (-not $pd.Fatal) {
                            $tAdd = (@($entries | ForEach-Object { $_.Add }) | Measure-Object -Sum).Sum
                            $tUpd = (@($entries | ForEach-Object { $_.Update }) | Measure-Object -Sum).Sum
                            $tConf = (@($entries | ForEach-Object { @($_.Conflicts).Count }) | Measure-Object -Sum).Sum
                            if (-not $tAdd) { $tAdd = 0 }
                            if (-not $tUpd) { $tUpd = 0 }
                            if (-not $tConf) { $tConf = 0 }
                            $gAdd += $tAdd; $gUpd += $tUpd; $gConf += $tConf
                        }
                        $perDstFull += [pscustomobject]@{
                            Dst = $pd.Dst; Fatal = $pd.Fatal
                            OriginMismatch = $pd.OriginMismatch; OriginA = $pd.OriginA; OriginB = $pd.OriginB
                            Entries = $entries; Skipped = $skipped
                            TotalAdd = $tAdd; TotalUpdate = $tUpd; TotalConflict = $tConf
                        }
                        $perDstJson += [pscustomobject]@{
                            dst = $pd.Dst
                            fatal = $pd.Fatal
                            originMismatch = [bool]$pd.OriginMismatch
                            originA = $pd.OriginA
                            originB = $pd.OriginB
                            totalAdd = [int]$tAdd
                            totalUpdate = [int]$tUpd
                            totalConflict = [int]$tConf
                            entries = @($entries | ForEach-Object {
                                [pscustomobject]@{
                                    label = $_.Label
                                    add = $_.Add
                                    update = $_.Update
                                    conflicts = @(($_.Conflicts | ForEach-Object { "$($_.To)（$($_.Reason)）" }) | Select-Object -First 20)
                                }
                            })
                            skipped = @($skipped | ForEach-Object { "$($_.Path)：$($_.Reason)" })
                        }
                    }
                    Set-Preview ([int]$j.Id) ([pscustomobject]@{
                        Src = $src
                        PerDst = $perDstFull
                        SubFilterKey = $subFilterKey
                        DstListKey = $dstListKey
                        HeadsPrefixKey = $headsPrefix
                        TotalAdd = $gAdd; TotalUpdate = $gUpd; TotalConflict = $gConf
                    })
                    $j.Result = [pscustomobject]@{
                        perDst = $perDstJson
                        totalAdd = [int]$gAdd
                        totalUpdate = [int]$gUpd
                        totalConflict = [int]$gConf
                    }
                    Job-Log $j ("預覽完成：{0} 個目的 Repo，合計新增 {1}、更新 {2}、衝突略過 {3}" -f $box.DstArr.Count, $gAdd, $gUpd, $gConf)
                }.GetNewClosure()
            $box.Worker = $worker
            $box.Fin = $fin
            $j.Steps.Enqueue($init) | Out-Null
            Send-JsonRaw $ctx ([pscustomobject]@{ jobId = $j.Id })
            return
        }

        '/api/sync/apply' {
            if (Get-ActiveJob) { Send-Text $ctx 409 'SERVER_BUSY'; return }
            if (Test-PendingSubInit) { Send-Text $ctx 409 'SUBINIT_BUSY'; return }
            $b = Read-JsonBody $req
            $pid2 = [int]$b.jobId
            if (-not $script:Previews.ContainsKey($pid2)) { Send-Text $ctx 404 '找不到預覽結果（請重新預覽）'; return }
            $p = $script:Previews[$pid2]
            # 防護：apply 帶了 submodules 但與預覽時的勾選不一致 -> 請重新預覽
            if ($b.PSObject.Properties.Name -contains 'submodules' -and $null -ne $p.PSObject.Properties['SubFilterKey'] -and $null -ne $p.SubFilterKey) {
                $subNow = @(@($b.submodules | ForEach-Object { ([string]$_).ToLowerInvariant() }) | Sort-Object) -join "`n"
                if ($subNow -cne $p.SubFilterKey) { Send-JsonRaw $ctx ([pscustomobject]@{ error = 'planStale' }) 400; return }
            }
            # 防護：apply 帶了 dstList 但與預覽時的目的 Repo 不一致 -> 請重新預覽
            if ($b.PSObject.Properties.Name -contains 'dstList' -and $null -ne $p.PSObject.Properties['DstListKey'] -and $null -ne $p.DstListKey) {
                $dstNow = @(@($b.dstList | ForEach-Object { ([string]$_).Trim().ToLowerInvariant().TrimEnd('\') }) | Where-Object { $_ } | Sort-Object) -join "`n"
                if ($dstNow -cne $p.DstListKey) { Send-JsonRaw $ctx ([pscustomobject]@{ error = 'planStale' }) 400; return }
            }
            # 防護：備份命名空間與預覽時不一致 -> 請重新預覽（plan 內的 To 是用預覽時的命名空間算的）
            if ($b.PSObject.Properties.Name -contains 'headsPrefix') {
                $hpNow = ''
                try { $hpNow = Test-RefPrefixFormat ([string]$b.headsPrefix) }
                catch { Send-Text $ctx 400 $_.Exception.Message; return }
                $hpPlan = if ($null -ne $p.PSObject.Properties['HeadsPrefixKey']) { [string]$p.HeadsPrefixKey } else { '' }
                if ($hpNow -cne $hpPlan) { Send-JsonRaw $ctx ([pscustomobject]@{ error = 'planStale'; reason = 'headsPrefix' }) 400; return }
            }
            # （舊版單 B plan 的相容包裝已移除：Previews 僅存於記憶體，
            #   本版預覽必含 PerDst，舊 plan 不可能存活到升級後的行程）
            $mismatchDsts = @($p.PerDst | Where-Object { $_.OriginMismatch -and -not $_.Fatal })
            if ($mismatchDsts.Count -gt 0 -and -not [bool]$b.forceOrigin) {
                Send-JsonRaw $ctx ([pscustomobject]@{
                    error = 'originMismatch'
                    originA = @($mismatchDsts)[0].OriginA
                    originB = @($mismatchDsts)[0].OriginB
                    mismatchDsts = @($mismatchDsts | ForEach-Object { $_.Dst })
                }) 400
                return
            }
            $j = New-ManagerJob 'sync-apply'
            $j.Meta = [ordered]@{ src = $p.Src; dsts = @($p.PerDst | ForEach-Object { $_.Dst }); forceOrigin = [bool]$b.forceOrigin; previewId = $pid2 }
            $todo = @()
            foreach ($pd in $p.PerDst) {
                if ($pd.Fatal) { continue }
                foreach ($e in $pd.Entries) {
                    if (@($e.UpdateList).Count -gt 0) { $todo += [pscustomobject]@{ Dst = $pd.Dst; Entry = $e } }
                }
            }
            $j.Total = $todo.Count
            Job-Log $j "開始套用預覽 #$pid2（$($todo.Count) 個 Repo，目的 Repo $($p.PerDst.Count) 個）"
            foreach ($t in $todo) {
                $tCopy = $t
                $step = {
                    param($j)
                    $eCopy = $tCopy.Entry
                    $tag = "[$($tCopy.Dst) / $($eCopy.Label)]"
                    Job-Log $j "$tag 同步 $($eCopy.Add + $eCopy.Update) 個 Ref..."
                    $res = Invoke-RefPairSync -Src $eCopy.Src -Dst $eCopy.Dst -Updates $eCopy.UpdateList -OnLog { param($m) Job-Log $j $m }
                    $j.Applied += $res.Applied
                    foreach ($f in @($res.Failed)) { $j.FailedList.Add("$tag $f") | Out-Null }
                    Job-Log $j "$tag 完成 $($res.Applied) 筆"
                    $j.Done++
                }.GetNewClosure()
                $j.Steps.Enqueue($step) | Out-Null
            }
            $sum = {
                param($j)
                $conflictAll = @()
                $skippedAll = @()
                foreach ($pd in $p.PerDst) {
                    foreach ($e in $pd.Entries) {
                        foreach ($c in @($e.Conflicts)) { $conflictAll += "[$($pd.Dst)] $($e.Label)：$($c.To)（$($c.Reason)）" }
                    }
                    foreach ($s in $pd.Skipped) { $skippedAll += "[$($pd.Dst)] $($s.Path)：$($s.Reason)" }
                }
                $j.Result = [pscustomobject]@{
                    applied = $j.Applied
                    failed = @($j.FailedList)
                    conflictSkipped = [int]$p.TotalConflict
                    conflicts = $conflictAll
                    skippedSubmodules = $skippedAll
                }
                if ($j.FailedList.Count -gt 0) { $j.State = 'Failed'; $j.Error = "有 $($j.FailedList.Count) 筆 Ref 套用失敗" }
                Job-Log $j "全部完成：套用 $($j.Applied) 筆，失敗 $($j.FailedList.Count) 筆"
            }.GetNewClosure()
            $j.Steps.Enqueue($sum) | Out-Null
            Send-JsonRaw $ctx ([pscustomobject]@{ jobId = $j.Id })
            return
        }

        '/api/fetch/start' {
            if (Get-ActiveJob) { Send-Text $ctx 409 'SERVER_BUSY'; return }
            if (Test-PendingSubInit) { Send-Text $ctx 409 'SUBINIT_BUSY'; return }
            $b = Read-JsonBody $req
            if (-not [bool]$b.confirm) { Send-Text $ctx 400 '缺少 confirm=true（這是第二次確認）'; return }
            $repoA = [string]$b.repoA
            $repoB = [string]$b.repoB
            $prune = [bool]$b.prune
            $recurse = [bool]$b.recurse
            $rootA = Get-GitRoot $repoA
            $rootB = $null
            if (-not [string]::IsNullOrWhiteSpace($repoB)) {
                $rootB = Get-GitRoot $repoB
                if ((Get-CommonDir $rootA) -eq (Get-CommonDir $rootB)) {
                    Write-Verbose 'B 與 A 共用 repo'
                    $rootB = $null
                }
            }
            $targets = @(Get-FetchTargets $rootA $recurse)
            if ($rootB) { $targets += @(Get-FetchTargets $rootB $recurse | ForEach-Object { [pscustomobject]@{ Label = "B / $($_.Label)"; Path = $_.Path } }) }
            $j = New-ManagerJob 'fetch'
            $j.Meta = [ordered]@{ repoA = $repoA; repoB = $repoB; prune = [bool]$prune; recurse = [bool]$recurse }
            $j.Total = $targets.Count
            Job-Log $j "Fetch 開始：共 $($targets.Count) 個 Repo（prune=$prune）"
            foreach ($t in $targets) {
                $tCopy = $t
                $step = {
                    param($j)
                    if (-not (Get-OriginUrl $tCopy.Path)) {
                        Job-Log $j "[$($tCopy.Label)] 沒有 origin，已略過"
                        $j.Done++
                        return
                    }
                    Job-Log $j "[$($tCopy.Label)] git fetch origin ..."
                    $ga = @('fetch', '--no-recurse-submodules')
                    if ($prune) { $ga += '--prune' }
                    $ga += 'origin'
                    $r = Invoke-Git -Repo $tCopy.Path -GitArgs $ga -AllowFail
                    if ($r.Code -ne 0) {
                        $j.FailedList.Add("$($tCopy.Label)（exit $($r.Code)）") | Out-Null
                        Job-Log $j "[$($tCopy.Label)] 失敗：$((@($r.Lines) | Select-Object -Last 2) -join ' | ')"
                    } else {
                        Job-Log $j "[$($tCopy.Label)] 完成"
                    }
                    $j.Done++
                }.GetNewClosure()
                $j.Steps.Enqueue($step) | Out-Null
            }
            $sum = {
                param($j)
                $j.Result = [pscustomobject]@{ targets = $j.Total; failed = @($j.FailedList) }
                if ($j.FailedList.Count -gt 0) { $j.State = 'Failed'; $j.Error = "有 $($j.FailedList.Count) 個 Repo Fetch 失敗" }
            }.GetNewClosure()
            $j.Steps.Enqueue($sum) | Out-Null
            Send-JsonRaw $ctx ([pscustomobject]@{ jobId = $j.Id })
            return
        }

        '/api/worktree/check' {
            $b = Read-JsonBody $req
            $r = Test-WorktreeRequest -Source ([string]$b.source) -Parent ([string]$b.parent) -FolderName ([string]$b.folderName) -Branch ([string]$b.branch) -StartingPoint ([string]$b.startingPoint)
            Send-JsonRaw $ctx ([pscustomobject]@{ items = @($r.Items); target = $r.Target; allOk = [bool]$r.AllOk; warnings = @($r.Warnings) })
            return
        }

        '/api/worktree/create' {
            if (Get-ActiveJob) { Send-Text $ctx 409 'SERVER_BUSY'; return }
            if (Test-PendingSubInit) { Send-Text $ctx 409 'SUBINIT_BUSY'; return }
            $b = Read-JsonBody $req
            $source = [string]$b.source
            $parent = [string]$b.parent
            $folderName = [string]$b.folderName
            $branch = [string]$b.branch
            $startingPoint = [string]$b.startingPoint
            if ([string]::IsNullOrWhiteSpace($startingPoint)) { $startingPoint = 'HEAD' }
            $chk = Test-WorktreeRequest -Source $source -Parent $parent -FolderName $folderName -Branch $branch -StartingPoint $startingPoint
            if (-not $chk.AllOk) {
                $bad = @($chk.Items | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Check)：$($_.Msg)" })
                Send-JsonRaw $ctx ([pscustomobject]@{ error = '檢查未通過'; items = $bad }) 400
                return
            }
            $j = New-ManagerJob 'worktree'
            $j.Meta = [ordered]@{ source = $source; parent = $parent; folder = $folderName; branch = $branch; startingPoint = $startingPoint }
            $j.Total = 1
            Job-Log $j "建立 Worktree：$($chk.Target)（Branch：$branch）"
            $step = {
                param($j)
                $r = Invoke-Git -Repo $chk.Source -GitArgs @('worktree', 'add', '-b', $branch, $chk.Target, $startingPoint) -AllowFail
                if ($r.Code -ne 0) { throw "建立 Worktree 失敗：$((@($r.Lines) | Select-Object -Last 3) -join ' | ')" }
                Job-Log $j "完成：$($chk.Target)"
                $j.Result = [pscustomobject]@{ target = $chk.Target; branch = $branch }
                $j.Done = 1
            }.GetNewClosure()
            $j.Steps.Enqueue($step) | Out-Null
            Send-JsonRaw $ctx ([pscustomobject]@{ jobId = $j.Id })
            return
        }

        '/api/jobs/history' {
            # 歷史清單（不含 log），新的在前
            $out = @()
            foreach ($rec in $script:History) { $out += Get-HistorySummary $rec }
            [array]::Reverse($out)
            Send-JsonRaw $ctx ([pscustomobject]@{ items = $out })
            return
        }

        '/api/jobs/history/log' {
            if (-not $query.ContainsKey('id')) { Send-Text $ctx 400 '缺少 id'; return }
            $id = 0
            if (-not [int]::TryParse($query['id'], [ref]$id)) { Send-Text $ctx 400 'id 格式錯誤'; return }
            $found = $null
            foreach ($rec in $script:History) {
                $rid = 0
                if ([int]::TryParse([string]$rec.id, [ref]$rid) -and $rid -eq $id) { $found = $rec; break }
            }
            if (-not $found) { Send-Text $ctx 404 '找不到此歷史紀錄'; return }
            $logArr = @()
            if ($found.log) { foreach ($l in @($found.log)) { if ($l) { $logArr += [string]$l } } }
            Send-JsonRaw $ctx ([pscustomobject]@{
                id        = [int]$found.id
                kind      = [string]$found.kind
                state     = [string]$found.state
                startedAt = [string]$found.startedAt
                endedAt   = [string]$found.endedAt
                meta      = $found.meta
                error     = [string]$found.error
                log       = $logArr
            })
            return
        }

        '/api/jobs' {
            if (-not $query.ContainsKey('id')) { Send-Text $ctx 400 '缺少 id'; return }
            $id = [int]$query['id']
            if (-not $script:Jobs.ContainsKey($id)) { Send-Text $ctx 404 '找不到此 job'; return }
            $j = $script:Jobs[$id]
            $cursor = 0
            if ($query.ContainsKey('cursor')) { $cursor = [int]$query['cursor'] }
            if ($cursor -lt 0) { $cursor = 0 }
            if ($cursor -gt $j.Lines.Count) { $cursor = $j.Lines.Count }
            $newLines = @()
            for ($i = $cursor; $i -lt $j.Lines.Count; $i++) { $newLines += [pscustomobject]@{ i = $i; m = $j.Lines[$i] } }
            Send-JsonRaw $ctx ([pscustomobject]@{
                id = $j.Id
                kind = $j.Kind
                state = $j.State
                done = [int]$j.Done
                total = [int]$j.Total
                log = $newLines
                next = $j.Lines.Count
                result = $j.Result
                error = $j.Error
            })
            return
        }

        default {
            Send-Text $ctx 404 'Not Found'
        }
    }
}

function Test-RequestAllowed($req) {
    # TOOL-SPEC 第 5 節安全規則。回傳 $null 表示放行，否則回傳 @{ Status; Code; Message }。
    $selfHosts = @("127.0.0.1:$Port", "localhost:$Port")
    $hostHdr = [string]$req.Headers['host']
    if (-not ($selfHosts -contains $hostHdr.ToLowerInvariant())) {
        return @{ Status = 403; Code = 'FORBIDDEN_HOST'; Message = "不允許的 Host：$hostHdr" }
    }
    $method = ([string]$req.Method).ToUpperInvariant()
    if ($method -eq 'GET' -or $method -eq 'HEAD') { return $null }
    if ($method -ne 'POST') {
        return @{ Status = 405; Code = 'METHOD_NOT_ALLOWED'; Message = "不支援的方法：$method" }
    }
    if ([string]$req.Headers['x-toolbox-request'] -ne '1') {
        return @{ Status = 403; Code = 'MISSING_TOOLBOX_HEADER'; Message = '缺少 X-Toolbox-Request 標頭' }
    }
    $origin = [string]$req.Headers['origin']
    if ($origin) {
        $allowed = @("http://127.0.0.1:$Port", "http://localhost:$Port") + $script:HubOrigins
        if (-not ($allowed -contains $origin.ToLowerInvariant())) {
            return @{ Status = 403; Code = 'FORBIDDEN_ORIGIN'; Message = "不允許的來源：$origin" }
        }
    }
    $ct = [string]$req.Headers['content-type']
    if (-not $ct.ToLowerInvariant().StartsWith('application/json')) {
        return @{ Status = 415; Code = 'UNSUPPORTED_MEDIA_TYPE'; Message = 'Content-Type 必須是 application/json' }
    }
    if ($req.Body -and $req.Body.Length -gt $script:MaxBodyChars) {
        return @{ Status = 413; Code = 'PAYLOAD_TOO_LARGE'; Message = '請求內容超過 1 MB' }
    }
    return $null
}


function Handle-Client($hctx) {
    $ctx = $null
    try {
        $req = Read-ClientRequest $hctx
        $ctx = @{ Code = 200; Type = 'text/plain; charset=utf-8'; Bytes = $null; Http = $hctx }
        $deny = Test-RequestAllowed $req
        try {
            if ($deny) {
                Send-JsonRaw $ctx ([pscustomobject]@{ ok = $false; error = [pscustomobject]@{ code = $deny.Code; message = $deny.Message; detail = $null } }) ([int]$deny.Status)
            } else {
                Route-Request $req $ctx
            }
        } catch {
            Send-Text $ctx 500 "500 $($_.Exception.Message)"
        }
        if ($ctx.Deferred) { return }   # 回覆與關線由主迴圈在子行程結束後接手
        Send-Response $hctx ([int]$ctx.Code) ([string]$ctx.Type) ([byte[]]$ctx.Bytes)
    } catch {
        # 客戶端中斷之類，忽略
        if (-not $ctx -or -not $ctx.Deferred) { try { $hctx.Response.Abort() } catch { } }
    }
}

# ---------------- 主迴圈 ----------------


$listener = $null
$lastErr = $null
$portDenied = 0; $portInUse = 0
# 明確指定 -Port 時只試那一個；否則從預設 port 往上找（最多 +20），都不行就請系統配一個空的 port。
# 0 代表「向系統要一個」：HttpListener 不能直接綁 0，先用 TcpListener 問到 port 再交給 HttpListener。
$tryPorts = if ($script:PortExplicit) { @($Port) } else { @($Port..($Port + 20)) + @(0, 0, 0) }
foreach ($p in $tryPorts) {
    if ($p -eq 0) {
        try {
            $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $probe.Start(); $p = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
        } catch { $lastErr = $_.Exception.Message; continue }
    }
    $h = New-Object System.Net.HttpListener
    $h.Prefixes.Add("http://127.0.0.1:$p/")
    $h.Prefixes.Add("http://localhost:$p/")
    try {
        $h.Start(); $listener = $h; $Port = $p
        break
    } catch {
        $lastErr = $_.Exception.Message
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.HttpListenerException])) { $ex = $ex.InnerException }
        if ($ex) { switch ([int]$ex.ErrorCode) { 5 { $portDenied++ } 32 { $portInUse++ } 183 { $portInUse++ } } }
        try { $h.Close() } catch { }
    }
}
if (-not $listener) {
    $why = if ($portDenied -gt 0 -and $portInUse -eq 0) { '存取被拒（port 被 Windows 保留，或缺少權限）。可用 netsh interface ipv4 show excludedportrange protocol=tcp 查看' } elseif ($portInUse -gt 0 -and $portDenied -eq 0) { 'port 已被其他程式佔用' } else { $lastErr }
    Write-Host "無法監聽 127.0.0.1:$($tryPorts[0])：$why" -ForegroundColor Red
    if ($script:PortExplicit) { Write-Host '不指定 -Port 時會自動找可用的 port。' -ForegroundColor Gray }
    exit 5
}
# Hub 讀到以 READY 開頭的這一行才算啟動成功（TOOL-SPEC 第 5 節）
[Console]::Out.WriteLine("READY http://127.0.0.1:$Port")
[Console]::Out.Flush()

# 父行程監看：-ParentPid 指定的行程結束時自動關閉
$script:ParentProc = $null
if ($ParentPid -gt 0) {
    try { $script:ParentProc = Get-Process -Id $ParentPid -ErrorAction Stop }
    catch { Write-Host "父行程 $ParentPid 不存在，結束。" -ForegroundColor Red; $listener.Stop(); exit 1 }
}
$script:NextParentCheck = Get-Date

Read-JobHistory
if ($script:History.Count -gt 0) {
    Write-Host "已載入 Job 歷史紀錄 $($script:History.Count) 筆（$($script:HistoryFile)）" -ForegroundColor Gray
}

$url = "http://127.0.0.1:$Port"
Write-Host '===============================================' -ForegroundColor Cyan
Write-Host " Git Ref Manager Web 控制台已啟動： $url" -ForegroundColor Green
Write-Host ' 只綁定本機 127.0.0.1；停止請按 Ctrl+C 或關閉此視窗' -ForegroundColor Gray
Write-Host '===============================================' -ForegroundColor Cyan
if ($OpenBrowser) { Start-Process $url }


try {
    while ($true) {
        if ($script:ParentProc -and (Get-Date) -ge $script:NextParentCheck) {
            $script:NextParentCheck = (Get-Date).AddSeconds(2)
            $gone = $true
            try { $script:ParentProc.Refresh(); $gone = $script:ParentProc.HasExited } catch { $gone = $true }
            if ($gone) { Write-Host '父行程已結束，自動關閉。' -ForegroundColor Gray; break }
        }
        Invoke-PendingOps   # 先結算已結束的子行程，避免空轉 Sleep 延後回覆
        if (-not $script:PendingCtx) { $script:PendingCtx = $listener.BeginGetContext($null, $null) }
        if ($script:PendingCtx.IsCompleted) {
            $hctx = $null
            try { $hctx = $listener.EndGetContext($script:PendingCtx) } catch { }
            $script:PendingCtx = $null
            if ($hctx) { Handle-Client $hctx }
        }
        elseif ((Get-ActiveJob)) {
            Invoke-JobStep (Get-ActiveJob)
        }
        else {
            [void]$script:PendingCtx.AsyncWaitHandle.WaitOne(60)
        }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Write-Host '已停止監聽。'
}
