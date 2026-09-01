<#
Cross-compiles the Android backend binary from  source and syncs the
runtime files into fqapp.

The backend binary is NOT stored in this repo (large, fully reproducible from
source). Run this script once after cloning, otherwise the APK will ship
without assets/bin/ and the local service cannot start.

Usage:
  .\scripts\build_backend.ps1                     # defaults to ..\
  .\scripts\build_backend.ps1 C:\path\to\
  .\scripts\build_backend.ps1 -ForceConfig        # also reset existing config

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

$ErrorActionPreference = 'Stop'

param(
    [string]$SourceDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ''),
    [switch]$ForceConfig
)

$AppDir = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Error 'go not found in PATH. Install Go 1.26+ first.'
    exit 1
}

$mainGo = Join-Path $SourceDir 'main.go'
$goMod  = Join-Path $SourceDir 'go.mod'
if (-not (Test-Path $mainGo) -or -not (Test-Path $goMod)) {
    Write-Error "$SourceDir does not look like an  source tree (main.go / go.mod missing). Usage: .\scripts\build_backend.ps1 [-ForceConfig] <-source-dir>"
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

# Never trust go's exit code alone: it can be 0 while producing no file.
if (-not (Test-Path $outBin) -or ((Get-Item $outBin).Length -eq 0)) {
    Write-Error "build produced no output at $outBin (go exited 0 but the file is missing or empty)"
    exit 1
}

Write-Host '==> syncing runtime files...'
$configDir  = Join-Path $AppDir 'assets\config'
$filtersDir = Join-Path $AppDir 'assets\filters'
$webDir     = Join-Path $AppDir 'assets\web'
$pluginsDir = Join-Path $AppDir 'assets\plugins'
foreach ($d in @($configDir, $filtersDir, $webDir, $pluginsDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# assets\config is app-side runtime config, not code: seed it once and never
# overwrite what is already there.
#
# It holds values deliberately tuned for mobile. The key one is
# anti_crawler.enabled, which only affects unmatched routes
# (\internal\endpoints\router.go): $true 302-redirects unknown paths to
# redirect_url, $false returns a JSON 404. Upstream  defaults to $true
# because it targets a web UI, but the app's ApiClient only produces confusing
# errors when it gets a 302, so this must stay $false.
#
# Delete the file (or pass -ForceConfig) to pull the upstream default back.
function Sync-ConfigFile {
    param([string]$Name)
    $dst = Join-Path $configDir $Name
    if ((Test-Path $dst) -and -not $ForceConfig) {
        Write-Host "    keep $Name (already present, not overwritten)"
        return
    }
    Copy-Item (Join-Path $SourceDir "config\$Name") $dst -Force
    Write-Host "    write $Name"
}

# Only these three known files. Never mirror config\ wholesale: a real
# device_pool.json carries secret_key credentials.
Sync-ConfigFile 'config.json'
Sync-ConfigFile 'filter.json'
Sync-ConfigFile 'device_pool.example.json'
Remove-Item (Join-Path $configDir 'device_pool.json') -ErrorAction SilentlyContinue

# filters / web / plugins are code, not config: always overwrite.
Copy-Item (Join-Path $SourceDir 'filters\*') $filtersDir -Recurse -Force
Copy-Item (Join-Path $SourceDir 'web\*')     $webDir     -Recurse -Force
Copy-Item (Join-Path $SourceDir 'plugins\*') $pluginsDir -Recurse -Force
Write-Host '    overwrite filters\ web\ plugins\'

Write-Host '==> done.'
Get-Item $outBin | Select-Object FullName, Length | Format-List
Write-Host ''
Write-Host 'Note: liblegacy.so under android/app/src/main/jniLibs/ is not in this repo.'
Write-Host '      It is only a placeholder for the planned JNI approach (it contains no'
Write-Host '      JNI export symbols), and MainActivity never loads it, so skipping it'
Write-Host '      does not break debug builds.'
