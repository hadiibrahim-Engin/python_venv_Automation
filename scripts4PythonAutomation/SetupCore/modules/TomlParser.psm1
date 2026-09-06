#Requires -Version 5.1
# =============================================================================
# Module  : TomlParser.psm1
# Purpose : Structure-aware TOML reader for pyproject.toml.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

<#
.SYNOPSIS
    Parses TOML into nested hashtables, recording where each key was defined.

.DESCRIPTION
    Deliberately a SUBSET parser covering what real pyproject.toml files use:
    table headers, array-of-tables, bare/quoted/dotted keys, basic and literal
    strings, multi-line strings, integers, floats, booleans, arrays (including
    multi-line) and inline tables.

    It is fail-closed: anything it cannot interpret raises a SetupException
    with ErrorCode TOML_PARSE_ERROR rather than being skipped, so a healing
    pass never operates on a partially understood document.

    Not supported (and rejected explicitly): dates/times.
#>

function New-TomlParseError {
    param([int] $LineNumber, [string] $Line, [string] $Detail)
    return (New-SetupException `
        -Message ("TOML parse error on line {0}: {1}`n  {2}" -f $LineNumber, $Detail, $Line.Trim()) `
        -ErrorCode 'TOML_PARSE_ERROR' `
        -Step 'METADATA' `
        -Context @{ LineNumber = $LineNumber; Line = $Line; Detail = $Detail })
}

<#
.SYNOPSIS
    Splits a dotted key path into segments, honouring quoted segments.
#>
function Split-TomlKeyPath {
    param([Parameter(Mandatory = $true)][string] $Key, [int] $LineNumber = 0, [string] $Line = '')

    $segments = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inBasic = $false
    $inLiteral = $false

    for ($i = 0; $i -lt $Key.Length; $i++) {
        $ch = $Key[$i]
        if ($inBasic) {
            if ($ch -eq '"') { $inBasic = $false } else { [void]$current.Append($ch) }
        }
        elseif ($inLiteral) {
            if ($ch -eq "'") { $inLiteral = $false } else { [void]$current.Append($ch) }
        }
        elseif ($ch -eq '"')  { $inBasic = $true }
        elseif ($ch -eq "'")  { $inLiteral = $true }
        elseif ($ch -eq '.')  { $segments.Add($current.ToString().Trim()); [void]$current.Clear() }
        else                  { [void]$current.Append($ch) }
    }
    if ($inBasic -or $inLiteral) { throw (New-TomlParseError -LineNumber $LineNumber -Line $Line -Detail 'unterminated quoted key') }
    $segments.Add($current.ToString().Trim())

    foreach ($s in $segments) {
        if ([string]::IsNullOrWhiteSpace($s)) { throw (New-TomlParseError -LineNumber $LineNumber -Line $Line -Detail 'empty key segment') }
    }
    return , $segments.ToArray()
}

<#
.SYNOPSIS
    Finds the index just past a complete scalar/array/inline-table value.
#>
function Get-TomlValueEnd {
    param([string] $Text, [int] $Start)

    $depthArray = 0
    $depthTable = 0
    $i = $Start

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            # Multi-line string?
            if ($i + 2 -lt $Text.Length -and $Text[$i + 1] -eq $quote -and $Text[$i + 2] -eq $quote) {
                $close = $Text.IndexOf(([string]$quote * 3), $i + 3)
                if ($close -lt 0) { return -1 }
                $i = $close + 3
                continue
            }
            $i++
            while ($i -lt $Text.Length -and $Text[$i] -ne $quote) {
                if ($quote -eq '"' -and $Text[$i] -eq '\') { $i++ }
                $i++
            }
            if ($i -ge $Text.Length) { return -1 }
            $i++
            continue
        }
        if ($ch -eq '#' -and $depthArray -eq 0 -and $depthTable -eq 0) { return $i }
        if ($ch -eq '[') { $depthArray++ }
        elseif ($ch -eq ']') { $depthArray--; if ($depthArray -lt 0) { return $i } }
        elseif ($ch -eq '{') { $depthTable++ }
        elseif ($ch -eq '}') { $depthTable--; if ($depthTable -lt 0) { return $i } }
        elseif ($ch -eq "`n" -and $depthArray -eq 0 -and $depthTable -eq 0) { return $i }
        $i++
    }
    if ($depthArray -ne 0 -or $depthTable -ne 0) { return -1 }
    return $i
}

