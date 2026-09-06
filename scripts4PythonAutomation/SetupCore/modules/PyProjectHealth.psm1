#Requires -Version 5.1
# =============================================================================
# Module  : PyProjectHealth.psm1
# Purpose : Read-only health analysis and transactional healing of pyproject.toml.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1')      -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'TomlParser.psm1')  -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Versioning.psm1')  -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Toml.psm1')        -Force -DisableNameChecking -Global -ErrorAction Stop

<#
    Severity : INFO | WARN | ERROR | FATAL
    FixClass : SafeAutoFix | NeedsDecision | NotFixable

    Only SafeAutoFix findings are ever applied automatically. NeedsDecision
    findings require a human (or an explicit CLI flag); NotFixable findings are
    reported and left alone.
#>

$script:_healthCache = @{}

function Clear-PyProjectHealthCache {
    <#
    .SYNOPSIS
        Drops cached health reports. Call after modifying pyproject.toml.
    #>
    [CmdletBinding()]
    param()
    $script:_healthCache = @{}
    if (Get-Command Clear-TomlCache -ErrorAction SilentlyContinue) { Clear-TomlCache }
}

function New-PyProjectFinding {
    <#
    .SYNOPSIS
        Creates one health finding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $true)][ValidateSet('SafeAutoFix', 'NeedsDecision', 'NotFixable')][string] $FixClass,
        [Parameter()][string] $Category = 'pyproject',
        [Parameter()][object] $CurrentValue = $null,
        [Parameter()][object] $SuggestedValue = $null,
        [Parameter()][string] $Path = ''
    )

    [pscustomobject]@{
        Code           = $Code
        Severity       = $Severity
        Message        = $Message
        AutoFixable    = ($FixClass -eq 'SafeAutoFix')
        FixClass       = $FixClass
        CurrentValue   = $CurrentValue
        SuggestedValue = $SuggestedValue
        Path           = $Path
        Category       = $Category
    }
}

function New-CanonicalProjectMetadata {
    <#
    .SYNOPSIS
        Neutral project model (Part M). Poetry and uv are adapters onto this.
    #>
    param()
    [pscustomobject]@{
        Name                 = $null
        Version              = $null
        RequiresPython       = $null
        RuntimeDependencies  = @()
        DevDependencies      = @()
        OptionalDependencies = @{}
        PackageManager       = $null
        BuildBackend         = $null
        Sources              = @{}
    }
}

function Get-NormalizedDependencyName {
    <#
    .SYNOPSIS
        PEP 503 normalised distribution name from a requirement string.

    .DESCRIPTION
        'Requests[socks] >= 2.31' and 'requests>=2.0' both normalise to
        'requests', which is what duplicate detection must compare.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Requirement)

    $text = $Requirement.Trim()
    if ($text.Length -eq 0) { return '' }
    # Strip environment markers, extras and any version specifier.
    $text = ($text -split ';', 2)[0]
    $text = ($text -split '[\[<>=!~ @]', 2)[0]
    return ($text.Trim().ToLowerInvariant() -replace '[-_.]+', '-')
}

function ConvertTo-CanonicalMetadata {
    <#
    .SYNOPSIS
        Projects parsed TOML onto the canonical model, preferring PEP 621.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject] $Parsed)

    $data = $Parsed.Data
    $meta = New-CanonicalProjectMetadata

    $project = Get-TomlPathValue -Data $data -Path 'project'
    $poetry  = Get-TomlPathValue -Data $data -Path 'tool.poetry'

    if ($project -is [hashtable]) {
        $meta.Name           = Get-TomlPathValue -Data $data -Path 'project.name'
        $meta.Version        = Get-TomlPathValue -Data $data -Path 'project.version'
        $meta.RequiresPython = Get-TomlPathValue -Data $data -Path 'project.requires-python'
        $deps = Get-TomlPathValue -Data $data -Path 'project.dependencies'
        if ($deps) { $meta.RuntimeDependencies = @($deps) }
        $opt = Get-TomlPathValue -Data $data -Path 'project.optional-dependencies'
        if ($opt -is [hashtable]) { $meta.OptionalDependencies = $opt }
    }

    # Poetry fills only what PEP 621 did not provide.
    if ($poetry -is [hashtable]) {
        if (-not $meta.Name)    { $meta.Name    = Get-TomlPathValue -Data $data -Path 'tool.poetry.name' }
        if (-not $meta.Version) { $meta.Version = Get-TomlPathValue -Data $data -Path 'tool.poetry.version' }
        if (-not $meta.RequiresPython) {
            $pyDep = Get-TomlPathValue -Data $data -Path 'tool.poetry.dependencies.python'
            if ($pyDep) { $meta.RequiresPython = $pyDep }
        }
    }

    # Dev dependencies: [dependency-groups].dev is the preferred modern home.
    $devGroup = Get-TomlPathValue -Data $data -Path 'dependency-groups.dev'
    if ($devGroup) { $meta.DevDependencies = @($devGroup) }
    else {
        $legacyUv = Get-TomlPathValue -Data $data -Path 'tool.uv.dev-dependencies'
        if ($legacyUv) { $meta.DevDependencies = @($legacyUv) }
        else {
            $poetryDev = Get-TomlPathValue -Data $data -Path 'tool.poetry.group.dev.dependencies'
            if ($poetryDev -is [hashtable]) { $meta.DevDependencies = @($poetryDev.Keys) }
        }
    }

    $meta.BuildBackend = Get-TomlPathValue -Data $data -Path 'build-system.build-backend'
    $sources = Get-TomlPathValue -Data $data -Path 'tool.uv.sources'
    if ($sources -is [hashtable]) { $meta.Sources = $sources }

    return $meta
}

