param(
    [Parameter(Mandatory = $true)]
    [string] $From,

    [Parameter(Mandatory = $true)]
    [string[]] $To,

    [Parameter(Mandatory = $true)]
    [string] $Context,

    [string] $Type = "cross_strait",

    [string[]] $Exceptions = @(),

    [string] $Path = (Join-Path $env:APPDATA "zhtw-mcp\overrides.json")
)

$ErrorActionPreference = "Stop"

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

if ($To.Count -eq 0) {
    throw "-To requires at least one suggestion."
}

$parent = Split-Path -Parent $Path
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

if (Test-Path -LiteralPath $Path) {
    $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $schemaVersion = if ($null -ne $doc.schema_version) { [int] $doc.schema_version } else { 3 }
    $spelling = @($doc.spelling | Where-Object { $_.from -ne $From })
    $caseRules = @($doc.case)
} else {
    $schemaVersion = 3
    $spelling = @()
    $caseRules = @()
}

$rule = [ordered] @{
    from = $From
    to = [string[]] $To
    type = $Type
    context = $Context
}

if ($Exceptions.Count -gt 0) {
    $rule.exceptions = [string[]] $Exceptions
}

$spelling += [pscustomobject] $rule

$out = [ordered] @{
    schema_version = $schemaVersion
    spelling = @($spelling)
    case = @($caseRules)
}

$json = $out | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Write-Output $Path
