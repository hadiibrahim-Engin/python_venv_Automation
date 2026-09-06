#Requires -Version 5.1
# =============================================================================
# Module  : GitSync.psm1
# Purpose : Safe, conflict-avoiding Git synchronization before setup starts.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitProcess {
<#
.SYNOPSIS
    Executes git with captured output and a hard timeout.

.DESCRIPTION
    Internal helper used by Invoke-SafeGitPull. It deliberately does not use
    shell invocation, so repository paths and Git output are not interpreted as
    PowerShell expressions. A timed-out process is terminated and reported as
    an error.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string[]] $Arguments,

        [Parameter()]
        [ValidateRange(1, 120)]
        [int] $TimeoutSeconds = 10,

        [Parameter()]
        [switch] $AllowFailure
    )

    $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCommand) {
        throw 'Git executable was not found on PATH.'
    }

    $safeArgs = @($Arguments | ForEach-Object {
        $arg = [string]$_
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '\"') + '"'
        } else {
            $arg
        }
    })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gitCommand.Source
    $psi.Arguments = ($safeArgs -join ' ')
    $psi.WorkingDirectory = $RepositoryPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Failed to start git command: git $($Arguments -join ' ')"
        }

        # Consume both redirected streams concurrently to avoid pipe deadlocks.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            throw ("Git command timed out after {0}s: git {1}" -f $TimeoutSeconds, ($Arguments -join ' '))
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = [int]$process.ExitCode

        $result = [pscustomobject]@{
            ExitCode  = $exitCode
            Succeeded = ($exitCode -eq 0)
            StdOut    = if ($null -ne $stdout) { $stdout.TrimEnd() } else { '' }
            StdErr    = if ($null -ne $stderr) { $stderr.TrimEnd() } else { '' }
        }

        if (-not $result.Succeeded -and -not $AllowFailure) {
            $details = if ($result.StdErr) { $result.StdErr } else { $result.StdOut }
            $suffix = if ($details) { ": $details" } else { '' }
            throw ("Git command failed with exit code {0}: git {1}{2}" -f $exitCode, ($Arguments -join ' '), $suffix)
        }

        return $result
    }
    finally {
        $process.Dispose()
    }
}

function New-GitSyncResult {
    param(
        [string] $Status,
        [string] $RepositoryRoot,
        [string] $Branch,
        [string] $Upstream,
        [int] $Ahead = 0,
        [int] $Behind = 0,
        [bool] $Dirty = $false,
        [bool] $Changed = $false,
        [string] $Message = '',
        [string] $RecoveryRef = $null
    )

    [pscustomobject]@{
        Status         = $Status
        RepositoryRoot = $RepositoryRoot
        Branch         = $Branch
        Upstream       = $Upstream
        Ahead          = $Ahead
        Behind         = $Behind
        Dirty          = $Dirty
        Changed        = $Changed
        Message        = $Message
        RecoveryRef    = $RecoveryRef
    }
}

<#
.SYNOPSIS
    Records the current HEAD under refs/devsetup-backup/<timestamp>.

.DESCRIPTION
    `git reset --hard` discards local commits and leaves them reachable only
    through the reflog, which expires. Writing a real ref first makes the
    pre-reset state recoverable with a plain `git reset --hard <ref>`.

    Returns the ref name, or $null when HEAD could not be resolved. Failing to
    create the backup ref is fatal: the caller must not perform a destructive
    reset without a recovery point.
#>
function New-GitRecoveryRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter()][int] $TimeoutSeconds = 10
    )

    $headProbe = Invoke-GitProcess -RepositoryPath $RepositoryRoot -Arguments @('rev-parse', 'HEAD') -TimeoutSeconds $TimeoutSeconds -AllowFailure
    if (-not $headProbe.Succeeded -or [string]::IsNullOrWhiteSpace($headProbe.StdOut)) {
        return $null
    }
    $head = $headProbe.StdOut.Trim()

    $refName = 'refs/devsetup-backup/{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $update = Invoke-GitProcess -RepositoryPath $RepositoryRoot -Arguments @('update-ref', $refName, $head) -TimeoutSeconds $TimeoutSeconds -AllowFailure
    if (-not $update.Succeeded) {
        throw ("GitSync could not create the recovery ref '{0}'; refusing to run a destructive reset." -f $refName)
    }

    return $refName
}

