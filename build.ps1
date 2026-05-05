#!/usr/bin/env pwsh
<#
.SYNOPSIS
    PowerShell port of the top-level Makefile.

.DESCRIPTION
    Mirrors the targets of `make`:
        all          Generate s2t_data.rs (if missing) and `cargo build --release`.
        clean        `cargo clean`.
        distclean    clean + remove generated s2t_data.rs and data/opencc/.
        check        cargo test, cargo clippy -D warnings, cargo fmt --check,
                     and python scripts/check-ruleset.py --lint.
        check-size   Verify the release binary is <= 20 MiB.
        indent       cargo fmt, python scripts/check-ruleset.py (twice),
                     and black scripts/*.py.
        corpus       cargo test --test corpus-evaluation -- --nocapture.
        install      Build, copy binary to ~/.local/bin, register MCP server
                     with Claude Code (user scope).
        uninstall    Stop running processes, deregister MCP, remove binary.
        status       Report binary, running process, and MCP registration state.
        ext-chrome   Build the Chrome extension WASM bundle into extension/dist/.

    The install/uninstall/status targets are a Windows-native rewrite of
    scripts/deploy.sh (which is bash-only).

.EXAMPLE
    .\build.ps1
    .\build.ps1 check
    .\build.ps1 install
    .\build.ps1 uninstall -Yes
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "all", "clean", "distclean",
        "check", "check-size", "indent", "corpus",
        "install", "uninstall", "status",
        "ext-chrome"
    )]
    [string]$Target = "all",

    # Skip the confirmation prompt during `uninstall`.
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot     = $PSScriptRoot
$BinaryName   = "zhtw-mcp"
$BinaryExe    = "$BinaryName.exe"
$ReleaseBin   = Join-Path $RepoRoot "target\release\$BinaryExe"
$S2TData      = Join-Path $RepoRoot "src\engine\s2t_data.rs"
$OpenCCDir    = Join-Path $RepoRoot "data\opencc"
$GenScript    = Join-Path $RepoRoot "scripts\gen-s2t-tables.py"
$CheckScript  = Join-Path $RepoRoot "scripts\check-ruleset.py"
$MaxSizeBytes = 20 * 1024 * 1024  # 20 MiB

# --- helpers -----------------------------------------------------------------

function Write-Info    { param([string]$Msg) Write-Host "[INFO]   $Msg"   -ForegroundColor Green }
function Write-WarnMsg { param([string]$Msg) Write-Host "[WARN]   $Msg"   -ForegroundColor Yellow }
function Write-ErrMsg  { param([string]$Msg) Write-Host "[ERROR]  $Msg"   -ForegroundColor Red }
function Write-Status  { param([string]$Msg) Write-Host "[STATUS] $Msg"   -ForegroundColor Cyan }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-Python {
    foreach ($name in @("python", "python3")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "Python is required but was not found on PATH."
}

function Ensure-S2TData {
    if (Test-Path $S2TData) { return }
    Write-Info "Generating $S2TData"
    Invoke-Native (Get-Python) @($GenScript)
    Invoke-Native "rustfmt" @($S2TData)
}

function Get-InstallDir {
    if ($env:XDG_BIN_HOME) { return $env:XDG_BIN_HOME }
    return (Join-Path $HOME ".local\bin")
}

function Stop-RunningInstances {
    param([string]$BinaryPath)
    $resolved = $null
    if (Test-Path $BinaryPath) {
        $resolved = (Resolve-Path $BinaryPath).Path
    }
    $procs = Get-CimInstance Win32_Process -Filter "Name = '$BinaryExe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not $resolved -or
            ($_.ExecutablePath -and ((Resolve-Path -LiteralPath $_.ExecutablePath -ErrorAction SilentlyContinue)?.Path -eq $resolved))
        }
    if (-not $procs) { return }

    Write-Info "Stopping running $BinaryName processes..."
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
    $still = Get-Process -Name $BinaryName -ErrorAction SilentlyContinue
    if ($still) {
        throw "Could not stop $BinaryName (PID: $($still.Id -join ', ')). Kill manually and re-run."
    }
    Write-Info "Stopped all $BinaryName processes"
}

function Find-Claude {
    foreach ($name in @("claude", "claude.exe", "claude.cmd")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Test-McpRegistered {
    param([string]$Claude)
    & $Claude mcp get $BinaryName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Register-McpServer {
    param([string]$Claude, [string]$BinaryPath)
    if (Test-McpRegistered -Claude $Claude) {
        Write-Info "MCP server already configured"
        return
    }
    Write-Info "Registering MCP server with Claude Code (user scope)..."
    & $Claude mcp add --scope user $BinaryName -- $BinaryPath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "claude mcp add failed. Run manually: claude mcp add --scope user $BinaryName -- `"$BinaryPath`""
    }
    Write-Info "MCP server registered successfully"
}

function Unregister-McpServer {
    param([string]$Claude)
    if (-not (Test-McpRegistered -Claude $Claude)) {
        Write-Info "MCP server not configured (user scope)"
        return
    }
    Write-Info "Removing MCP server from Claude Code (user scope)..."
    & $Claude mcp remove --scope user $BinaryName *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "claude mcp remove failed."
    }
    Write-Info "MCP server removed"
}

function Test-OnPath {
    param([string]$Dir)
    $needle = $Dir.TrimEnd('\').ToLower()
    return ($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\').ToLower() }) -contains $needle
}

# --- targets -----------------------------------------------------------------

function Invoke-All {
    Ensure-S2TData
    Invoke-Native "cargo" @("build", "--release")
}

function Invoke-Clean {
    Invoke-Native "cargo" @("clean")
}

function Invoke-DistClean {
    Invoke-Clean
    if (Test-Path $S2TData)  { Remove-Item -Force $S2TData }
    if (Test-Path $OpenCCDir) { Remove-Item -Recurse -Force $OpenCCDir }
}

function Invoke-Check {
    Ensure-S2TData
    Invoke-Native "cargo" @("test")
    Invoke-Native "cargo" @("clippy", "--", "-D", "warnings")
    Invoke-Native "cargo" @("fmt", "--check")
    Invoke-Native (Get-Python) @($CheckScript, "--lint")
}

function Invoke-CheckSize {
    Invoke-All
    if (-not (Test-Path $ReleaseBin)) {
        throw "Release binary not found at $ReleaseBin"
    }
    $size = (Get-Item $ReleaseBin).Length
    if ($size -gt $MaxSizeBytes) {
        Write-ErrMsg "FAIL: release binary $size bytes exceeds 20 MiB budget ($MaxSizeBytes)"
        exit 1
    }
    Write-Info "OK: release binary $size bytes (budget: $MaxSizeBytes)"
}

function Invoke-Indent {
    Ensure-S2TData
    Invoke-Native "cargo" @("fmt")
    $py = Get-Python
    Invoke-Native $py @($CheckScript)
    Invoke-Native $py @($CheckScript, "--lint")
    $pyScripts = Get-ChildItem -Path (Join-Path $RepoRoot "scripts") -Filter "*.py" | ForEach-Object FullName
    if ($pyScripts) {
        Invoke-Native "black" $pyScripts
    }
}

function Invoke-Corpus {
    Ensure-S2TData
    Invoke-Native "cargo" @("test", "--test", "corpus-evaluation", "--", "--nocapture")
}

function Invoke-ExtChrome {
    if (-not (Get-Command wasm-pack -ErrorAction SilentlyContinue)) {
        throw "wasm-pack is required. Install with 'cargo install wasm-pack' or see https://rustwasm.github.io/wasm-pack/installer/"
    }
    Ensure-S2TData
    $installed = (& rustup target list --installed) -split "`r?`n"
    if ($installed -notcontains "wasm32-unknown-unknown") {
        Invoke-Native "rustup" @("target", "add", "wasm32-unknown-unknown")
    }
    Invoke-Native "wasm-pack" @(
        "build", $RepoRoot,
        "--target", "web",
        "--out-dir", "extension/dist",
        "--out-name", "zhtw_mcp_wasm",
        "--no-opt",
        "--no-default-features",
        "--features", "browser-wasm"
    )
}

function Invoke-Install {
    Write-Host "=========================================="
    Write-Host "  zhtw-mcp Installer"
    Write-Host "=========================================="

    $claude = Find-Claude
    if (-not $claude) {
        Write-ErrMsg "Claude CLI not found in PATH"
        Write-Host "  Install: npm install -g @anthropic-ai/claude-code"
        exit 1
    }
    Write-Info "Claude CLI found: $claude"

    Invoke-All

    $installDir = Get-InstallDir
    if (-not (Test-Path $installDir)) {
        Write-Info "Creating install directory: $installDir"
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    $installed = Join-Path $installDir $BinaryExe

    Stop-RunningInstances -BinaryPath $installed

    Write-Info "Installing binary -> $installed"
    Copy-Item -Force -Path $ReleaseBin -Destination $installed
    if (-not (Test-Path $installed)) {
        throw "Binary installation failed."
    }
    Write-Info "Binary installed successfully"

    if (Test-OnPath $installDir) {
        Write-Info "Install directory is in PATH"
    } else {
        Write-WarnMsg "Install directory is not in PATH"
        Write-Host "  Add for current user: [Environment]::SetEnvironmentVariable('Path', `"$installDir;`" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')"
    }

    Register-McpServer -Claude $claude -BinaryPath $installed

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Installation Complete"
    Write-Host "=========================================="
    Write-Host "Binary:  $installed"
    Write-Host "Claude MCP server configured (user scope)"
    Write-Host "Next: run /mcp in Claude Code to connect"
}

function Invoke-Uninstall {
    Write-Host "=========================================="
    Write-Host "  zhtw-mcp Uninstaller"
    Write-Host "=========================================="

    if (-not $Yes -and -not ($env:ZHTW_YES -eq "1")) {
        $reply = Read-Host "Are you sure you want to uninstall $BinaryName? [y/N]"
        if ($reply -notmatch '^[Yy]') {
            Write-Host "Uninstallation cancelled"
            return
        }
    }

    $installDir = Get-InstallDir
    $installed  = Join-Path $installDir $BinaryExe

    Stop-RunningInstances -BinaryPath $installed

    $claude = Find-Claude
    if ($claude) {
        Unregister-McpServer -Claude $claude
    } else {
        Write-WarnMsg "Claude CLI not found; skipping MCP deregistration"
    }

    if (Test-Path $installed) {
        Remove-Item -Force $installed
        Write-Info "Removed $installed"
    } else {
        Write-WarnMsg "Binary not found at $installed"
    }

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Uninstallation Complete"
    Write-Host "=========================================="
}

function Invoke-Status {
    $installDir = Get-InstallDir
    $installed  = Join-Path $installDir $BinaryExe

    Write-Status "Checking installation status..."
    Write-Host ""

    if (Test-Path $installed) {
        Write-Info "Binary present: $installed"
        $size = (Get-Item $installed).Length
        Write-Host "  Size: $size bytes"
    } else {
        Write-WarnMsg "Binary not installed at $installed"
    }

    $procs = Get-Process -Name $BinaryName -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Info "Running PIDs: $($procs.Id -join ', ')"
    } else {
        Write-Status "No running $BinaryName process"
    }

    $claude = Find-Claude
    if ($claude) {
        if (Test-McpRegistered -Claude $claude) {
            Write-Info "MCP server registered with Claude Code"
        } else {
            Write-WarnMsg "MCP server not registered"
        }
    } else {
        Write-WarnMsg "Claude CLI not on PATH"
    }

    if (Test-OnPath $installDir) {
        Write-Info "$installDir is on PATH"
    } else {
        Write-WarnMsg "$installDir is NOT on PATH"
    }
}

# --- dispatch ----------------------------------------------------------------

switch ($Target) {
    "all"        { Invoke-All }
    "clean"      { Invoke-Clean }
    "distclean"  { Invoke-DistClean }
    "check"      { Invoke-Check }
    "check-size" { Invoke-CheckSize }
    "indent"     { Invoke-Indent }
    "corpus"     { Invoke-Corpus }
    "install"    { Invoke-Install }
    "uninstall"  { Invoke-Uninstall }
    "status"     { Invoke-Status }
    "ext-chrome" { Invoke-ExtChrome }
}
