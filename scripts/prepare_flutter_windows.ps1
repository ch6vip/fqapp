param([Parameter(Mandatory = $true)][string]$FlutterRoot)
$ErrorActionPreference = 'Stop'
$sdk = [IO.Path]::GetFullPath($FlutterRoot)
$patch = Join-Path $PSScriptRoot 'patches\flutter-3.44.6-semantics.patch'
# Flutter 3.44.6 sends orphan OverlayPortal nodes during route transitions.
# Optional backport for a dedicated SDK; normal Windows builds do not call it.
& git -C $sdk apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -eq 0) { Write-Output 'Flutter Windows semantics backport already applied'; exit 0 }
& git -C $sdk apply --check $patch
if ($LASTEXITCODE -ne 0) {
    throw 'Optional backport does not match this SDK; inspect scripts/patches/README.md before changing it.'
}
& git -C $sdk apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Could not apply Flutter semantics backport' }
Write-Output 'Applied Flutter Windows semantics backport'