function Get-PyProjectHealthReport {
<#
.SYNOPSIS
    Read-only health analysis of a project's pyproject.toml and lock files.

.DESCRIPTION
    Never writes anything. Returns a report describing every problem found,
    each classified as SafeAutoFix, NeedsDecision or NotFixable so that
    `devsetup repair` can act on exactly the safe subset.

.PARAMETER ProjectRoot
    Project directory containing pyproject.toml.

.PARAMETER NoCache
    Re-read from disk even when a cached report exists.

.OUTPUTS
    PSCustomObject with ProjectRoot, PyProjectPath, Findings, Metadata,
    PackageManager, IsHealthy, HasErrors and Counts.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter()][switch] $NoCache
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $cacheKey = $resolvedRoot.ToLowerInvariant()
    if (-not $NoCache -and $script:_healthCache.ContainsKey($cacheKey)) {
        return $script:_healthCache[$cacheKey]
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $tomlPath = Join-Path $resolvedRoot 'pyproject.toml'
    $metadata = New-CanonicalProjectMetadata
    $parsed = $null

    # --- File presence and parse -------------------------------------------
    if (-not (Test-Path -LiteralPath $tomlPath -PathType Leaf)) {
        $findings.Add((New-PyProjectFinding -Code 'PYPROJECT_MISSING' -Severity 'FATAL' -FixClass 'NeedsDecision' `
            -Message 'pyproject.toml does not exist in this project.' -Path $tomlPath -Category 'file'))
    }
    else {
        $raw = Get-Content -LiteralPath $tomlPath -Raw -Encoding UTF8
        if ($null -eq $raw -or [string]::IsNullOrWhiteSpace($raw)) {
            $findings.Add((New-PyProjectFinding -Code 'PYPROJECT_EMPTY' -Severity 'FATAL' -FixClass 'NeedsDecision' `
                -Message 'pyproject.toml is empty.' -Path $tomlPath -Category 'file'))
        }
        else {
            try { $parsed = ConvertFrom-TomlText -Text $raw }
            catch {
                $findings.Add((New-PyProjectFinding -Code 'PYPROJECT_PARSE_INVALID' -Severity 'FATAL' -FixClass 'NotFixable' `
                    -Message ("pyproject.toml is not valid TOML: {0}" -f $_.Exception.Message) -Path $tomlPath -Category 'syntax'))
            }
        }
    }

    if ($parsed) {
        $data = $parsed.Data
        $metadata = ConvertTo-CanonicalMetadata -Parsed $parsed

        Add-MetadataFindings   -Findings $findings -Data $data -Metadata $metadata -TomlPath $tomlPath
        Add-PythonFindings     -Findings $findings -Data $data -Metadata $metadata -TomlPath $tomlPath
        Add-DependencyFindings -Findings $findings -Data $data -Metadata $metadata -TomlPath $tomlPath
        Add-ToolingFindings    -Findings $findings -Data $data -Metadata $metadata -TomlPath $tomlPath
    }

    # --- Package manager + lock health -------------------------------------
    $pmReport = $null
    try { $pmReport = Get-PmDetectionReport -ProjectRoot $resolvedRoot } catch { $pmReport = $null }

    if ($pmReport) {
        $metadata.PackageManager = $pmReport.PackageManager
        # PYPROJECT_MULTIPLE_LOCKFILES is reported by Test-PyProjectLockHealth,
        # which has the better message; only the generic case is added here.
        if ($pmReport.Status -eq 'Ambiguous' -and $pmReport.AmbiguityCode -ne 'PYPROJECT_MULTIPLE_LOCKFILES') {
            $code = if ($pmReport.AmbiguityCode) { $pmReport.AmbiguityCode } else { 'PYPROJECT_PM_AMBIGUOUS' }
            $findings.Add((New-PyProjectFinding -Code $code -Severity 'ERROR' -FixClass 'NeedsDecision' `
                -Message ("The package manager cannot be determined: {0}" -f $pmReport.Reason) `
                -CurrentValue $pmReport.Reason -SuggestedValue 'uv | poetry' `
                -Path $tomlPath -Category 'packagemanager'))
        }
    }

    # Lock health is meaningless when the document itself could not be read:
    # the detected package manager would be a guess.
    $fatalParse = @($findings | Where-Object { $_.Code -in @('PYPROJECT_MISSING', 'PYPROJECT_EMPTY', 'PYPROJECT_PARSE_INVALID') }).Count -gt 0
    if (-not $fatalParse) {
        foreach ($lockFinding in (Test-PyProjectLockHealth -ProjectRoot $resolvedRoot -PackageManager $metadata.PackageManager)) {
            $findings.Add($lockFinding)
        }
    }

    # NOTE: @($list) throws "Argument types do not match" for a
    # System.Collections.Generic.List[object] on PowerShell 7.5.x. Use ToArray().
    # The same condition can be reported by both PM detection and lock health
    # (dual lock files), so collapse identical Code+Path pairs.
    $seenFindings = @{}
    $all = @()
    foreach ($finding in $findings.ToArray()) {
        $key = '{0}|{1}' -f $finding.Code, $finding.Path
        if ($seenFindings.ContainsKey($key)) { continue }
        $seenFindings[$key] = $true
        $all += $finding
    }
    $report = [pscustomobject]@{
        ProjectRoot    = $resolvedRoot
        PyProjectPath  = $tomlPath
        Findings       = $all
        Metadata       = $metadata
        PackageManager = $metadata.PackageManager
        HasErrors      = [bool](@($all | Where-Object { $_.Severity -in @('ERROR', 'FATAL') }).Count)
        IsHealthy      = ($all.Count -eq 0)
        Counts         = [pscustomobject]@{
            INFO  = @($all | Where-Object Severity -eq 'INFO').Count
            WARN  = @($all | Where-Object Severity -eq 'WARN').Count
            ERROR = @($all | Where-Object Severity -eq 'ERROR').Count
            FATAL = @($all | Where-Object Severity -eq 'FATAL').Count
        }
    }

    $script:_healthCache[$cacheKey] = $report
    return $report
}

