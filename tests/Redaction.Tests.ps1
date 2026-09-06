#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'Redaction.psm1') -Force -DisableNameChecking -Global
    $script:PH = Get-RedactionPlaceholder
}
AfterAll { Remove-Module Redaction -Force -ErrorAction SilentlyContinue }

Describe 'Test-SecretKeyName' {
    It 'flags <Name>' -ForEach @(
        @{ Name = 'password' }, @{ Name = 'Password' }, @{ Name = 'token' }
        @{ Name = 'AZURE_DEVOPS_PAT' }, @{ Name = 'apiKey' }, @{ Name = 'api_key' }
        @{ Name = 'Authorization' }, @{ Name = 'credential' }, @{ Name = 'clientSecret' }
        @{ Name = 'ConnectionString' }, @{ Name = 'privateKey' }
    ) { Test-SecretKeyName -Name $Name | Should -BeTrue }

    It 'does not flag <Name>' -ForEach @(
        @{ Name = 'user' }, @{ Name = 'ProjectRoot' }, @{ Name = 'version' }
        @{ Name = 'packageManager' }, @{ Name = '' }
    ) { Test-SecretKeyName -Name $Name | Should -BeFalse }
}

Describe 'Protect-SecretText' {
    It 'redacts a credential embedded in a URL but keeps the user' {
        $out = Protect-SecretText -Text 'https://hadi:abcd1234@dev.azure.com/org/_git/repo'
        $out | Should -Match 'hadi'
        $out | Should -Not -Match 'abcd1234'
        $out | Should -Match ([regex]::Escape($script:PH))
    }

    It 'redacts an Authorization header including the scheme value' {
        $out = Protect-SecretText -Text 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig'
        $out | Should -Not -Match 'eyJhbGci'
    }

    It 'redacts <Case>' -ForEach @(
        @{ Case = 'token=abc123def456';                 Secret = 'abc123def456' }
        @{ Case = '{ "apiKey": "sk-live-9999" }';       Secret = 'sk-live-9999' }
        @{ Case = 'PAT: qwertyuiopasdfghjklzxcvbnmqwertyuiopasdfghjklzxcvbnmqw'; Secret = 'qwertyuiop' }
        @{ Case = 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'; Secret = 'ghp_ABCDEFGH' }
        @{ Case = 'client_secret = "shhh-very-secret"';   Secret = 'shhh-very-secret' }
    ) {
        (Protect-SecretText -Text $Case) | Should -Not -Match ([regex]::Escape($Secret))
    }

    It 'leaves harmless text alone' {
        $text = 'Running uv sync in /home/user/project'
        Protect-SecretText -Text $text | Should -Be $text
    }

    It 'handles empty and null input without throwing' {
        Protect-SecretText -Text '' | Should -Be ''
        { Protect-SecretText -Text $null } | Should -Not -Throw
    }
}

Describe 'Protect-SecretObject' {
    It 'redacts by key name at any depth' {
        $o = @{ user = 'hadi'; Password = 'hunter2'; nested = @{ AZURE_DEVOPS_PAT = 'xyz'; keep = 'ok' } }
        $r = Protect-SecretObject -InputObject $o
        $r['user'] | Should -Be 'hadi'
        $r['Password'] | Should -Be $script:PH
        $r['nested']['AZURE_DEVOPS_PAT'] | Should -Be $script:PH
        $r['nested']['keep'] | Should -Be 'ok'
    }

    It 'still redacts a credential URL under an innocent key' {
        $r = Protect-SecretObject -InputObject @{ remote = 'https://u:p4ss@host/x.git' }
        $r['remote'] | Should -Not -Match 'p4ss'
    }

    It 'walks arrays' {
        $r = Protect-SecretObject -InputObject @{ items = @('safe', 'token=leaky') }
        ($r['items'] -join ' ') | Should -Not -Match 'leaky'
    }

    It 'redacts PSCustomObject properties' {
        $r = Protect-SecretObject -InputObject ([pscustomobject]@{ Name = 'x'; ApiKey = 'secret' })
        $r.Name | Should -Be 'x'
        $r.ApiKey | Should -Be $script:PH
    }

    It 'preserves non-string scalars' {
        $r = Protect-SecretObject -InputObject @{ count = 5; flag = $true }
        $r['count'] | Should -Be 5
        $r['flag'] | Should -BeTrue
    }

    It 'stops at the depth limit instead of recursing forever' {
        $deep = @{ a = @{ b = @{ c = @{ d = 'x' } } } }
        $r = Protect-SecretObject -InputObject $deep -Depth 2
        ($r | ConvertTo-Json -Depth 8) | Should -Match 'TRUNCATED'
    }
}

Describe 'Protect-SecretFile' {
    It 'writes a redacted copy and leaves the original untouched' {
        $src = Join-Path $TestDrive 'log.ndjson'
        $dst = Join-Path $TestDrive 'log.redacted.ndjson'
        Set-Content -LiteralPath $src -Value '{"url":"https://u:SECRET99@host","token":"tok123"}' -Encoding UTF8

        Protect-SecretFile -SourcePath $src -DestinationPath $dst -Confirm:$false | Should -BeTrue
        (Get-Content -LiteralPath $src -Raw) | Should -Match 'SECRET99'
        (Get-Content -LiteralPath $dst -Raw) | Should -Not -Match 'SECRET99'
        (Get-Content -LiteralPath $dst -Raw) | Should -Not -Match 'tok123'
    }

    It 'returns false for a missing source' {
        Protect-SecretFile -SourcePath (Join-Path $TestDrive 'nope.txt') -DestinationPath (Join-Path $TestDrive 'x.txt') -Confirm:$false |
            Should -BeFalse
    }
}