<#
.SYNOPSIS
    Converts a raw TOML value string into a PowerShell value.
#>
function ConvertFrom-TomlValue {
    param([string] $Raw, [int] $LineNumber = 0, [string] $Line = '')

    $text = $Raw.Trim()
    if ($text.Length -eq 0) { throw (New-TomlParseError -LineNumber $LineNumber -Line $Line -Detail 'missing value') }

    # Multi-line strings
    foreach ($q in @('"""', "'''")) {
        if ($text.StartsWith($q) -and $text.EndsWith($q) -and $text.Length -ge 6) {
            $inner = $text.Substring(3, $text.Length - 6)
            if ($inner.StartsWith("`r`n")) { $inner = $inner.Substring(2) } elseif ($inner.StartsWith("`n")) { $inner = $inner.Substring(1) }
            return $inner
        }
    }

    # Basic string
    if ($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) {
        $inner = $text.Substring(1, $text.Length - 2)
        return ($inner -replace '\\n', "`n" -replace '\\t', "`t" -replace '\\r', "`r" -replace '\\"', '"' -replace '\\\\', '\')
    }
    # Literal string
    if ($text.StartsWith("'") -and $text.EndsWith("'") -and $text.Length -ge 2) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text -eq 'true')  { return $true }
    if ($text -eq 'false') { return $false }

    # Array
    if ($text.StartsWith('[') -and $text.EndsWith(']')) {
        $inner = Remove-TomlComments -Text $text.Substring(1, $text.Length - 2)
        $items = Split-TomlList -Text $inner -LineNumber $LineNumber -Line $Line
        $result = @()
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace($item)) { continue }
            $result += , (ConvertFrom-TomlValue -Raw $item -LineNumber $LineNumber -Line $Line)
        }
        return , $result
    }

    # Inline table
    if ($text.StartsWith('{') -and $text.EndsWith('}')) {
        $inner = Remove-TomlComments -Text $text.Substring(1, $text.Length - 2)
        $table = @{}
        foreach ($pair in (Split-TomlList -Text $inner -LineNumber $LineNumber -Line $Line)) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }
            $eq = Get-TomlAssignmentIndex -Text $pair
            if ($eq -lt 0) { throw (New-TomlParseError -LineNumber $LineNumber -Line $Line -Detail 'inline table entry without =') }
            $k = Split-TomlKeyPath -Key $pair.Substring(0, $eq).Trim() -LineNumber $LineNumber -Line $Line
            $v = ConvertFrom-TomlValue -Raw $pair.Substring($eq + 1) -LineNumber $LineNumber -Line $Line
            Set-TomlPathValue -Root $table -Path $k -Value $v
        }
        return $table
    }

    # Numbers (underscores allowed by TOML)
    $numeric = $text -replace '_', ''
    $intVal = 0L
    if ([long]::TryParse($numeric, [ref]$intVal)) { return $intVal }
    $dblVal = 0.0
    if ([double]::TryParse($numeric, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dblVal)) { return $dblVal }

    throw (New-TomlParseError -LineNumber $LineNumber -Line $Line -Detail ("unsupported value '{0}'" -f $text))
}

<#
.SYNOPSIS
    Strips `# ...` comments from TOML text without touching quoted strings.

.DESCRIPTION
    Needed for multi-line arrays and inline tables: a comment between elements
    would otherwise be glued onto the neighbouring item when the list is split.
#>
function Remove-TomlComments {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            [void]$sb.Append($ch); $i++
            while ($i -lt $Text.Length -and $Text[$i] -ne $quote) {
                if ($quote -eq '"' -and $Text[$i] -eq '\' -and $i + 1 -lt $Text.Length) {
                    [void]$sb.Append($Text[$i]); $i++
                }
                [void]$sb.Append($Text[$i]); $i++
            }
            if ($i -lt $Text.Length) { [void]$sb.Append($Text[$i]); $i++ }
            continue
        }
        if ($ch -eq '#') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        [void]$sb.Append($ch); $i++
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
    Splits a comma-separated TOML list, ignoring commas inside nested values.
