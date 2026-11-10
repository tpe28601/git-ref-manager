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