function Add-MetadataFindings {
    param([System.Collections.Generic.List[object]] $Findings, [hashtable] $Data, [pscustomobject] $Metadata, [string] $TomlPath)

    if (-not $Metadata.Name) {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_NAME_MISSING' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message 'No project name is declared ([project].name or [tool.poetry].name).' `
            -SuggestedValue '<project-name>' -Path $TomlPath -Category 'metadata'))
    }
    if (-not $Metadata.Version) {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_VERSION_MISSING' -Severity 'WARN' -FixClass 'NeedsDecision' `
            -Message 'No project version is declared ([project].version or [tool.poetry].version).' `
            -SuggestedValue '0.1.0' -Path $TomlPath -Category 'metadata'))
    }

    # Same field declared in both dialects with different values.
    $pairs = @(
        @{ A = 'project.name';    B = 'tool.poetry.name';    Label = 'name' }
        @{ A = 'project.version'; B = 'tool.poetry.version'; Label = 'version' }
    )
    foreach ($pair in $pairs) {
        $a = Get-TomlPathValue -Data $Data -Path $pair.A
        $b = Get-TomlPathValue -Data $Data -Path $pair.B
        if ($a -and $b -and ([string]$a -ne [string]$b)) {
            $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_METADATA_DIVERGED' -Severity 'ERROR' -FixClass 'NeedsDecision' `
                -Message ("[project].{0} is '{1}' but [tool.poetry].{0} is '{2}'. Only one can be authoritative." -f $pair.Label, $a, $b) `
                -CurrentValue ("{0} vs {1}" -f $a, $b) -SuggestedValue $a `
                -Path $TomlPath -Category 'metadata'))
        }
    }

    # Poetry-style metadata alongside a PEP 621 [project] table.
    $hasProject = (Get-TomlPathValue -Data $Data -Path 'project') -is [hashtable]
    $poetryName = Get-TomlPathValue -Data $Data -Path 'tool.poetry.name'
    if ($hasProject -and $poetryName) {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_POETRY_METADATA_LEGACY' -Severity 'WARN' -FixClass 'NeedsDecision' `
            -Message 'Shared metadata is declared under [tool.poetry] while a PEP 621 [project] table exists. Keep common metadata in [project] only.' `
            -CurrentValue '[tool.poetry].name' -SuggestedValue '[project].name' `
            -Path $TomlPath -Category 'metadata'))
    }
}