#>
function Split-TomlList {
    param([string] $Text, [int] $LineNumber = 0, [string] $Line = '')

    $parts = New-Object System.Collections.Generic.List[string]
    $depthArray = 0; $depthTable = 0
    $start = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch; $i++
            while ($i -lt $Text.Length -and $Text[$i] -ne $quote) {
                if ($quote -eq '"' -and $Text[$i] -eq '\') { $i++ }
                $i++
            }
        }
        elseif ($ch -eq '#' -and $depthArray -eq 0 -and $depthTable -eq 0) {
            # Comment inside a multi-line array: skip to end of line.
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
        }
        elseif ($ch -eq '[') { $depthArray++ }
        elseif ($ch -eq ']') { $depthArray-- }
        elseif ($ch -eq '{') { $depthTable++ }
        elseif ($ch -eq '}') { $depthTable-- }
        elseif ($ch -eq ',' -and $depthArray -eq 0 -and $depthTable -eq 0) {
            $parts.Add($Text.Substring($start, $i - $start))
            $start = $i + 1
        }
        $i++
    }
    if ($start -lt $Text.Length) { $parts.Add($Text.Substring($start)) }
    return , $parts.ToArray()
}

<#
.SYNOPSIS
    Index of the '=' that separates a key from its value, ignoring quotes.
#>
function Get-TomlAssignmentIndex {
    param([string] $Text)
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch; $i++
            while ($i -lt $Text.Length -and $Text[$i] -ne $quote) { $i++ }
        }
        elseif ($ch -eq '=') { return $i }
        $i++
    }
    return -1
}

<#
.SYNOPSIS
    Writes a value at a dotted path inside a nested hashtable.
#>
function Set-TomlPathValue {
    param([hashtable] $Root, [string[]] $Path, $Value)
    $node = $Root
    for ($i = 0; $i -lt $Path.Length - 1; $i++) {
        $seg = $Path[$i]
        if (-not $node.ContainsKey($seg) -or -not ($node[$seg] -is [hashtable])) { $node[$seg] = @{} }
        $node = $node[$seg]
    }
    $node[$Path[-1]] = $Value
}

<#
.SYNOPSIS
    Reads a dotted path out of parsed TOML data. Returns $null when absent.
#>
function Get-TomlPathValue {
    param([Parameter(Mandatory = $true)][hashtable] $Data, [Parameter(Mandatory = $true)][string] $Path)
    $node = $Data
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $node -or -not ($node -is [hashtable]) -or -not $node.ContainsKey($seg)) { return $null }
        $node = $node[$seg]
    }
    # Comma-wrap: without it PowerShell unrolls a returned list, so an array
    # value comes back as its elements (or as $null when it is empty).
    return , $node
}

<#
.SYNOPSIS
    Parses TOML text into nested hashtables plus per-key source locations.

.OUTPUTS
    PSCustomObject:
        Data      - nested hashtable of the document
        Locations - hashtable mapping 'dotted.key' -> 1-based line number
        Tables    - hashtable mapping 'dotted.table' -> 1-based header line
