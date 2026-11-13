# GitRefCore.ps1 - Git Ref Manager 共用核心（CLI 選單版與 Web 面板共用）
# 無任何互動提示；長任務由呼叫端包裝。
# 安全底線：不 push、不刪除 ref、不自動初始化/切換 Submodule。

function Invoke-Git {
    param(
        [string]$Repo,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    # git 正常訊息也走 stderr；必須用 Continue，避免 NativeCommandError 中斷。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = if ($Repo) { & git -C $Repo @GitArgs 2>&1 } else { & git @GitArgs 2>&1 }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $lines = @($out | ForEach-Object { [string]$_ })
    if ($code -ne 0 -and -not $AllowFail) {
        $joined = ($lines | Select-Object -Last 6) -join ' | '
        throw "git $($GitArgs -join ' ') 失敗（exit $code）：$joined"
    }
    [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Assert-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '找不到 git 指令。請先安裝 Git for Windows，並確認 git.exe 已加入 PATH。'
    }
    [void](Invoke-Git -GitArgs @('--version'))
}

function Get-GitRoot([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder)) { throw '資料夾路徑為空。' }
    if (-not (Test-Path -LiteralPath $Folder)) {
        $resolved = Resolve-Path -LiteralPath $Folder -ErrorAction SilentlyContinue
        if (-not $resolved) { throw "資料夾不存在：$Folder" }
    }
    $r = Invoke-Git -Repo $Folder -GitArgs @('rev-parse','--show-toplevel') -AllowFail
    if ($r.Code -ne 0 -or $r.Lines.Count -eq 0 -or -not $r.Lines[0]) { throw "不是 Git 工作目錄：$Folder" }
    [System.IO.Path]::GetFullPath(($r.Lines | Select-Object -First 1))
}

function Get-CommonDir([string]$Repo) {
    $r = Invoke-Git -Repo $Repo -GitArgs @('rev-parse','--git-common-dir')
    $p = ($r.Lines | Select-Object -First 1)
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
    [System.IO.Path]::GetFullPath($p).TrimEnd('\','/').ToLowerInvariant()
}

function Get-OriginUrl([string]$Repo) {
    $r = Invoke-Git -Repo $Repo -GitArgs @('remote','get-url','origin') -AllowFail
    if ($r.Code -ne 0) { return $null }
    $u = ($r.Lines | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    return ([string]$u).Trim()
}

function Get-Refs([string]$Repo, [string[]]$Namespaces) {
    # 用 for-each-ref 讀取（同時支援 packed-refs 與 reftable）。
    $fmt = '--format=%(refname)%09%(objectname)%09%(symref)'
    $args2 = @('for-each-ref', $fmt)
    if ($Namespaces -and @($Namespaces).Count -gt 0) { $args2 += [string[]]$Namespaces }
    $r = Invoke-Git -Repo $Repo -GitArgs $args2
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @($r.Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = ([string]$line) -split "`t"
        if ($f.Count -lt 3) { continue }
        $list.Add([pscustomobject]@{ Name = $f[0]; ObjectId = $f[1]; Symbolic = $f[2] }) | Out-Null
    }
    return $list.ToArray()
}

function Get-InitializedSubmodulePaths([string]$Repo) {
    # 遞迴列出「已初始化」的 Submodule 相對路徑；未初始化(-)與衝突(U)一律略過。
    $r = Invoke-Git -Repo $Repo -GitArgs @('submodule','status','--recursive') -AllowFail
    if ($r.Code -ne 0) { throw "無法讀取 Submodule 清單：$Repo" }
    $all = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($r.Lines)) {
        $value = [string]$line
        if ($value -notmatch '^([ +\-U])([0-9a-fA-F]{40,64})\s+(.+)$') { continue }
        $flag = $matches[1]
        $subpath = ($matches[3] -replace '\s+\([^)]*\)$', '')
        if ($flag -eq '-' -or $flag -eq 'U') { continue }   # 未初始化/衝突：一律略過
        $full = Join-Path $Repo $subpath
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        $inside = Invoke-Git -Repo $full -GitArgs @('rev-parse','--is-inside-work-tree') -AllowFail
        if ($inside.Code -ne 0 -or -not (@($inside.Lines) -contains 'true')) { continue }
        if (-not $all.Contains($subpath)) { $all.Add($subpath) | Out-Null }
    }
    return @($all.ToArray())
}

function Get-SubmoduleStatusList([string]$Repo) {
    # 遞迴列出所有 Submodule 相對路徑與初始化狀態（含未初始化 '-' 與衝突 'U'），供 Web 勾選清單用。
    # 掃描失敗回傳 $null（區別於「沒有 Submodule」的空清單），讓呼叫端能退守或標示。
    $r = Invoke-Git -Repo $Repo -GitArgs @('submodule','status','--recursive') -AllowFail
    if ($r.Code -ne 0) { return $null }
    $seen = @{}
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @($r.Lines)) {
        $value = [string]$line
        if ($value -notmatch '^([ +\-U])([0-9a-fA-F]{40,64})\s+(.+)$') { continue }
        $flag = $matches[1]
        $subpath = ($matches[3] -replace '\s+\([^)]*\)$', '')
        if ($subpath -like '*/.git/modules/*') { continue }
        $key = $subpath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $list.Add([pscustomobject]@{ path = $subpath; initialized = ($flag -ne '-' -and $flag -ne 'U') }) | Out-Null
    }
    return @($list.ToArray())
}

