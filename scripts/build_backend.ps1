<#
Builds the host backend binary from  source and syncs runtime files
into fqapp. Pass -Jni to also build the Android arm64 shared library.

The backend binary is NOT stored in this repo (large, fully reproducible from
source). Android builds require -Jni; the host executable in assets/bin/
is only used by desktop deployments.

Usage:
  .\scripts\build_backend.ps1                     # defaults to ..\
  .\scripts\build_backend.ps1 C:\path\to\
  .\scripts\build_backend.ps1 -ForceConfig        # also reset existing config
  .\scripts\build_backend.ps1 -ForceRuntime       # replace bundled web/filter/plugin code
  .\scripts\build_backend.ps1 -Jni                # also build arm64 liblegacy.so

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [string]$SourceDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ''),
    [switch]$ForceConfig,
    [switch]$ForceRuntime,
    [switch]$Jni
)

$ErrorActionPreference = 'Stop'

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
$hostTarget = @(go env GOHOSTOS GOHOSTARCH)
if ($LASTEXITCODE -ne 0 -or $hostTarget.Count -ne 2 -or -not $hostTarget[0] -or -not $hostTarget[1]) {
    throw 'cannot determine Go host OS and architecture'
}
Write-Host "==> building host backend ($($hostTarget[0])/$($hostTarget[1]), CGO_ENABLED=0)..."

$binDir = Join-Path $AppDir 'assets\bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$outBin = Join-Path $binDir ''
$buildBin = Join-Path $binDir ('.-' + [guid]::NewGuid().ToString('N') + '.tmp')

