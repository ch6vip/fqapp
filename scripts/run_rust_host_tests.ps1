<#
Builds the host Rust core and runs the real Dart -> flutter_rust_bridge -> Rust
integration tests against it.

Everything the tests touch is local: a temporary runtime directory and a mock
upstream on 127.0.0.1. No device, no real device pool, no upstream traffic.

Usage:
  .\scripts\run_rust_host_tests.ps1
  .\scripts\run_rust_host_tests.ps1 -SkipBuild

Unknown parameters are a hard error (PowerShell rejects them before the
script body runs). With -SkipBuild the existing host library is trusted only
after proving it is not older than the newest rust/ change; a stale library
errors out instead of running tests against code that is no longer there.

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

if ($SkipBuild) {
    # -SkipBuild trusts the existing host library, so prove it is not older
    # than the newest rust/ change: a stale library would run the tests
    # against code that is no longer there. rust/target/ is build output, not
    # source, so it is excluded from the comparison.
    $LibraryTime = (Get-Item -LiteralPath $Library).LastWriteTimeUtc
    $RustDir = Join-Path $AppDir 'rust'
    $StaleSource = Get-ChildItem -LiteralPath $RustDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]target[\\/]' -and $_.LastWriteTimeUtc -gt $LibraryTime } |
        Select-Object -First 1
    if ($StaleSource) {
        Write-Error "Host Rust core $Library is older than rust/ change $($StaleSource.FullName); rebuild without -SkipBuild first."
        exit 1
    }
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