function Invoke-SafeGitPull {
<#
.SYNOPSIS
    Safely synchronizes a Git working tree with its configured upstream.

.DESCRIPTION
    Performs a bounded `git fetch`, determines ahead/behind state, protects
    local changes, and only performs a normal update using `git pull --ff-only`.

    The default behaviour is deliberately conservative: when local changes are
    present, synchronization is skipped with a warning. Diverged branches are
    never merged automatically.

    `git reset --hard <upstream>` is only reachable when -Force is explicitly
    supplied by the caller. Untracked files are never deleted automatically;
    after a forced reset they are re-checked and cause the operation to stop if
    they could still interfere with synchronization.

.PARAMETER RepositoryPath
    Repository or subdirectory to inspect. Defaults to the current directory.

.PARAMETER SkipIfDirty
    When true (default), a dirty working tree causes Git synchronization to be
    skipped with a warning. When false, a dirty working tree throws instead.

.PARAMETER Force
    Explicitly permits destructive alignment with the upstream using
    `git reset --hard`. This may discard tracked local modifications and local
    commits. It never runs `git clean` and therefore never deletes untracked
    files.

.PARAMETER TimeoutSeconds
    Timeout for Git operations. Defaults to 10 seconds, including `git fetch`.

.EXAMPLE
    Invoke-SafeGitPull -RepositoryPath 'C:\src\my-project'

    Fetches and fast-forwards only when safe. Dirty repositories are skipped.

.EXAMPLE
    Invoke-SafeGitPull -RepositoryPath 'C:\src\my-project' -SkipIfDirty:$false

    Fails instead of silently continuing when local changes exist.

.EXAMPLE
    Invoke-SafeGitPull -RepositoryPath 'C:\src\my-project' -Force -WhatIf

    Shows whether a destructive reset or fast-forward would be attempted,
    without mutating Git state.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryPath = (Get-Location).Path,

        [Parameter()]
        [bool] $SkipIfDirty = $true,

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [ValidateRange(1, 120)]
        [int] $TimeoutSeconds = 10
    )

    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        throw "Repository path does not exist or is not a directory: $RepositoryPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $RepositoryPath).Path

    $repoProbe = Invoke-GitProcess -RepositoryPath $resolvedPath -Arguments @('rev-parse', '--show-toplevel') -TimeoutSeconds $TimeoutSeconds -AllowFailure
    if (-not $repoProbe.Succeeded -or [string]::IsNullOrWhiteSpace($repoProbe.StdOut)) {
        Write-Warning "GitSync: '$resolvedPath' is not inside a Git repository. Git synchronization skipped."
        return New-GitSyncResult -Status 'NotGitRepository' -RepositoryRoot $resolvedPath -Message 'Path is not a Git repository.'
    }

    $repoRoot = $repoProbe.StdOut.Trim()

    $branchProbe = Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -TimeoutSeconds $TimeoutSeconds -AllowFailure
    $branch = if ($branchProbe.Succeeded) { $branchProbe.StdOut.Trim() } else { '' }
    if (-not $branch -or $branch -eq 'HEAD') {
        Write-Warning 'GitSync: repository is in detached HEAD state. Automatic pull skipped.'
        return New-GitSyncResult -Status 'DetachedHead' -RepositoryRoot $repoRoot -Branch $branch -Message 'Detached HEAD has no safe branch target.'
    }

    # Fetch mutates remote-tracking refs, so it participates in ShouldProcess.
    # In -WhatIf mode we intentionally inspect the currently cached refs only.
    if ($PSCmdlet.ShouldProcess($repoRoot, 'git fetch --prune')) {
        Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('fetch', '--prune') -TimeoutSeconds $TimeoutSeconds | Out-Null
    }

    $upstreamProbe = Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -TimeoutSeconds $TimeoutSeconds -AllowFailure
    if (-not $upstreamProbe.Succeeded -or [string]::IsNullOrWhiteSpace($upstreamProbe.StdOut)) {
        Write-Warning ("GitSync: branch '{0}' has no configured upstream. Automatic pull skipped." -f $branch)
        return New-GitSyncResult -Status 'NoUpstream' -RepositoryRoot $repoRoot -Branch $branch -Message 'Current branch has no configured upstream.'
    }
    $upstream = $upstreamProbe.StdOut.Trim()

    $statusProbe = Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('status', '--porcelain') -TimeoutSeconds $TimeoutSeconds
    $dirty = -not [string]::IsNullOrWhiteSpace($statusProbe.StdOut)

    $countProbe = Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('rev-list', '--left-right', '--count', ("HEAD...{0}" -f $upstream)) -TimeoutSeconds $TimeoutSeconds
    $counts = @($countProbe.StdOut.Trim() -split '\s+')
    if ($counts.Count -lt 2) {
        throw "GitSync could not parse ahead/behind counts from: '$($countProbe.StdOut)'"
    }

    $ahead = 0
    $behind = 0
    if (-not [int]::TryParse($counts[0], [ref]$ahead) -or -not [int]::TryParse($counts[1], [ref]$behind)) {
        throw "GitSync received invalid ahead/behind counts from git: '$($countProbe.StdOut)'"
    }

    if ($behind -eq 0) {
        $status = if ($ahead -gt 0) { 'Ahead' } else { 'UpToDate' }
        return New-GitSyncResult -Status $status -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead $ahead -Behind $behind -Dirty $dirty -Message 'No remote fast-forward is required.'
    }

    if ($dirty -and -not $Force) {
        $message = ("Local changes detected while branch '{0}' is {1} commit(s) behind '{2}'." -f $branch, $behind, $upstream)
        if ($SkipIfDirty) {
            Write-Warning ("GitSync: {0} Pull skipped to protect local work." -f $message)
            return New-GitSyncResult -Status 'SkippedDirty' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead $ahead -Behind $behind -Dirty $true -Message $message
        }
        throw ("GitSync refused to pull: {0} Commit/stash local changes, use -SkipIfDirty, or explicitly use -Force." -f $message)
    }

    if ($ahead -gt 0 -and -not $Force) {
        $message = ("Branch '{0}' has diverged from '{1}' (ahead {2}, behind {3})." -f $branch, $upstream, $ahead, $behind)
        Write-Warning ("GitSync: {0} Automatic merge is disabled; synchronize manually or explicitly use -Force." -f $message)
        return New-GitSyncResult -Status 'Diverged' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead $ahead -Behind $behind -Dirty $dirty -Message $message
    }

    if ($Force) {
        $action = "git reset --hard $upstream"
        if ($PSCmdlet.ShouldProcess($repoRoot, $action)) {
            Write-Warning ("GitSync: -Force explicitly supplied. Tracked local changes/commits may be discarded by '{0}'." -f $action)

            # Make the pre-reset state recoverable by a real ref, not just the
            # reflog (which expires). Created before anything destructive runs.
            $recoveryRef = New-GitRecoveryRef -RepositoryRoot $repoRoot -TimeoutSeconds $TimeoutSeconds
            if ($recoveryRef) {
                Write-Warning ("GitSync: previous HEAD saved as '{0}'. Recover with: git reset --hard {0}" -f $recoveryRef)
            }

            Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('reset', '--hard', $upstream) -TimeoutSeconds $TimeoutSeconds | Out-Null

            # Deliberately do not run git clean. Untracked files are user data.
            $postResetStatus = Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('status', '--porcelain') -TimeoutSeconds $TimeoutSeconds
            if (-not [string]::IsNullOrWhiteSpace($postResetStatus.StdOut)) {
                throw ("GitSync forced reset completed, but untracked or otherwise outstanding files remain. No git clean was performed; resolve them manually. Previous HEAD is preserved at '{0}'." -f $recoveryRef)
            }

            return New-GitSyncResult -Status 'ForceReset' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead 0 -Behind 0 -Dirty $false -Changed $true -Message "Repository reset to $upstream." -RecoveryRef $recoveryRef
        }

        return New-GitSyncResult -Status 'WhatIfForceReset' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead $ahead -Behind $behind -Dirty $dirty -Changed $false -Message "Would reset repository to $upstream."
    }

    if ($PSCmdlet.ShouldProcess($repoRoot, "git pull --ff-only $upstream")) {
        Invoke-GitProcess -RepositoryPath $repoRoot -Arguments @('pull', '--ff-only') -TimeoutSeconds $TimeoutSeconds | Out-Null
        return New-GitSyncResult -Status 'FastForwarded' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead 0 -Behind 0 -Dirty $false -Changed $true -Message "Fast-forwarded $branch to $upstream."
    }

    return New-GitSyncResult -Status 'WhatIfFastForward' -RepositoryRoot $repoRoot -Branch $branch -Upstream $upstream -Ahead $ahead -Behind $behind -Dirty $dirty -Changed $false -Message "Would fast-forward $branch to $upstream."
}

Export-ModuleMember -Function Invoke-SafeGitPull, New-GitRecoveryRef