function Get-RepoSummary([string]$Repo) {
    try {
        $root = Get-GitRoot $Repo
        $branch = (Invoke-Git -Repo $root -GitArgs @('rev-parse','--abbrev-ref','HEAD') -AllowFail).Lines | Select-Object -First 1
        $st = Invoke-Git -Repo $root -GitArgs @('status','--porcelain') -AllowFail
        $dirty = @($st.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        $subTotal = 0; $subInit = 0
        $subPaths = @()
        if (Test-Path -LiteralPath (Join-Path $root '.gitmodules')) {
            # 單趟 --recursive 同時供完整清單與計數：無 '/' 的條目即頂層 Submodule，
            # 維持舊版非遞迴輸出的 total/initialized 顯示語意，省掉第二次 git 行程。
            $subPaths = Get-SubmoduleStatusList $root
            if ($null -eq $subPaths) {
                # 遞迴掃描失敗（例如某顆子模块工作樹損壞讓 --recursive fatal）：
                # 退回非遞迴計數，避免有 .gitmodules 的 Repo 靜默報 0 顆。
                $sm = Invoke-Git -Repo $root -GitArgs @('submodule','status') -AllowFail
                foreach ($l in @($sm.Lines)) {
                    if ($l -match '^\s*[ +\-U][0-9a-fA-F]{40,64}') { $subTotal++; if (-not $l.StartsWith('-')) { $subInit++ } }
                }
                $subPaths = @()
            } else {
                $subPaths = @($subPaths)
                foreach ($sp in $subPaths) {
                    if ($sp.path -notmatch '[\\/]') { $subTotal++; if ($sp.initialized) { $subInit++ } }
                }
            }
        }
        $commonDir = ''
        try { $commonDir = [string](Get-CommonDir $root) } catch { }   # 取得失敗留空，驗證端會退回即時查詢
        return [pscustomobject]@{
            path = $root
            ok = $true
            branch = [string]$branch
            origin = [string](Get-OriginUrl $root)
            dirty = $dirty
            commonDir = $commonDir
            submodules = @{ total = $subTotal; initialized = $subInit }
            submodulePaths = $subPaths
        }
    } catch {
        return [pscustomobject]@{ path = $Repo; ok = $false; error = $_.Exception.Message }
    }
}

# ---------------- Repo 摘要 TTL 快取（Web 重整驗證突發去重） ----------------
# 頁面重新載入時 UI 會對同一批 Repo 幾乎同時發出好幾筆驗證，每筆原本都要
# 開短命子行程掃 git（含 submodule status）。主迴圈把摘要短效快取，突發期
# 內直接記憶體回覆；UI 按 Enter 強制重驗會繞過此快取，外部改動仍可即時反映。

function Get-NormalizedRepoKey([string]$Repo) {
    $v = ([string]$Repo).Trim().Trim('"')
    $v = $v -replace '/', '\'   # C:/x 與 C:\x 同一顆 Repo
    $v = $v -replace '[\\]+$', ''
    return $v.ToLowerInvariant()
}

function New-SummaryCache([double]$TtlSec = 8) {
    return [pscustomobject]@{ Ttl = [TimeSpan]::FromSeconds($TtlSec); Items = [hashtable]::Synchronized(@{}) }
}

function Get-CachedSummary($Cache, [string]$Repo) {
    if ($null -eq $Cache) { return $null }
    $key = Get-NormalizedRepoKey $Repo
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    if (-not $Cache.Items.ContainsKey($key)) { return $null }
    $ent = $Cache.Items[$key]
    if ((Get-Date) -gt $ent.Expires) { [void]$Cache.Items.Remove($key); return $null }
    return $ent.Summary
}

function Set-CachedSummary($Cache, $Summary) {
    if ($null -eq $Cache -or $null -eq $Summary) { return }
    if (-not $Summary.PSObject.Properties['ok'] -or -not [bool]$Summary.ok) { return }   # 失敗摘要不緩存，重試即時重掃
    if (-not $Summary.PSObject.Properties['path']) { return }
    $key = Get-NormalizedRepoKey ([string]$Summary.path)
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $Cache.Items[$key] = [pscustomobject]@{ Summary = $Summary; Expires = (Get-Date).Add($Cache.Ttl) }
}

function Remove-CachedSummary($Cache, [string]$Repo) {
    # Repo 狀態被變更（如 Submodule 初始化）後淘汰舊摘要，下次驗證即時重掃
    if ($null -eq $Cache) { return }
    $key = Get-NormalizedRepoKey $Repo
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    [void]$Cache.Items.Remove($key)
}

function Get-OrdinalSortedNames([string[]]$Names) {
    # 去重（大小寫視為不同）並以 Ordinal 排序，供 Find-RefConflicts 的 BinarySearch 使用。
    $nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($n in @($Names)) { if ($null -ne $n) { [void]$nameSet.Add([string]$n) } }
    $sorted = New-Object string[] $nameSet.Count
    $nameSet.CopyTo($sorted)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    # 逗號：避免單一元素陣列被 PowerShell 展開成純量
    return ,$sorted
}

function Find-RefConflicts($Updates, $DstNamesSorted, [System.Collections.Generic.HashSet[string]]$DstNameSet) {
    # 找出「ref 同時要當檔案與資料夾」的 D/F 衝突：
    #   正向：目標 T 的某個上層路徑在目的端已存在為 ref。
    #   反向：目的端已有 T/xxx，表示 T 在目的端必須是目錄。
    $clean = @(); $conf = @()
    foreach ($u in @($Updates)) {
        $t = $u.To
        $bad = $null
        $parts = $t.Split('/')
        for ($i = $parts.Count - 1; $i -ge 1; $i--) {
            $anc = ($parts[0..($i - 1)] -join '/')
            if ($DstNameSet.Contains($anc)) { $bad = "目的端已有 ref 佔用上層路徑：$anc"; break }
        }
        if (-not $bad) {
            $prefix = $t + '/'
            $idx = [Array]::BinarySearch($DstNamesSorted, $prefix, [System.StringComparer]::Ordinal)
            # PowerShell 運算子優先序：必須寫成 (-$idx) - 1；`-not $idx - 1` 會被解析成
            # (-not $idx) - 1 = -1，反向 D/F 檢查永遠查錯位置而漏判。
            if ($idx -lt 0) { $idx = (-$idx) - 1 }
            if ($idx -lt $DstNamesSorted.Count -and $DstNamesSorted[$idx].StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                $bad = "目的端已有子分支：$($DstNamesSorted[$idx])"
            }
        }
        if ($bad) { $conf += [pscustomobject]@{ To = $t; Reason = $bad } } else { $clean += $u }
    }
    return [pscustomobject]@{ Clean = @($clean); Conflicts = @($conf) }
}

function Test-RefPrefixFormat([string]$Prefix) {
    # 驗證並正規化 ref 命名空間前綴（規則比照 git check-ref-format，離線實作）。
    # 回傳正規化前綴（去首尾 '/'）；空白回傳 ''（呼叫端採預設值）。不合法直接 throw。
    $p = ([string]$Prefix).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    if ($p -match '[\x00-\x1f\x7f]') { throw "命名空間含控制字元：$p" }
    if ($p -match '[\s~^:?*\[\]\\]' -or $p.Contains('@{')) { throw "命名空間含非法字元：$p（不支援空白、~ ^ : ? * [ \\ 與 @{）" }
    if ($p -match '\.\.') { throw "命名空間不能含『..』：$p" }
    $p = $p.Trim('/')
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    foreach ($seg in $p.Split('/')) {
        if (-not $seg) { throw "命名空間不能有空段（連續 //）：$p" }
        if ($seg.StartsWith('.')) { throw "命名空間段不能以『.』開頭：$p" }
        if ($seg.EndsWith('.lock') -or $seg.EndsWith('.')) { throw "命名空間段不能以『.』或『.lock』結尾：$p" }
    }
    # 保留／危險命名空間：大小寫變體都要擋（Windows 檔案系統不區分大小寫，
    # 『REFS/HEADS/x』寫進去會直接動到 .git\refs\heads\ 下的真實分支檔案）。
    $pl = $p.ToLowerInvariant()
    if ($pl -eq 'head' -or $pl -eq 'refs/heads' -or $pl.StartsWith('refs/heads/')) {
        throw "命名空間不能是 $p：會直接覆寫目的端的真實分支，請改用 refs/ 下的獨立空間"
    }
    if ($pl -eq 'refs/remotes' -or $pl.StartsWith('refs/remotes/') -or $pl -eq 'refs/tags' -or $pl.StartsWith('refs/tags/')) {
        throw "命名空間 $p 會污染目的端的遠端追蹤 Ref 或標籤，請改用獨立空間"
    }
    if ($pl -eq 'refs/bisect' -or $pl.StartsWith('refs/bisect/') -or $pl -eq 'refs/next' -or $pl.StartsWith('refs/next/') -or
        $pl -eq 'refs/replace' -or $pl.StartsWith('refs/replace/')) {
        throw "命名空間 $p 為 Git 保留，請改用其他名稱"
    }
    return $p
}

function Get-RefPairUpdates($Src, $Dst, [string[]]$Namespaces, [string]$HeadsPrefix) {
    # 只計算 A->B 需要的 ref 異動（含 D/F 衝突與大小寫衝突預檢），不做任何寫入。
    # HeadsPrefix：refs/heads/* 備份到目的端的命名空間；空白＝預設 refs/sync/source-heads。
    if ([string]::IsNullOrWhiteSpace($HeadsPrefix)) { $HeadsPrefix = 'refs/sync/source-heads' }
    # 大小寫必須用 Ordinal 比對；PowerShell 預設 hashtable 不區分大小寫，
    # 會讓 A 端「僅大小寫不同」的重複 Ref（如 Feature/feature）永遠無法收斂。
    $srcRefs = @(Get-Refs $Src $Namespaces)
    $dstExact = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @(Get-Refs $Dst @('refs/remotes/origin', $HeadsPrefix))) {
        if (-not $dstExact.ContainsKey($r.Name)) { $dstExact[$r.Name] = $r.ObjectId }
    }
    # 排序與 Find-RefConflicts 的 BinarySearch 必須用同一個 comparer（Ordinal）。
    # 不可用 Sort-Object：它依 CurrentCulture 排序且大小寫不敏感去重，
    # 例如 @('refs/heads/aa','refs/heads/B') 排序後 ordinal BinarySearch 會找錯位置而漏掉 D/F 衝突。
    $sorted = Get-OrdinalSortedNames @(Get-Refs $Dst @() | ForEach-Object { [string]$_.Name })
    $dstAllNames = $sorted
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $setIC = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $dstAllNames) { [void]$set.Add($n); [void]$setIC.Add($n) }
    $seenCase = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $updates = @()
    $caseConf = @()
    foreach ($r in $srcRefs) {
        if (-not [string]::IsNullOrEmpty($r.Symbolic)) { continue }   # 略過 symbolic ref（如 origin/HEAD）
        $to = $r.Name
        if ($r.Name.StartsWith('refs/heads/')) {
            $to = $HeadsPrefix + '/' + $r.Name.Substring('refs/heads/'.Length)
        }
        if ($dstExact.ContainsKey($to)) {
            if ($dstExact[$to] -eq $r.ObjectId) { continue }
            $action = '更新'
        } else {
            $action = '新增'
            # Windows 檔案系統無法同時容納僅大小寫不同的 Ref：目的端已有變體、
            # 或來源端本身重複時，一律略過並回報，避免互相覆蓋與永不收斂。
            if ($setIC.Contains($to)) {
                $caseConf += [pscustomobject]@{ To = $to; Reason = '目的端已有僅大小寫不同的同名 Ref（Windows 限制，無法同時存在，略過）' }
                continue
            }
            if ($seenCase.Contains($to)) {
                $caseConf += [pscustomobject]@{ To = $to; Reason = '來源端存在僅大小寫不同的重複 Ref，避免目的端互相覆蓋，只同步第一個' }
                continue
            }
            [void]$seenCase.Add($to)
        }
        $updates += [pscustomobject]@{ From = $r.Name; To = $to; ObjectId = $r.ObjectId; Action = $action }
    }
    $rc = Find-RefConflicts $updates $sorted $set
    $clean = @($rc.Clean | ForEach-Object { @{ From = $_.From; To = $_.To; ObjectId = $_.ObjectId; Action = $_.Action } })
    return [pscustomobject]@{
        UpdateList = $clean
        Add        = @($clean | Where-Object { $_.Action -eq '新增' }).Count
        Update     = @($clean | Where-Object { $_.Action -eq '更新' }).Count
        Conflicts  = @($rc.Conflicts) + @($caseConf)
    }
}