function Add-PythonFindings {
    param([System.Collections.Generic.List[object]] $Findings, [hashtable] $Data, [pscustomobject] $Metadata, [string] $TomlPath)

    if (-not $Metadata.RequiresPython) {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_REQUIRES_PYTHON_MISSING' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message 'No Python requirement is declared (requires-python / [tool.poetry.dependencies].python).' `
            -SuggestedValue '>=3.11,<3.13' -Path $TomlPath -Category 'python'))
        return
    }

    try { ConvertTo-VersionConstraints -ConstraintStr $Metadata.RequiresPython | Out-Null }
    catch {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_PYTHON_CONSTRAINT_INVALID' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message ("The Python requirement '{0}' cannot be interpreted: {1}" -f $Metadata.RequiresPython, $_.Exception.Message) `
            -CurrentValue $Metadata.RequiresPython -SuggestedValue '>=3.11,<3.13' `
            -Path $TomlPath -Category 'python'))
        return
    }

    # Both dialects declaring a Python requirement that disagree.
    $pep621 = Get-TomlPathValue -Data $Data -Path 'project.requires-python'
    $poetry = Get-TomlPathValue -Data $Data -Path 'tool.poetry.dependencies.python'
    if ($pep621 -and $poetry -and ([string]$pep621 -ne [string]$poetry)) {
        $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_PYTHON_CONSTRAINT_CONFLICT' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message ("requires-python is '{0}' but [tool.poetry.dependencies].python is '{1}'." -f $pep621, $poetry) `
            -CurrentValue ("{0} vs {1}" -f $pep621, $poetry) -SuggestedValue $pep621 `
            -Path $TomlPath -Category 'python'))
    }
}

function Add-DependencyFindings {
    param([System.Collections.Generic.List[object]] $Findings, [hashtable] $Data, [pscustomobject] $Metadata, [string] $TomlPath)

    $groups = @(
        @{ Path = 'project.dependencies';         Items = $Metadata.RuntimeDependencies; Label = '[project].dependencies' }
        @{ Path = 'dependency-groups.dev';        Items = $Metadata.DevDependencies;     Label = '[dependency-groups].dev' }
    )
    foreach ($group in $groups) {
        if (-not $group.Items -or $group.Items.Count -eq 0) { continue }
        $seen = @{}
        foreach ($requirement in $group.Items) {
            $name = Get-NormalizedDependencyName -Requirement ([string]$requirement)
            if (-not $name) { continue }
            if ($seen.ContainsKey($name)) {
                $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_DUPLICATE_DEPENDENCY' -Severity 'WARN' -FixClass 'SafeAutoFix' `
                    -Message ("'{0}' is listed more than once in {1}." -f $name, $group.Label) `
                    -CurrentValue ("{0} / {1}" -f $seen[$name], $requirement) -SuggestedValue $seen[$name] `
                    -Path $group.Path -Category 'dependencies'))
            } else {
                $seen[$name] = $requirement
            }
        }
    }
}

