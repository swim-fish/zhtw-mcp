$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "upsert-zhtw-override.ps1"
$testRoot = Join-Path $env:TEMP "zhtw-add-term-$([guid]::NewGuid().ToString('N'))"
$originalXdgConfigHome = $env:XDG_CONFIG_HOME

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $overridePath = Join-Path $testRoot "explicit/overrides.json"

    & $scriptPath `
        -Path $overridePath `
        -From "code" `
        -To @("program code", "auth code", "source code") `
        -Context "Choose by context." `
        -Exceptions @("error code") | Out-Null

    $doc = Get-Content -Raw -LiteralPath $overridePath | ConvertFrom-Json
    $bytes = [System.IO.File]::ReadAllBytes($overridePath)
    Assert-True ($doc.schema_version -eq 3) "schema_version should be 3"
    Assert-True (@($doc.spelling).Count -eq 1) "the first rule should be added"
    Assert-True (@($doc.spelling[0].to).Count -eq 3) "all candidates should be preserved"
    Assert-True (@($doc.spelling[0].exceptions).Count -eq 1) "exceptions should be preserved"
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "output should not have a UTF-8 BOM"

    & $scriptPath `
        -Path $overridePath `
        -From "source code" `
        -Context "Accepted term." `
        -Disabled | Out-Null

    $doc = Get-Content -Raw -LiteralPath $overridePath | ConvertFrom-Json
    $rawJson = Get-Content -Raw -LiteralPath $overridePath
    $disabledRule = $doc.spelling | Where-Object { $_.from -eq "source code" }
    Assert-True ($disabledRule.disabled -eq $true) "disabled should be true"
    Assert-True (@($disabledRule.to).Count -eq 0) "a disabled rule should have no suggestions"
    Assert-True ($rawJson -match '"to"\s*:\s*\[\]') "a disabled rule should serialize to as an empty array"
    Assert-True (@(Get-ChildItem "$overridePath.user-edit.*.bak").Count -eq 1) "an existing file should be backed up"

    $env:XDG_CONFIG_HOME = Join-Path $testRoot "xdg"
    & $scriptPath -From "term" -To "replacement" -Context "XDG path test." | Out-Null
    $xdgOverridePath = Join-Path $env:XDG_CONFIG_HOME "zhtw-mcp/overrides.json"
    Assert-True (Test-Path -LiteralPath $xdgOverridePath) "an absolute XDG_CONFIG_HOME should take precedence"

    $invalidPath = Join-Path $testRoot "invalid-schema.json"
    [System.IO.File]::WriteAllText(
        $invalidPath,
        '{"schema_version":2,"spelling":[],"case":[]}',
        [System.Text.UTF8Encoding]::new($false)
    )
    $before = [System.IO.File]::ReadAllText($invalidPath)
    $rejected = $false
    try {
        & $scriptPath -Path $invalidPath -From "x" -To "y" -Context "test" | Out-Null
    } catch {
        $rejected = $true
    }
    Assert-True $rejected "an invalid schema should be rejected"
    Assert-True ([System.IO.File]::ReadAllText($invalidPath) -eq $before) "a rejected file should remain unchanged"

    $bomPath = Join-Path $testRoot "bom.json"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bomBytes = [byte[]]@([System.Text.Encoding]::UTF8.GetPreamble()) +
        $utf8.GetBytes('{"schema_version":3,"spelling":[],"case":[]}')
    [System.IO.File]::WriteAllBytes($bomPath, $bomBytes)
    $beforeBom = [System.IO.File]::ReadAllBytes($bomPath)
    $rejected = $false
    try {
        & $scriptPath -Path $bomPath -From "x" -To "y" -Context "test" | Out-Null
    } catch {
        $rejected = $true
    }
    Assert-True $rejected "a UTF-8 BOM should be rejected"
    Assert-True ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bomPath)) -eq [Convert]::ToBase64String($beforeBom)) "a rejected BOM file should remain unchanged"

    $rejected = $false
    try {
        & $scriptPath -Path (Join-Path $testRoot "bad-exception.json") -From "code" -To "program code" -Context "test" -Exceptions "unrelated" | Out-Null
    } catch {
        $rejected = $true
    }
    Assert-True $rejected "an exception that omits the source term should be rejected"

    Write-Output "All upsert-zhtw-override tests passed."
} finally {
    $env:XDG_CONFIG_HOME = $originalXdgConfigHome
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
