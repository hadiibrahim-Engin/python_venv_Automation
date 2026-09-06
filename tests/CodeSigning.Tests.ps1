#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $RepoRoot 'scripts4PythonAutomation\SetupCore\modules\CodeSigning.psm1'
    Import-Module $ModulePath -Force -DisableNameChecking
}

AfterAll {
    Remove-Module CodeSigning -Force -ErrorAction SilentlyContinue
}

Describe 'Idempotent code signing' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codesigning-test-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
        $script:DigiCertExe = Join-Path $TempRoot 'DigiCertUtil.exe'
        Set-Content -LiteralPath $DigiCertExe -Value 'fake signer'
    }

    AfterEach {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'skips already valid signatures and does not invoke DigiCert' {
        $file = Join-Path $TempRoot 'already-signed.exe'
        Set-Content -LiteralPath $file -Value 'binary'

        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                StatusMessage = 'Valid signature'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Existing Signer' }
                TimeStamperCertificate = $null
            }
        } -ModuleName CodeSigning

        Mock Invoke-CodeSigner {
            throw 'DigiCert should not be called for an already-valid signature.'
        } -ModuleName CodeSigning

        $result = Set-CodeSignature -DigiCertUtilityExe $DigiCertExe -Files @($file) -Confirm:$false

        $result.Total | Should -Be 1
        $result.Signed | Should -Be 1
        $result.NewlySigned | Should -Be 0
        $result.Skipped | Should -Be 1
        $result.Failed.Count | Should -Be 0
        Assert-MockCalled Invoke-CodeSigner -ModuleName CodeSigning -Times 0
    }

    It 'signs an unsigned file' {
        $file = Join-Path $TempRoot 'unsigned.exe'
        Set-Content -LiteralPath $file -Value 'binary'

        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'NotSigned'
                StatusMessage = 'Not signed'
                SignerCertificate = $null
                TimeStamperCertificate = $null
            }
        } -ModuleName CodeSigning

        Mock Invoke-CodeSigner {
            [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = ''; StdErr = ''; ErrorText = $null }
        } -ModuleName CodeSigning

        $result = Set-CodeSignature -DigiCertUtilityExe $DigiCertExe -Files @($file) -Confirm:$false

        $result.Total | Should -Be 1
        $result.Signed | Should -Be 1
        $result.NewlySigned | Should -Be 1
        $result.Skipped | Should -Be 0
        $result.Failed.Count | Should -Be 0
        Assert-MockCalled Invoke-CodeSigner -ModuleName CodeSigning -Times 1
    }

    It 're-signs a changed file whose previous signature has HashMismatch' {
        $file = Join-Path $TempRoot 'changed.exe'
        Set-Content -LiteralPath $file -Value 'changed binary'

        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'HashMismatch'
                StatusMessage = 'The file hash does not match the signed hash.'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Old Signer' }
                TimeStamperCertificate = $null
            }
        } -ModuleName CodeSigning

        Mock Invoke-CodeSigner {
            [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = ''; StdErr = ''; ErrorText = $null }
        } -ModuleName CodeSigning

        $result = Set-CodeSignature -DigiCertUtilityExe $DigiCertExe -Files @($file) -Confirm:$false

        $result.NewlySigned | Should -Be 1
        $result.Skipped | Should -Be 0
        Assert-MockCalled Invoke-CodeSigner -ModuleName CodeSigning -Times 1
    }

    It 'signs only non-valid files in a mixed venv set' {
        $valid = Join-Path $TempRoot 'valid.exe'
        $unsigned = Join-Path $TempRoot 'unsigned.exe'
        Set-Content -LiteralPath $valid -Value 'valid binary'
        Set-Content -LiteralPath $unsigned -Value 'unsigned binary'

        Mock Get-AuthenticodeSignature {
            param($FilePath)
            if ($FilePath -like '*valid.exe') {
                return [pscustomobject]@{
                    Status = 'Valid'
                    StatusMessage = 'Valid signature'
                    SignerCertificate = [pscustomobject]@{ Subject = 'CN=Existing Signer' }
                    TimeStamperCertificate = $null
                }
            }

            [pscustomobject]@{
                Status = 'NotSigned'
                StatusMessage = 'Not signed'
                SignerCertificate = $null
                TimeStamperCertificate = $null
            }
        } -ModuleName CodeSigning

        Mock Invoke-CodeSigner {
            param($DigiCertUtilityExe, $Files)
            $Files.Count | Should -Be 1
            $Files[0] | Should -Be $unsigned
            [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = ''; StdErr = ''; ErrorText = $null }
        } -ModuleName CodeSigning

        $result = Set-CodeSignature -DigiCertUtilityExe $DigiCertExe -Files @($valid, $unsigned) -Confirm:$false

        $result.Total | Should -Be 2
        $result.Signed | Should -Be 2
        $result.NewlySigned | Should -Be 1
        $result.Skipped | Should -Be 1
        Assert-MockCalled Invoke-CodeSigner -ModuleName CodeSigning -Times 1
    }

    It 'allows explicit ForceResign of a currently valid file' {
        $file = Join-Path $TempRoot 'valid.exe'
        Set-Content -LiteralPath $file -Value 'valid binary'

        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                StatusMessage = 'Valid signature'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Existing Signer' }
                TimeStamperCertificate = $null
            }
        } -ModuleName CodeSigning

        Mock Invoke-CodeSigner {
            [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = ''; StdErr = ''; ErrorText = $null }
        } -ModuleName CodeSigning

        $result = Set-CodeSignature -DigiCertUtilityExe $DigiCertExe -Files @($file) -ForceResign -Confirm:$false

        $result.ForceResign | Should -BeTrue
        $result.NewlySigned | Should -Be 1
        $result.Skipped | Should -Be 0
        Assert-MockCalled Invoke-CodeSigner -ModuleName CodeSigning -Times 1
    }
}