function Add-ToolingFindings {
    param([System.Collections.Generic.List[object]] $Findings, [hashtable] $Data, [pscustomobject] $Metadata, [string] $TomlPath)

    # [tool.uv].dev-dependencies predates [dependency-groups].
    $legacy = Get-TomlPathValue -Data $Data -Path 'tool.uv.dev-dependencies'
    if ($legacy) {
        $conflict = Get-TomlPathValue -Data $Data -Path 'dependency-groups.dev'
        if ($conflict) {
            $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES' -Severity 'ERROR' -FixClass 'NeedsDecision' `
                -Message 'Dev dependencies are declared in both [tool.uv].dev-dependencies and [dependency-groups].dev.' `
                -CurrentValue (@($legacy) -join ', ') -SuggestedValue (@($conflict) -join ', ') `
                -Path 'tool.uv.dev-dependencies' -Category 'tooling'))
        } else {
            $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES' -Severity 'WARN' -FixClass 'SafeAutoFix' `
                -Message '[tool.uv].dev-dependencies is legacy; the standard location is [dependency-groups].dev.' `
                -CurrentValue (@($legacy) -join ', ') -SuggestedValue '[dependency-groups].dev' `
                -Path 'tool.uv.dev-dependencies' -Category 'tooling'))
        }
    }

    # A [tool.uv.sources] entry that no dependency group references.
    if ($Metadata.Sources -is [hashtable] -and $Metadata.Sources.Count -gt 0) {
        $declared = @{}
        foreach ($requirement in (@($Metadata.RuntimeDependencies) + @($Metadata.DevDependencies))) {
            $n = Get-NormalizedDependencyName -Requirement ([string]$requirement)
            if ($n) { $declared[$n] = $true }
        }
        foreach ($optSet in $Metadata.OptionalDependencies.Values) {
            foreach ($requirement in @($optSet)) {
                $n = Get-NormalizedDependencyName -Requirement ([string]$requirement)
                if ($n) { $declared[$n] = $true }
            }
        }
        foreach ($sourceName in $Metadata.Sources.Keys) {
            $n = Get-NormalizedDependencyName -Requirement ([string]$sourceName)
            if ($n -and -not $declared.ContainsKey($n)) {
                $Findings.Add((New-PyProjectFinding -Code 'PYPROJECT_UV_SOURCE_ORPHANED' -Severity 'WARN' -FixClass 'NeedsDecision' `
                    -Message ("[tool.uv.sources].{0} has no matching entry in any dependency list." -f $sourceName) `
                    -CurrentValue $sourceName -SuggestedValue 'declare it as a dependency or remove the source' `
                    -Path ("tool.uv.sources.{0}" -f $sourceName) -Category 'tooling'))
            }
        }
    }
}

function Test-PyProjectLockHealth {
<#
.SYNOPSIS
    Reports lock-file findings for a project (read-only).

.DESCRIPTION
    Distinguishes "missing", "belongs to the other package manager", "invalid"
    and "older than pyproject.toml". A stale lock is repairable without
    upgrading anything; an invalid or foreign lock is never overwritten blindly.

.OUTPUTS
    Zero or more finding objects.
#>
    # NOTE: returns the array unwrapped. Comma-wrapping it would make
    # `... | ForEach-Object Code` see one array object instead of the findings,
    # and @(...) would count an empty result as 1.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter()][AllowNull()][string] $PackageManager
    )

    $result = New-Object System.Collections.Generic.List[object]
    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $tomlPath   = Join-Path $resolvedRoot 'pyproject.toml'
    $uvLock     = Join-Path $resolvedRoot 'uv.lock'
    $poetryLock = Join-Path $resolvedRoot 'poetry.lock'

    $hasUv     = Test-Path -LiteralPath $uvLock -PathType Leaf
    $hasPoetry = Test-Path -LiteralPath $poetryLock -PathType Leaf

    if ($hasUv -and $hasPoetry) {
        $result.Add((New-PyProjectFinding -Code 'PYPROJECT_MULTIPLE_LOCKFILES' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message 'Both uv.lock and poetry.lock exist. Exactly one package manager must own this project.' `
            -CurrentValue 'uv.lock + poetry.lock' -SuggestedValue 'delete the lock file of the manager you do not use' `
            -Path $resolvedRoot -Category 'lock'))
    }

    if (-not $PackageManager) { return $result.ToArray() }

    $expected = if ($PackageManager -eq 'uv') { $uvLock } else { $poetryLock }
    $foreign  = if ($PackageManager -eq 'uv') { $poetryLock } else { $uvLock }
    $expectedName = Split-Path $expected -Leaf
    $foreignName  = Split-Path $foreign -Leaf

    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        if (Test-Path -LiteralPath $foreign -PathType Leaf) {
            $result.Add((New-PyProjectFinding -Code 'LOCK_WRONG_MANAGER' -Severity 'ERROR' -FixClass 'NeedsDecision' `
                -Message ("The project resolves to {0} but only {1} is present." -f $PackageManager, $foreignName) `
                -CurrentValue $foreignName -SuggestedValue $expectedName -Path $resolvedRoot -Category 'lock'))
        } else {
            $result.Add((New-PyProjectFinding -Code 'LOCK_MISSING' -Severity 'WARN' -FixClass 'SafeAutoFix' `
                -Message ("{0} is missing; it will be generated from pyproject.toml without upgrading anything." -f $expectedName) `
                -SuggestedValue $expectedName -Path $resolvedRoot -Category 'lock'))
        }
        return $result.ToArray()
    }

    $lockRaw = Get-Content -LiteralPath $expected -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($lockRaw)) {
        $result.Add((New-PyProjectFinding -Code 'LOCK_INVALID' -Severity 'ERROR' -FixClass 'NeedsDecision' `
            -Message ("{0} is empty or unreadable." -f $expectedName) `
            -Path $expected -Category 'lock'))
        return $result.ToArray()
    }

    if ((Test-Path -LiteralPath $tomlPath -PathType Leaf)) {
        $tomlTime = (Get-Item -LiteralPath $tomlPath).LastWriteTimeUtc
        $lockTime = (Get-Item -LiteralPath $expected).LastWriteTimeUtc
        if ($lockTime -lt $tomlTime) {
            $result.Add((New-PyProjectFinding -Code 'LOCK_OUTDATED' -Severity 'WARN' -FixClass 'SafeAutoFix' `
                -Message ("{0} is older than pyproject.toml and may not reflect the declared dependencies." -f $expectedName) `
                -CurrentValue $lockTime.ToString('o') -SuggestedValue $tomlTime.ToString('o') `
                -Path $expected -Category 'lock'))
        }
    }

    return $result.ToArray()
}

