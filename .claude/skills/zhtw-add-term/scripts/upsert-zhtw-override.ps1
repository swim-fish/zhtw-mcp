param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $From,

    [string[]] $To = @(),

    [Parameter(Mandatory = $true)]
    [string] $Context,

    [string] $Type = "cross_strait",

    [string[]] $Exceptions = @(),

    [switch] $Disabled,

    [string] $Path
)

$ErrorActionPreference = "Stop"

function Get-ZhtwConfigRoot {
    if ($env:XDG_CONFIG_HOME -and [System.IO.Path]::IsPathRooted($env:XDG_CONFIG_HOME)) {
        return $env:XDG_CONFIG_HOME
    }

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return (Join-Path $env:HOME "Library/Application Support")
    }

    return (Join-Path $env:HOME ".config")
}

function Test-Utf8Bom {
    param([Parameter(Mandatory = $true)][string] $FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    return $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
}

if (-not $Path) {
    $Path = Join-Path (Get-ZhtwConfigRoot) "zhtw-mcp/overrides.json"
}
$Path = [System.IO.Path]::GetFullPath($Path)

$validTypes = @(
    "political_coloring",
    "cross_strait",
    "typo",
    "confusable",
    "variant",
    "ai_filler",
    "translationese"
)

if ($validTypes -notcontains $Type) {
    throw "Invalid rule type '$Type'. Valid types: $($validTypes -join ', ')"
}

if (-not $Disabled -and $To.Count -eq 0) {
    throw "-To requires at least one suggestion unless -Disabled is used."
}

foreach ($exception in $Exceptions) {
    if (-not $exception.Contains($From)) {
        throw "Exception '$exception' must contain the source term '$From'."
    }
}

$parent = Split-Path -Parent $Path
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

if (Test-Path -LiteralPath $Path) {
    if (Test-Utf8Bom -FilePath $Path) {
        throw "Refusing to edit '$Path' because it has a UTF-8 BOM."
    }

    $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ([int]$doc.schema_version -ne 3) {
        throw "Refusing to edit '$Path': schema_version must be 3."
    }

    $spelling = @($doc.spelling | Where-Object { $_.from -ne $From })
    $caseRules = @($doc.case)
} else {
    $spelling = @()
    $caseRules = @()
}

$rule = [ordered] @{
    from = $From
    to = [string[]]$To
    type = $Type
    context = $Context
}

if ($Disabled) {
    $rule.to = [string[]]@()
    $rule.disabled = $true
} elseif ($Exceptions.Count -gt 0) {
    $rule.exceptions = [string[]]$Exceptions
}

$spelling += [pscustomobject] $rule

$out = [ordered] @{
    schema_version = 3
    spelling = @($spelling)
    case = @($caseRules)
}

$json = $out | ConvertTo-Json -Depth 8
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fileName = Split-Path -Leaf $Path
$tempPath = Join-Path $parent ".$fileName.$PID.$([guid]::NewGuid().ToString('N')).tmp"

try {
    [System.IO.File]::WriteAllText(
        $tempPath,
        $json + [Environment]::NewLine,
        $utf8NoBom
    )

    if (Test-Utf8Bom -FilePath $tempPath) {
        throw "Temporary output unexpectedly contains a UTF-8 BOM."
    }

    $verified = Get-Content -Raw -LiteralPath $tempPath | ConvertFrom-Json
    if ([int]$verified.schema_version -ne 3) {
        throw "Temporary output has an invalid schema_version."
    }

    if (Test-Path -LiteralPath $Path) {
        $timestamp = Get-Date -Format "yyyyMMddTHHmmssfff"
        $backupPath = "$Path.user-edit.$timestamp.bak"
        [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
    } else {
        [System.IO.File]::Move($tempPath, $Path)
    }
} finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }
}

Write-Output $Path
