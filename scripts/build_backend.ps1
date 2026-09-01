# Cross-compiles the Android backend binary from  source and syncs the
# runtime files into fqapp.
#
# The backend binary is NOT stored in this repo (large, fully reproducible from
# source). Run this script once after cloning, otherwise the APK will ship
# without assets/bin/ and the local service cannot start.
#
# Usage:
#   .\scripts\build_backend.ps1                    # defaults to ..\
#   .\scripts\build_backend.ps1 C:\path\to\
#
# Comments are kept in ASCII on purpose so the file parses cleanly on
# Windows PowerShell 5.1 without a UTF-8 BOM.

$ErrorActionPreference = 'Stop'

param(
    [string]$SourceDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '')
)

$AppDir = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Error 'go not found in PATH. Install Go 1.26+ first.'
    exit 1
}

$mainGo = Join-Path $SourceDir 'main.go'
$goMod  = Join-Path $SourceDir 'go.mod'
if (-not (Test-Path $mainGo) -or -not (Test-Path $goMod)) {
    Write-Error "$SourceDir does not look like an  source tree (main.go / go.mod missing). Usage: .\scripts\build_backend.ps1 <-source-dir>"
    exit 1
}

Write-Host "==> source: $SourceDir"
Write-Host '==> cross-compiling backend (android/arm64, CGO_ENABLED=0)...'

$binDir = Join-Path $AppDir 'assets\bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$outBin = Join-Path $binDir ''

$env:GOOS = 'android'
$env:GOARCH = 'arm64'
$env:CGO_ENABLED = '0'
Push-Location $SourceDir
try {
    go build -trimpath -ldflags '-s -w' -o $outBin .
    if (-not $?) { throw 'go build failed' }
}
finally {
    Pop-Location
    Remove-Item Env:\GOOS, Env:\GOARCH, Env:\CGO_ENABLED -ErrorAction SilentlyContinue
}

Write-Host '==> syncing runtime files...'
$configDir  = Join-Path $AppDir 'assets\config'
$filtersDir = Join-Path $AppDir 'assets\filters'
$webDir     = Join-Path $AppDir 'assets\web'
$pluginsDir = Join-Path $AppDir 'assets\plugins'
foreach ($d in @($configDir, $filtersDir, $webDir, $pluginsDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Copy only these known-good config files. The real device pool carries
# secret_key values and must never be bundled into the APK, so we copy the
# placeholder example instead of mirroring the whole directory.
Copy-Item (Join-Path $SourceDir 'config\config.json')              (Join-Path $configDir 'config.json')              -Force
Copy-Item (Join-Path $SourceDir 'config\filter.json')              (Join-Path $configDir 'filter.json')              -Force
Copy-Item (Join-Path $SourceDir 'config\device_pool.example.json') (Join-Path $configDir 'device_pool.example.json') -Force
Remove-Item (Join-Path $configDir 'device_pool.json') -ErrorAction SilentlyContinue

Copy-Item (Join-Path $SourceDir 'filters\*')  $filtersDir -Recurse -Force
Copy-Item (Join-Path $SourceDir 'web\*')      $webDir     -Recurse -Force
Copy-Item (Join-Path $SourceDir 'plugins\*')  $pluginsDir -Recurse -Force

Write-Host '==> done.'
Get-Item $outBin | Select-Object FullName, Length | Format-List
Write-Host ''
Write-Host 'Note: liblegacy.so under android/app/src/main/jniLibs/ is not in this repo.'
Write-Host '      It is only a placeholder for the planned JNI approach (it contains no'
Write-Host '      JNI export symbols), and MainActivity never loads it, so skipping it'
Write-Host '      does not break debug builds.'