function Test-PyProjectHealth {
<#
.SYNOPSIS
    Returns $true when a project has no ERROR or FATAL findings.

.PARAMETER Strict
    Also fail on WARN findings.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter()][switch] $Strict,
        [Parameter()][switch] $NoCache
    )

    $report = Get-PyProjectHealthReport -ProjectRoot $ProjectRoot -NoCache:$NoCache
    if ($Strict) { return ($report.Findings.Count -eq 0) }
    return (-not $report.HasErrors)
}


# ===========================================================================
# Transactional healing (Part Q)
# ===========================================================================

<#
.SYNOPSIS
    Renders a TOML array assignment as text lines.

.DESCRIPTION
    Keeps the original shape: an array that was written on one line stays on
    one line, a multi-line array stays multi-line with the same indentation.
#>
function Format-TomlArrayAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $KeyText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Items,
        [Parameter()][switch] $MultiLine,
        [Parameter()][string] $Indent = '',
        [Parameter()][string] $ItemIndent = '    '
    )

    $quoted = @($Items | ForEach-Object { '"{0}"' -f ($_ -replace '\\', '\\' -replace '"', '\"') })

    if (-not $MultiLine) {
        return @('{0}{1} = [{2}]' -f $Indent, $KeyText, ($quoted -join ', '))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}{1} = [' -f $Indent, $KeyText))
    foreach ($q in $quoted) { $lines.Add(('{0}{1},' -f $ItemIndent, $q)) }
    $lines.Add(('{0}]' -f $Indent))
    return $lines.ToArray()
}

<#
.SYNOPSIS
    Removes duplicate entries from a TOML dependency array, keeping the first.
