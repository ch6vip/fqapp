param([Parameter(Mandatory = $true)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
$sdk = [IO.Path]::GetFullPath($FlutterRoot)
$patch = Join-Path $PSScriptRoot 'patches\flutter-3.44.6-semantics.patch'
# Flutter 3.44.6 sends orphan OverlayPortal nodes during route transitions.
# Backport the upstream lifecycle fixes before compiling the application.
& git -C $sdk apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -eq 0) { Write-Output 'Flutter Windows semantics backport already applied'; exit 0 }
& git -C $sdk apply --check $patch
if ($LASTEXITCODE -ne 0) {
    throw 'This build requires Flutter 3.44.6 with the checked-in semantics backport. SDK differs; inspect scripts/patches/README.md before changing it.'
}
& git -C $sdk apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Could not apply Flutter semantics backport' }
Write-Output 'Applied Flutter Windows semantics backport'
