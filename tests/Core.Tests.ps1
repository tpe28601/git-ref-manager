# Pester 5：Invoke-Pester -Path tests
BeforeAll {
    . (Join-Path $PSScriptRoot '..\GitRefCore.ps1')
}

Describe 'Get-OrdinalSortedNames' {
    It '以 Ordinal 排序（大寫在小寫之前）' {
        $r = Get-OrdinalSortedNames @('refs/heads/aa', 'refs/heads/B')
        $r[0] | Should -BeExactly 'refs/heads/B'
        $r[1] | Should -BeExactly 'refs/heads/aa'
    }
    It '只差大小寫的名稱都保留' {
        $r = Get-OrdinalSortedNames @('refs/heads/x', 'refs/heads/X', 'refs/heads/x')
        $r.Count | Should -Be 2
    }
    It '單一元素時仍回傳陣列' {
        $r = Get-OrdinalSortedNames @('refs/heads/only')
        ,$r | Should -BeOfType [string[]]
        $r.Count | Should -Be 1
    }
    It '空清單回傳空陣列' {
        $r = Get-OrdinalSortedNames @()
        $r.Count | Should -Be 0
    }
}

Describe 'Find-RefConflicts' {
    BeforeAll {
        $names = Get-OrdinalSortedNames @('refs/heads/aa', 'refs/heads/B/child')
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($n in $names) { [void]$set.Add($n) }
        $script:names = $names
        $script:set = $set
    }
    It '找得到反向 D/F 衝突（目的端已有子分支）——舊版會漏掉' {
        $u = @([pscustomobject]@{ From = 'x'; To = 'refs/heads/B'; ObjectId = '0'; Action = '新增' })
        $r = Find-RefConflicts $u $script:names $script:set
        @($r.Conflicts).Count | Should -Be 1
        @($r.Clean).Count | Should -Be 0
    }
    It '找得到正向 D/F 衝突（上層路徑已是 ref）' {
        $u = @([pscustomobject]@{ From = 'x'; To = 'refs/heads/aa/new'; ObjectId = '0'; Action = '新增' })
        $r = Find-RefConflicts $u $script:names $script:set
        @($r.Conflicts).Count | Should -Be 1
    }
    It '沒有衝突時放行' {
        $u = @([pscustomobject]@{ From = 'x'; To = 'refs/heads/c'; ObjectId = '0'; Action = '新增' })
        $r = Find-RefConflicts $u $script:names $script:set
        @($r.Clean).Count | Should -Be 1
    }
}

Describe 'Get-RepoSummary（submodule 單趟掃描）' {
    # git 偵測放 Describe 主體：-Skip: 在 discovery 階段求值，放 BeforeAll(run) 會永遠跳過
    $script:HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    BeforeAll {
        function script:GitInit([string]$Dir) {
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            git -C $Dir init -q 2>&1 | Out-Null
            git -C $Dir config user.email test@example.com
            git -C $Dir config user.name Tester
            git -C $Dir config commit.gpgsign false
        }
        function script:GitCommitFile([string]$Repo, [string]$Name) {
            Set-Content -Path (Join-Path $Repo $Name) -Value $Name
            git -C $Repo add -A 2>&1 | Out-Null
            git -C $Repo commit -q -m $Name 2>&1 | Out-Null
        }
    }

    It '無 .gitmodules：submodule 計數 0，commonDir 有值' -Skip:(-not $script:HasGit) {
        $main = Join-Path $TestDrive plain
        GitInit $main
        GitCommitFile $main 'a.txt'
        $s = Get-RepoSummary $main
        $s.ok | Should -BeTrue
        $s.submodules.total | Should -Be 0
        $s.submodules.initialized | Should -Be 0
        @($s.submodulePaths).Count | Should -Be 0
        $s.commonDir | Should -Not -BeNullOrEmpty
    }

    It '頂層＋巢狀 Submodule：total 只計頂層，paths 完整遞迴' -Skip:(-not $script:HasGit) {
        $src1 = Join-Path $TestDrive src1
        GitInit $src1; GitCommitFile $src1 's.txt'
        $main = Join-Path $TestDrive main2
        GitInit $main; GitCommitFile $main 'm.txt'
        git -c protocol.file.allow=always -C $main submodule add -f $src1 sub1 2>&1 | Out-Null
        git -C $main commit -q -m add-sub1 2>&1 | Out-Null
        $sub1Dir = Join-Path $main 'sub1'
        Test-Path -LiteralPath $sub1Dir | Should -BeTrue   # add 失敗就直接失敗，別讓斷言變成假通過
        $src2 = Join-Path $TestDrive src2
        GitInit $src2; GitCommitFile $src2 'n.txt'
        git -c protocol.file.allow=always -C $sub1Dir submodule add -f $src2 sub2 2>&1 | Out-Null
        git -C $sub1Dir commit -q -m add-sub2 2>&1 | Out-Null
        git -C $main add -A 2>&1 | Out-Null
        git -C $main commit -q -m bump-sub1 2>&1 | Out-Null
        $s = Get-RepoSummary $main
        $s.ok | Should -BeTrue
        $s.submodules.total | Should -Be 1          # 巢狀 sub1/sub2 不列入頂層計數
        $s.submodules.initialized | Should -Be 1
        $paths = @($s.submodulePaths | ForEach-Object { $_.path })
        $paths | Should -Contain 'sub1'
        ($paths | Where-Object { $_ -match 'sub1/sub2' }).Count | Should -Be 1
    }

    It '未初始化的 Submodule：計入 total 不計入 initialized' -Skip:(-not $script:HasGit) {
        $src = Join-Path $TestDrive src3
        GitInit $src; GitCommitFile $src 's.txt'
        $main = Join-Path $TestDrive main4
        GitInit $main; GitCommitFile $main 'm.txt'
        git -c protocol.file.allow=always -C $main submodule add -f $src sub1 2>&1 | Out-Null
        git -C $main commit -q -m add 2>&1 | Out-Null
        git -C $main submodule deinit -f sub1 2>&1 | Out-Null
        $s = Get-RepoSummary $main
        $s.submodules.total | Should -Be 1
        $s.submodules.initialized | Should -Be 0
        @($s.submodulePaths)[0].initialized | Should -BeFalse
    }
}

Describe '驗證摘要 TTL 快取' {
    It '大小寫／尾斜線歸一化後命中' {
        $c = New-SummaryCache 60
        Set-CachedSummary $c ([pscustomobject]@{ ok = $true; path = 'C:\Repos\Mix' })
        $hit = Get-CachedSummary $c 'C:\repos\mix\'
        $hit.path | Should -BeExactly 'C:\Repos\Mix'
    }
    It '失敗摘要不進快取（重試即時重掃）' {
        $c = New-SummaryCache 60
        Set-CachedSummary $c ([pscustomobject]@{ ok = $false; path = 'C:\Repos\Bad' })
        Get-CachedSummary $c 'C:\Repos\Bad' | Should -BeNullOrEmpty
    }
    It 'TTL 到期後不再命中' {
        $c = New-SummaryCache -1
        Set-CachedSummary $c ([pscustomobject]@{ ok = $true; path = 'C:\Repos\Old' })
        Get-CachedSummary $c 'C:\Repos\Old' | Should -BeNullOrEmpty
    }
    It '空路徑不進快取' {
        $c = New-SummaryCache 60
        Set-CachedSummary $c ([pscustomobject]@{ ok = $true; path = '   ' })
        Get-CachedSummary $c '' | Should -BeNullOrEmpty
    }
}