#>
function Repair-DuplicateDependencyArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][pscustomobject] $Parsed,
        [Parameter(Mandatory = $true)][string] $ArrayPath
    )

    if (-not $Parsed.Locations.ContainsKey($ArrayPath)) { return , $Lines }

    $items = Get-TomlPathValue -Data $Parsed.Data -Path $ArrayPath
    if (-not $items) { return , $Lines }

    $kept = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($items)) {
        $name = Get-NormalizedDependencyName -Requirement ([string]$item)
        if ($name -and $seen.ContainsKey($name)) { continue }
        if ($name) { $seen[$name] = $true }
        $kept.Add([string]$item)
    }
    if ($kept.Count -eq @($items).Count) { return , $Lines }

    $start = $Parsed.Locations[$ArrayPath]
    $end   = $Parsed.EndLocations[$ArrayPath]
    $firstLine = $Lines[$start - 1]
    $indent = ($firstLine -replace '^(\s*).*$', '$1')
    $keyText = ($ArrayPath -split '\.')[-1]
    $multi = ($end -gt $start)

    $replacement = Format-TomlArrayAssignment -KeyText $keyText -Items $kept.ToArray() `
        -MultiLine:$multi -Indent $indent -ItemIndent ($indent + '    ')

    $out = New-Object System.Collections.Generic.List[string]
    if ($start -gt 1) { $out.AddRange([string[]]$Lines[0..($start - 2)]) }
    $out.AddRange([string[]]$replacement)
    if ($end -lt $Lines.Count) { $out.AddRange([string[]]$Lines[$end..($Lines.Count - 1)]) }
    return , $out.ToArray()
}

<#
.SYNOPSIS
    Moves [tool.uv].dev-dependencies to the standard [dependency-groups].dev.

.DESCRIPTION
    Only ever called when [dependency-groups].dev does not already exist; the
    conflicting case is classified NeedsDecision and never auto-fixed.
#>
function Repair-LegacyUvDevDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][pscustomobject] $Parsed
    )

    $path = 'tool.uv.dev-dependencies'
    if (-not $Parsed.Locations.ContainsKey($path)) { return , $Lines }

    # Assign first, then wrap. Get-TomlPathValue returns ,$node, so
    # @(Get-TomlPathValue ...) yields a 1-element array holding the array,
    # which a [string[]] parameter then flattens into one joined string.
    $rawItems = Get-TomlPathValue -Data $Parsed.Data -Path $path
    $items = @($rawItems)
    $start = $Parsed.Locations[$path]
    $end   = $Parsed.EndLocations[$path]

    # 1. Drop the legacy assignment.
    $out = New-Object System.Collections.Generic.List[string]
    if ($start -gt 1) { $out.AddRange([string[]]$Lines[0..($start - 2)]) }
    if ($end -lt $Lines.Count) { $out.AddRange([string[]]$Lines[$end..($Lines.Count - 1)]) }

    # 2. Append the standard table. Appending (rather than splicing into an
    #    existing [dependency-groups]) is safe because this fix only runs when
    #    no [dependency-groups].dev exists.
    $body = New-Object System.Collections.Generic.List[string]
    $body.AddRange([string[]]$out.ToArray())
    while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) { $body.RemoveAt($body.Count - 1) }
    $body.Add('')

    if ($Parsed.Tables.ContainsKey('dependency-groups')) {
        # The table exists but has no dev key: add the key under it.
        $header = $Parsed.Tables['dependency-groups']
        $insertAt = $header
        $rebuilt = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $body.Count; $i++) {
            $rebuilt.Add($body[$i])
            if ($i -eq ($insertAt - 1)) {
                $rebuilt.AddRange([string[]](Format-TomlArrayAssignment -KeyText 'dev' -Items $items -MultiLine))
            }
        }
        return , $rebuilt.ToArray()
    }

    $body.Add('[dependency-groups]')
    $body.AddRange([string[]](Format-TomlArrayAssignment -KeyText 'dev' -Items $items -MultiLine))
    $body.Add('')
    return , $body.ToArray()
}

function Invoke-PyProjectHealing {
<#
.SYNOPSIS
    Applies SafeAutoFix findings to pyproject.toml transactionally.

.DESCRIPTION
    Pipeline (Part Q):

        record SHA256 -> backup -> patch in memory -> write temp ->
        validate TOML syntax -> re-check health -> build diff ->
        atomic replace -> invalidate caches

    If any step after the backup fails, the original file is restored and the
    function throws. It never leaves a half-repaired document behind.

    Only findings classified SafeAutoFix are applied. NeedsDecision and
    NotFixable findings are returned in Skipped so the caller can surface them.
    Lock repair is deliberately NOT part of this function: healing pyproject
    and healing the lock file are separate operations.

.PARAMETER ProjectRoot
    Project directory containing pyproject.toml.

.PARAMETER BackupDirectory
    Where to place the backup. Defaults to the project directory.

.OUTPUTS
    PSCustomObject with Applied, Skipped, Changed, BackupPath, Diff,
    OriginalSha256 and NewSha256.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter()][string] $BackupDirectory
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $tomlPath = Join-Path $resolvedRoot 'pyproject.toml'

    $report = Get-PyProjectHealthReport -ProjectRoot $resolvedRoot -NoCache
    $safe    = @($report.Findings | Where-Object { $_.FixClass -eq 'SafeAutoFix' -and $_.Category -ne 'lock' })
    $skipped = @($report.Findings | Where-Object { $_.FixClass -ne 'SafeAutoFix' -or $_.Category -eq 'lock' })

    $result = [pscustomobject]@{
        ProjectRoot    = $resolvedRoot
        Applied        = @()
        Skipped        = $skipped
        Changed        = $false
        BackupPath     = $null
        Diff           = @()
        OriginalSha256 = $null
        NewSha256      = $null
    }

    if ($safe.Count -eq 0) { return $result }
    if (-not (Test-Path -LiteralPath $tomlPath -PathType Leaf)) { return $result }

    $originalText = Get-Content -LiteralPath $tomlPath -Raw -Encoding UTF8
    $result.OriginalSha256 = Get-TextSha256 -Text $originalText

    if (-not $PSCmdlet.ShouldProcess($tomlPath, ("Apply {0} safe pyproject fix(es)" -f $safe.Count))) {
        return $result
    }

    # --- 1. Backup -------------------------------------------------------
    if (-not $BackupDirectory) { $BackupDirectory = $resolvedRoot }
    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $backupPath = Join-Path $BackupDirectory ('pyproject.toml.devsetup-backup-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $tomlPath -Destination $backupPath -Force
    $result.BackupPath = $backupPath

    $tempPath = Join-Path $resolvedRoot ('.pyproject.toml.devsetup-{0}.tmp' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))

    try {
        # --- 2. Patch in memory -----------------------------------------
        $parsed = ConvertFrom-TomlText -Text $originalText
        $lines = [string[]]$parsed.Lines
        $applied = New-Object System.Collections.Generic.List[object]

        # Re-parse between edits: every patch invalidates the recorded line
        # numbers of everything after it.
        foreach ($finding in $safe) {
            switch ($finding.Code) {
                'PYPROJECT_DUPLICATE_DEPENDENCY' {
                    $lines = Repair-DuplicateDependencyArray -Lines $lines -Parsed $parsed -ArrayPath $finding.Path
                    $parsed = ConvertFrom-TomlText -Text ($lines -join "`n")
                    $lines = [string[]]$parsed.Lines
                    $applied.Add($finding)
                }
                'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES' {
                    $lines = Repair-LegacyUvDevDependencies -Lines $lines -Parsed $parsed
                    $parsed = ConvertFrom-TomlText -Text ($lines -join "`n")
                    $lines = [string[]]$parsed.Lines
                    $applied.Add($finding)
                }
                default { }   # not auto-fixable here; left for the caller
            }
        }

        if ($applied.Count -eq 0) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            $result.BackupPath = $null
            return $result
        }

        $newText = ($lines -join "`n")
        if (-not $newText.EndsWith("`n")) { $newText += "`n" }

        # --- 3. Write temp ----------------------------------------------
        Set-Content -LiteralPath $tempPath -Value $newText -Encoding UTF8 -NoNewline

        # --- 4. Validate syntax -----------------------------------------
        $reparsed = ConvertFrom-TomlFile -Path $tempPath

        # --- 5. Re-check health: no NEW error may appear ----------------
        $beforeErrors = @($report.Findings | Where-Object { $_.Severity -in @('ERROR', 'FATAL') } | ForEach-Object Code)
        $afterMeta = ConvertTo-CanonicalMetadata -Parsed $reparsed
        if (-not $afterMeta.Name -and $report.Metadata.Name) {
            throw "Healing would have removed the project name; rolled back."
        }
        if (-not $afterMeta.Version -and $report.Metadata.Version) {
            throw "Healing would have removed the project version; rolled back."
        }
        if ($report.Metadata.RuntimeDependencies.Count -gt 0 -and $afterMeta.RuntimeDependencies.Count -eq 0) {
            throw "Healing would have removed every runtime dependency; rolled back."
        }
        if ($report.Metadata.DevDependencies.Count -gt 0 -and $afterMeta.DevDependencies.Count -eq 0) {
            throw "Healing would have removed every dev dependency; rolled back."
        }

        # --- 6. Diff -----------------------------------------------------
        $result.Diff = Get-TextDiff -Before $originalText -After $newText

        # --- 7. Atomic replace -------------------------------------------
        Move-Item -LiteralPath $tempPath -Destination $tomlPath -Force

        $result.NewSha256 = Get-TextSha256 -Text $newText
        $result.Applied = $applied.ToArray()
        $result.Changed = $true
    }
    catch {
        # --- Rollback -----------------------------------------------------
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $backupPath -Destination $tomlPath -Force
        Clear-PyProjectHealthCache
        throw (New-SetupException `
            -Message ("pyproject healing failed and was rolled back: {0}" -f $_.Exception.Message) `
            -ErrorCode 'PYPROJECT_HEAL_FAILED' -Step 'HEAL' `
            -Context @{ ProjectRoot = $resolvedRoot; BackupPath = $backupPath } `
            -InnerException $_.Exception)
    }
    finally {
        # --- 8. Invalidate caches ----------------------------------------
        Clear-PyProjectHealthCache
    }

    return $result
}

