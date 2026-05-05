#!/usr/bin/env pwsh
# Windows / PowerShell equivalent of extension/build-wasm.sh.
# Builds the browser-wasm bundle into extension/dist/.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

if (-not (Get-Command wasm-pack -ErrorAction SilentlyContinue)) {
    Write-Error "wasm-pack is required. Install it with 'cargo install wasm-pack' or from https://rustwasm.github.io/wasm-pack/installer/"
    exit 1
}

$S2TData = Join-Path $RepoRoot "src\engine\s2t_data.rs"
if (-not (Test-Path $S2TData)) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        Write-Error "Python is required to generate $S2TData. Install Python 3 and re-run."
        exit 1
    }
    & $python.Source (Join-Path $RepoRoot "scripts\gen-s2t-tables.py")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & rustfmt $S2TData
}

$wasmTargets = (& rustup target list --installed) -split "`r?`n"
if ($wasmTargets -notcontains "wasm32-unknown-unknown") {
    & rustup target add wasm32-unknown-unknown
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& wasm-pack build "$RepoRoot" `
    --target web `
    --out-dir extension/dist `
    --out-name zhtw_mcp_wasm `
    --no-opt `
    --no-default-features `
    --features browser-wasm
exit $LASTEXITCODE