$originalGoOS = $env:GOOS
$originalGoArch = $env:GOARCH
$originalCgo = $env:CGO_ENABLED
try {
    $env:GOOS = $hostTarget[0]
    $env:GOARCH = $hostTarget[1]
    $env:CGO_ENABLED = '0'
    Push-Location -LiteralPath $SourceDir
    try {
        go build -trimpath -ldflags '-s -w' -o $buildBin .
        if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
    }
    finally { Pop-Location }
    # Dot-prefixed temporary outputs are hidden on Unix PowerShell.
    if (-not (Test-Path -LiteralPath $buildBin) -or ((Get-Item -LiteralPath $buildBin -Force).Length -eq 0)) {
        throw "build produced no output at $buildBin"
    }
    Move-Item -LiteralPath $buildBin -Destination $outBin -Force
}
finally {
    $env:GOOS = $originalGoOS
    $env:GOARCH = $originalGoArch
    $env:CGO_ENABLED = $originalCgo
    Remove-Item -LiteralPath $buildBin -Force -ErrorAction SilentlyContinue
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

# Bundled runtime code contains app fixes. A backend rebuild must not undo
# them; explicit -ForceRuntime opts in to replacing it with upstream code.
function Sync-RuntimeDirectory {
    param([string]$Name, [string]$Destination)
    $sourceDirectory = (Resolve-Path -LiteralPath (Join-Path $SourceDir $Name)).ProviderPath
    Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceDirectory.Length).TrimStart('\', '/')
        $target = Join-Path $Destination $relative
        if ($ForceRuntime -or -not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}
Sync-RuntimeDirectory 'filters' $filtersDir
Sync-RuntimeDirectory 'web' $webDir
Sync-RuntimeDirectory 'plugins' $pluginsDir
Write-Host '    synced filters\ web\ plugins\ (existing files kept unless -ForceRuntime)'

Write-Host '==> backend binary and runtime files done.'
Get-Item $outBin | Select-Object FullName, Length | Format-List

if ($Jni) {
    Write-Host ''
    Write-Host '==> building JNI shared library (android/arm64, c-shared)...'

    # Prefer an explicitly configured NDK, then the SDK path from
    # ANDROID_HOME/ANDROID_SDK_ROOT, then the standard local.properties file.
    $ndkRoot = $env:ANDROID_NDK_HOME
    if (-not $ndkRoot) { $ndkRoot = $env:ANDROID_NDK_ROOT }
    $sdkRoot = $env:ANDROID_HOME
    if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
    if (-not $sdkRoot) {
        $localProps = Join-Path $AppDir 'android\local.properties'
        if (Test-Path $localProps) {
            $line = Get-Content $localProps | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
            if ($line) { $sdkRoot = ($line -replace '^sdk\.dir=', '').Replace('\:', ':').Replace('\\', '\').Replace('\ ', ' ') }
        }
    }
    if (-not $ndkRoot -and $sdkRoot) {
        $ndkRoot = Get-ChildItem (Join-Path $sdkRoot 'ndk') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $ndkRoot -or -not (Test-Path $ndkRoot)) {
        throw 'Android NDK not found. Set ANDROID_NDK_HOME or install an NDK under the Android SDK.'
    }

    $hostTag = switch ($hostTarget[0]) {
        'windows' { 'windows-x86_64' }
        'darwin' { 'darwin-x86_64' }
        'linux' { 'linux-x86_64' }
        default { throw "unsupported NDK host platform: $($hostTarget[0])" }
    }
    $prebuilt = Join-Path $ndkRoot "toolchains\llvm\prebuilt\$hostTag"
    $cc = Join-Path $prebuilt 'bin\aarch64-linux-android21-clang.cmd'
    if (-not (Test-Path $cc)) { $cc = Join-Path $prebuilt 'bin\aarch64-linux-android21-clang' }
    if (-not (Test-Path $cc)) { throw "Android clang not found under $prebuilt" }
    $sysroot = Join-Path $prebuilt 'sysroot'
    if (-not (Test-Path -LiteralPath $sysroot -PathType Container)) { throw "Android sysroot not found at $sysroot" }
    $jniDir = Join-Path $AppDir 'android\app\src\main\jniLibs\arm64-v8a'
    New-Item -ItemType Directory -Force -Path $jniDir | Out-Null
    $outSo = Join-Path $jniDir 'liblegacy.so'
    $buildSo = Join-Path $jniDir ('.lib-' + [guid]::NewGuid().ToString('N') + '.so')
    $outHeader = [System.IO.Path]::ChangeExtension($buildSo, '.h')

    $oldGoOS = $env:GOOS; $oldGoArch = $env:GOARCH; $oldCgo = $env:CGO_ENABLED; $oldCC = $env:CC; $oldCgoFlags = $env:CGO_CFLAGS
    try {
        $env:GOOS = 'android'
        $env:GOARCH = 'arm64'
        $env:CGO_ENABLED = '1'
        $env:CC = '"' + $cc.Replace('\', '/') + '"'
        $env:CGO_CFLAGS = '-I"' + $sysroot.Replace('\', '/') + '/usr/include"'
        Push-Location -LiteralPath $SourceDir
        try {
            go build -buildmode=c-shared -trimpath -ldflags '-s -w' -o $buildSo .
            if ($LASTEXITCODE -ne 0) { throw 'go c-shared build failed' }
        }
        finally { Pop-Location }
        if (-not (Test-Path -LiteralPath $buildSo) -or (Get-Item -LiteralPath $buildSo -Force).Length -eq 0) {
            throw "JNI build produced no output at $buildSo"
        }
        Move-Item -LiteralPath $buildSo -Destination $outSo -Force
    }
    finally {
        $env:GOOS = $oldGoOS; $env:GOARCH = $oldGoArch; $env:CGO_ENABLED = $oldCgo; $env:CC = $oldCC; $env:CGO_CFLAGS = $oldCgoFlags
        Remove-Item -LiteralPath $buildSo, $outHeader -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $outSo) -or (Get-Item $outSo).Length -eq 0) { throw "JNI build produced no output at $outSo" }
    # The generated C header is useful during development but is not needed
    # by the Android app and should not be packaged as an asset.
    if (Test-Path $outHeader) { Remove-Item -LiteralPath $outHeader -Force }
    Get-Item $outSo | Select-Object FullName, Length | Format-List
}
else {
    Write-Host ''
    Write-Host 'Tip: pass -Jni to build liblegacy.so for Android SELinux-safe startup.'
}