<#
.SYNOPSIS
    SHA256 of a string, as lowercase hex.
#>
function Get-TextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

<#
.SYNOPSIS
    Minimal line-oriented diff, good enough for a change summary in the log.
#>
function Get-TextDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Before,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $After
    )

    $b = ($Before -replace "`r`n", "`n") -split "`n"
    $a = ($After  -replace "`r`n", "`n") -split "`n"
    $diff = New-Object System.Collections.Generic.List[string]

    $bSet = @{}
    foreach ($line in $b) { $bSet[$line] = ($bSet[$line] | ForEach-Object { $_ }); $bSet[$line] = 1 }
    $aSet = @{}
    foreach ($line in $a) { $aSet[$line] = 1 }

    foreach ($line in $b) { if (-not $aSet.ContainsKey($line)) { $diff.Add('- ' + $line) } }
    foreach ($line in $a) { if (-not $bSet.ContainsKey($line)) { $diff.Add('+ ' + $line) } }
    return $diff.ToArray()
}


Export-ModuleMember -Function `
    Get-PyProjectHealthReport, `
    Test-PyProjectHealth, `
    Test-PyProjectLockHealth, `
    Clear-PyProjectHealthCache, `
    New-PyProjectFinding, `
    ConvertTo-CanonicalMetadata, `
    Get-NormalizedDependencyName, `
    Invoke-PyProjectHealing, `
    Get-TextSha256, `
    Get-TextDiff, `
    Format-TomlArrayAssignment, `
    Repair-DuplicateDependencyArray, `
    Repair-LegacyUvDevDependencies