function Invoke-RefPairSync($Src, $Dst, $Updates, [scriptblock]$OnLog) {
    # 以 30 筆/批 atomic 方式套用；批次失敗時降為逐筆重試，壞的跳過不卡整批。
    $applied = 0
    $failed = @()
    if (@($Updates).Count -eq 0) { return [pscustomobject]@{ Applied = 0; Failed = @() } }
    $batchSize = 30
    $total = @($Updates).Count
    for ($i = 0; $i -lt $total; $i += $batchSize) {
        $last = [Math]::Min($i + $batchSize - 1, $total - 1)
        $batch = @($Updates[$i..$last])
        $specs = @($batch | ForEach-Object { '+' + $_.From + ':' + $_.To })
        if ($OnLog) { & $OnLog ("  批次 {0}-{1} / {2} ..." -f ($i + 1), ($last + 1), $total) }
        $r = Invoke-Git -Repo $Dst -GitArgs (@('fetch','--no-tags','--no-recurse-submodules','--atomic', $Src) + $specs) -AllowFail
        if ($r.Code -eq 0) { $applied += $batch.Count; continue }
        if ($OnLog) { & $OnLog '  批次失敗，改為逐筆套用...' }
        foreach ($u in $batch) {
            $r1 = Invoke-Git -Repo $Dst -GitArgs @('fetch','--no-tags','--no-recurse-submodules', $Src, ('+' + $u.From + ':' + $u.To)) -AllowFail
            if ($r1.Code -eq 0) { $applied++ }
            else {
                $failed += $u.To
                if ($OnLog) { & $OnLog ("  [失敗，已略過] {0}：{1}" -f $u.To, (@($r1.Lines | Select-Object -Last 1))) }
            }
        }
    }
    return [pscustomobject]@{ Applied = $applied; Failed = $failed }
}