#>
function ConvertFrom-TomlText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $data = @{}
    $locations = @{}
    $endLocations = @{}
    $tables = @{}

    $normalized = $Text -replace "`r`n", "`n"
    $lines = $normalized -split "`n"
    $currentPath = @()

    $lineIndex = 0
    while ($lineIndex -lt $lines.Length) {
        $lineNumber = $lineIndex + 1
        $line = $lines[$lineIndex]
        $trimmed = $line.Trim()

        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { $lineIndex++; continue }

        # Array of tables: [[a.b]]
        if ($trimmed -match '^\[\[(.+?)\]\]\s*(#.*)?$') {
            $currentPath = Split-TomlKeyPath -Key $Matches[1].Trim() -LineNumber $lineNumber -Line $line
            $key = $currentPath -join '.'
            $tables[$key] = $lineNumber
            $entry = @{}
            $existing = Get-TomlPathValue -Data $data -Path $key
            if ($existing -is [System.Collections.IList]) {
                $null = $existing.Add($entry)
            } else {
                $list = New-Object System.Collections.ArrayList
                $null = $list.Add($entry)
                Set-TomlPathValue -Root $data -Path $currentPath -Value $list
            }
            $lineIndex++
            continue
        }

        # Table header: [a.b]
        if ($trimmed -match '^\[(.+?)\]\s*(#.*)?$') {
            $currentPath = Split-TomlKeyPath -Key $Matches[1].Trim() -LineNumber $lineNumber -Line $line
            $key = $currentPath -join '.'
            if ($tables.ContainsKey($key)) {
                throw (New-TomlParseError -LineNumber $lineNumber -Line $line -Detail ("table [{0}] is defined more than once" -f $key))
            }
            $tables[$key] = $lineNumber
            if ($null -eq (Get-TomlPathValue -Data $data -Path $key)) {
                Set-TomlPathValue -Root $data -Path $currentPath -Value @{}
            }
            $lineIndex++
            continue
        }

        # key = value (value may span multiple lines)
        $eq = Get-TomlAssignmentIndex -Text $line
        if ($eq -lt 0) {
            throw (New-TomlParseError -LineNumber $lineNumber -Line $line -Detail 'expected a table header or key = value')
        }

        $keyText = $line.Substring(0, $eq).Trim()
        $keyPath = Split-TomlKeyPath -Key $keyText -LineNumber $lineNumber -Line $line

        # Gather the value, pulling in further lines while it stays open.
        $valueText = $line.Substring($eq + 1)
        $consumed = 0
        $end = Get-TomlValueEnd -Text $valueText -Start 0
        while ($end -lt 0) {
            $consumed++
            if ($lineIndex + $consumed -ge $lines.Length) {
                throw (New-TomlParseError -LineNumber $lineNumber -Line $line -Detail 'unterminated value')
            }
            $valueText += "`n" + $lines[$lineIndex + $consumed]
            $end = Get-TomlValueEnd -Text $valueText -Start 0
        }
        $rawValue = $valueText.Substring(0, $end)

        $fullPath = @($currentPath) + @($keyPath)
        $value = ConvertFrom-TomlValue -Raw $rawValue -LineNumber $lineNumber -Line $line

        $target = $data
        if ($currentPath.Length -gt 0) {
            $containerKey = $currentPath -join '.'
            $container = Get-TomlPathValue -Data $data -Path $containerKey
            if ($container -is [System.Collections.IList]) { $target = $container[$container.Count - 1] }
            elseif ($container -is [hashtable]) { $target = $container }
            else { Set-TomlPathValue -Root $data -Path $currentPath -Value @{}; $target = Get-TomlPathValue -Data $data -Path $containerKey }
        }
        Set-TomlPathValue -Root $target -Path $keyPath -Value $value
        $dotted = $fullPath -join '.'
        $locations[$dotted] = $lineNumber
        # Last physical line of the value, so a healing pass can replace the
        # whole span of a multi-line array or string.
        $endLocations[$dotted] = $lineNumber + $consumed

        $lineIndex += 1 + $consumed
    }

    return [pscustomobject]@{
        Data         = $data
        Locations    = $locations
        EndLocations = $endLocations
        Tables       = $tables
        Lines        = $lines
    }
}

<#
.SYNOPSIS
    Reads and parses a TOML file from disk.
#>
function ConvertFrom-TomlFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-SetupException -Message ("TOML file not found: {0}" -f $Path) `
            -ErrorCode 'TOML_FILE_NOT_FOUND' -Step 'METADATA' -Context @{ Path = $Path })
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { $text = '' }
    return ConvertFrom-TomlText -Text $text
}

Export-ModuleMember -Function ConvertFrom-TomlText, ConvertFrom-TomlFile, Get-TomlPathValue, Split-TomlKeyPath
