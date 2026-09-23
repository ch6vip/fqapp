<#
Builds the host Rust core and runs the real Dart -> flutter_rust_bridge -> Rust
integration tests against it.

Everything the tests touch is local: a temporary runtime directory and a mock
upstream on 127.0.0.1. No device, no real device pool, no upstream traffic.

Usage:
  .\scripts\run_rust_host_tests.ps1
  .\scripts\run_rust_host_tests.ps1 -SkipBuild

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $AppDir 'rust\Cargo.toml'

if (-not $SkipBuild) {
    Write-Host '==> building the host Rust core...'
    Push-Location -LiteralPath $AppDir
    try {
        cargo build --manifest-path $Manifest
        if ($LASTEXITCODE -ne 0) { throw 'host rust build failed' }
    }
    finally { Pop-Location }
}

$LibraryName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'fqapi_core.dll' } else { 'libfqapi_core.so' }
$Library = Join-Path $AppDir "rust\target\debug\$LibraryName"
if (-not (Test-Path -LiteralPath $Library)) {
    Write-Error "host core not found at $Library"
    exit 1
}

$env:FQAPP_RUST_HOST_LIB = $Library
Write-Host "==> host core: $Library"
Get-FileHash -Algorithm SHA256 -LiteralPath $Library | Format-List

Push-Location -LiteralPath $AppDir
try {
    flutter test --no-pub test/rust_host_integration_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'host integration tests failed' }
}
finally { Pop-Location }