function New-SyncPlan($Src, $Dst, $Options, [scriptblock]$OnLog) {
    # Options: @{ IncludeOrigin=$bool; IncludeHeads=$bool; Recurse=$bool; HeadsPrefix=$string（空白＝預設） }
    $headsPrefix = [string]$Options.HeadsPrefix
    $fatal = $null
    $rootA = try { Get-GitRoot $Src } catch { $fatal = "A：$($_.Exception.Message)" }
    $rootB = try { Get-GitRoot $Dst } catch { if (-not $fatal) { $fatal = "B：$($_.Exception.Message)" } }
    if ($fatal) { return [pscustomobject]@{ Fatal = $fatal; Entries = @(); Skipped = @(); TotalAdd = 0; TotalUpdate = 0; TotalConflict = 0; OriginMismatch = $false } }
    if ((Get-CommonDir $rootA) -eq (Get-CommonDir $rootB)) {
        return [pscustomobject]@{ Fatal = 'A 與 B 共用同一個 Git Repository（Worktree），不需同步 Ref。'; Entries = @(); Skipped = @(); TotalAdd = 0; TotalUpdate = 0; TotalConflict = 0; OriginMismatch = $false }
    }
    $namespaces = @()
    if ($Options.IncludeOrigin) { $namespaces += 'refs/remotes/origin' }
    if ($Options.IncludeHeads)  { $namespaces += 'refs/heads' }
    if (@($namespaces).Count -eq 0) {
        return [pscustomobject]@{ Fatal = '未選擇任何要同步的 Ref 類型。'; Entries = @(); Skipped = @(); TotalAdd = 0; TotalUpdate = 0; TotalConflict = 0; OriginMismatch = $false }
    }
    $urlA = Get-OriginUrl $rootA
    $urlB = Get-OriginUrl $rootB
    $mismatch = ($Options.IncludeOrigin -and ($urlA -ne $urlB))
    $entries = @()
    $skipped = @()
    $planLog = if ($OnLog) { [scriptblock]::Create('param($m) & $OnLog $m') } else { $null }

    $m = Get-RefPairUpdates $rootA $rootB $namespaces $headsPrefix
    $entries += [pscustomobject]@{ Label = '主 Repo'; Src = $rootA; Dst = $rootB; UpdateList = $m.UpdateList; Add = $m.Add; Update = $m.Update; Conflicts = @($m.Conflicts) }
    if ($OnLog) { & $OnLog ("主 Repo：新增 {0}、更新 {1}、衝突略過 {2}" -f $m.Add, $m.Update, @($m.Conflicts).Count) }

    if ($Options.Recurse) {
        $subsA = @(Get-InitializedSubmodulePaths $rootA)
        $subsB = @(Get-InitializedSubmodulePaths $rootB)
        if ($OnLog) { & $OnLog ("A 已初始化 Submodule：{0} 個；B 已初始化：{1} 個" -f $subsA.Count, $subsB.Count) }
        $bMap = @{}
        foreach ($p in $subsB) { $bMap[$p.ToLowerInvariant()] = $p }
        $aSet = @{}
        foreach ($p in $subsA) { $aSet[$p.ToLowerInvariant()] = $true }
        foreach ($p in $subsA) {
            if ($p -like '*/.git/modules/*') { continue }
            $key = $p.ToLowerInvariant()
            if (-not $bMap.ContainsKey($key)) { $skipped += [pscustomobject]@{ Path = $p; Reason = 'Repo B 尚未初始化該 Submodule' }; continue }
            $subA = Join-Path $rootA $p
            $subB = Join-Path $rootB $bMap[$key]
            $ua = Get-OriginUrl $subA
            $ub = Get-OriginUrl $subB
            if ($ua -ne $ub) { $skipped += [pscustomobject]@{ Path = $p; Reason = "兩邊 origin URL 不同（$ua / $ub），避免誤覆蓋" }; continue }
            if ((Get-CommonDir $subA) -eq (Get-CommonDir $subB)) { $skipped += [pscustomobject]@{ Path = $p; Reason = '兩邊共用同一個 Submodule Repo，不需同步' }; continue }
            $sm = Get-RefPairUpdates $subA $subB $namespaces $headsPrefix
            $entries += [pscustomobject]@{ Label = "Submodule: $p"; Src = $subA; Dst = $subB; UpdateList = $sm.UpdateList; Add = $sm.Add; Update = $sm.Update; Conflicts = @($sm.Conflicts) }
            if ($OnLog) { & $OnLog ("[$p] 新增 {0}、更新 {1}、衝突略過 {2}" -f $sm.Add, $sm.Update, @($sm.Conflicts).Count) }
        }
        foreach ($q in $subsB) {
            if ($q -like '*/.git/modules/*') { continue }
            if (-not $aSet.ContainsKey($q.ToLowerInvariant())) { $skipped += [pscustomobject]@{ Path = $q; Reason = 'Repo A 沒有此 Submodule（僅供參考，不影響同步）' } }
        }
    }
    return [pscustomobject]@{
        Fatal = $null
        Entries = $entries
        Skipped = $skipped
        OriginMismatch = $mismatch
        OriginA = $urlA
        OriginB = $urlB
        TotalAdd = (@($entries | ForEach-Object { $_.Add }) | Measure-Object -Sum).Sum
        TotalUpdate = (@($entries | ForEach-Object { $_.Update }) | Measure-Object -Sum).Sum
        TotalConflict = (@($entries | ForEach-Object { @($_.Conflicts).Count }) | Measure-Object -Sum).Sum
    }
}

function Get-FetchTargets([string]$Repo, [bool]$Recurse) {
    $targets = @([pscustomobject]@{ Label = '主 Repo'; Path = $Repo })
    if ($Recurse) {
        foreach ($p in @(Get-InitializedSubmodulePaths $Repo)) {
            $targets += [pscustomobject]@{ Label = "Submodule: $p"; Path = (Join-Path $Repo $p) }
        }
    }
    return $targets
}

function Test-WorktreeRequest($Source, $Parent, $FolderName, $Branch, $StartingPoint) {
    $items = @()
    $target = $null
    $ok = $true
    try {
        $root = Get-GitRoot $Source
        $items += [pscustomobject]@{ Check = '來源 Repo 有效'; Ok = $true; Msg = $root }
    } catch {
        $items += [pscustomobject]@{ Check = '來源 Repo 有效'; Ok = $false; Msg = $_.Exception.Message }
        return [pscustomobject]@{ Items = $items; Target = $null; AllOk = $false; Warnings = @() }
    }
    if ([string]::IsNullOrWhiteSpace($FolderName)) { $FolderName = (Split-Path $root -Leaf) + '-worktree' }
    $nameBad = ($FolderName -eq '.' -or $FolderName -eq '..' -or $FolderName -match '[\\/:*?"<>|]' -or $FolderName.TrimEnd(' ', '.') -ne $FolderName)
    if ($nameBad) {
        $ok = $false
        $items += [pscustomobject]@{ Check = '新資料夾名稱'; Ok = $false; Msg = '名稱不合法（不可含路徑或特殊字元）' }
    } else {
        $items += [pscustomobject]@{ Check = '新資料夾名稱'; Ok = $true; Msg = $FolderName }
    }
    if (-not $nameBad -and [string]::IsNullOrWhiteSpace($Parent)) {
        $ok = $false
        $items += [pscustomobject]@{ Check = '上層資料夾'; Ok = $false; Msg = '請選擇上層資料夾' }
    } elseif (-not $nameBad) {
        if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
            $ok = $false
            $items += [pscustomobject]@{ Check = '上層資料夾'; Ok = $false; Msg = "不存在：$Parent" }
        } else {
            $target = Join-Path ([System.IO.Path]::GetFullPath($Parent)) $FolderName
            $items += [pscustomobject]@{ Check = '上層資料夾'; Ok = $true; Msg = $Parent }
        }
    }
    if ($target) {
        $exists = Test-Path -LiteralPath $target
        if ($exists) { $ok = $false }
        $items += [pscustomobject]@{ Check = '目標資料夾'; Ok = (-not $exists); Msg = $(if ($exists) { "已存在，避免覆蓋：$target" } else { "可建立：$target" }) }
        $normSrc = $root.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
        $inside = ([System.IO.Path]::GetFullPath($target)).StartsWith($normSrc, [System.StringComparison]::OrdinalIgnoreCase)
        if ($inside) { $ok = $false }
        $items += [pscustomobject]@{ Check = '不在來源 Repo 內部'; Ok = (-not $inside); Msg = $(if ($inside) { '新 Worktree 不應建立在來源 Repo 內部' } else { 'OK' }) }
    }
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $ok = $false
        $items += [pscustomobject]@{ Check = 'Branch 名稱格式'; Ok = $false; Msg = '不可為空' }
    } else {
        $r = Invoke-Git -Repo $root -GitArgs @('check-ref-format','--branch', $Branch) -AllowFail
        if ($r.Code -ne 0) { $ok = $false }
        $items += [pscustomobject]@{ Check = 'Branch 名稱格式'; Ok = ($r.Code -eq 0); Msg = $(if ($r.Code -eq 0) { $Branch } else { '名稱不合法' }) }
        if ($r.Code -eq 0) {
            $e = Invoke-Git -Repo $root -GitArgs @('show-ref','--verify','--quiet', ('refs/heads/' + $Branch)) -AllowFail
            if ($e.Code -eq 0) {
                $ok = $false
                $items += [pscustomobject]@{ Check = 'Branch 未重複'; Ok = $false; Msg = "Branch 已存在：$Branch" }
            } else {
                $items += [pscustomobject]@{ Check = 'Branch 未重複'; Ok = $true; Msg = '可使用' }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($StartingPoint)) { $StartingPoint = 'HEAD' }
    $sp = Invoke-Git -Repo $root -GitArgs @('rev-parse','--verify','--quiet', ($StartingPoint + '^{commit}')) -AllowFail
    if ($sp.Code -ne 0) {
        $ok = $false
        $items += [pscustomobject]@{ Check = '起始 Ref'; Ok = $false; Msg = "不是有效 Commit：$StartingPoint" }
    } else {
        $items += [pscustomobject]@{ Check = '起始 Ref'; Ok = $true; Msg = (($sp.Lines | Select-Object -First 1) + "（$StartingPoint）") }
    }
    $warnings = @()
    $gm = Invoke-Git -Repo $root -GitArgs @('cat-file','-e', ($StartingPoint + ':.gitmodules')) -AllowFail
    if ($gm.Code -eq 0) {
        $warnings += '起始 Commit 含 .gitmodules：Git 對 Worktree + Submodule 多重 Checkout 支援不完整；建立後不會自動初始化 Submodule。'
    }
    return [pscustomobject]@{ Items = $items; Target = $target; AllOk = ($ok -and $target); Warnings = $warnings; Source = $root }
}

function Browse-Filesystem([string]$Path, [switch]$Scan, [int]$Depth, [int]$Limit) {
    $skipped = @('$RECYCLE.BIN','System Volume Information','Windows','Program Files','Program Files (x86)','ProgramData','node_modules','.git','Build','Conf','AppData')
    if ($Scan) {
        # 用 List 與一般迴圈：不可在内部 scriptblock 用 $found +=（作用域會複製，且 @() 加單筆會退化為純量）。
        $found = New-Object 'System.Collections.Generic.List[object]'
        $stack = New-Object 'System.Collections.Generic.Stack[tuple[string,int]]'
        $rootP = try { (Get-Item -LiteralPath $Path).FullName } catch { throw "路徑不存在：$Path" }
        $stack.Push([tuple[string,int]]::new($rootP, 0))
        while ($stack.Count -gt 0 -and $found.Count -lt $Limit) {
            $cur = $stack.Pop()
            foreach ($d in @(Get-ChildItem -LiteralPath $cur.Item1 -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($found.Count -ge $Limit) { break }
                if ($skipped -contains $d.Name) { continue }
                $gm = Join-Path $d.FullName '.git'
                if (Test-Path -LiteralPath $gm) { $found.Add([pscustomobject]@{ path = $d.FullName; name = $d.Name }) | Out-Null }
                if ($cur.Item2 -lt $Depth) { $stack.Push([tuple[string,int]]::new($d.FullName, $cur.Item2 + 1)) }
            }
        }
        return [pscustomobject]@{ repos = @($found.ToArray()) }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $drives = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            [pscustomobject]@{ name = $_.Root; path = $_.Root; hasGit = $false }
        })
        return [pscustomobject]@{ current = ''; parent = $null; items = $drives; truncated = $false }
    }
    $full = try { [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path) } catch { throw "路徑不存在：$Path" }
    $items = @()
    $trunc = $false
    $kids = @(Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue)
    $show = @($kids | Where-Object { $skipped -notcontains $_.Name })
    foreach ($d in @($show | Select-Object -First 500)) {
        $items += [pscustomobject]@{
            name   = $d.Name
            path   = $d.FullName
            hasGit = (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))
        }
    }
    if (@($show).Count -gt 500) { $trunc = $true }
    $parent = $null
    if ($full.Length -gt 3) {
        $p = Split-Path $full -Parent
        if ($p -and $p -ne $full) { $parent = $p }
    }
    return [pscustomobject]@{ current = $full; parent = $parent; items = @($items); truncated = $trunc }
}
