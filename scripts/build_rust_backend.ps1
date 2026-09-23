<#
Builds the Rust native core (rust/ -> libfqapi_core.so) for Android arm64 and
copies it into android/app/src/main/jniLibs/arm64-v8a.

This is the single entry point for the Rust build: it regenerates the
flutter_rust_bridge bindings, cross-compiles with the pinned NDK, and places the
shared library where Gradle packages it. Pass -HostLib to also build the host
cdylib used by desktop deployments.

Usage:
  .\scripts\build_rust_backend.ps1
  .\scripts\build_rust_backend.ps1 -SkipCodegen
  .\scripts\build_rust_backend.ps1 -HostLib
  .\scripts\build_rust_backend.ps1 -Profile debug

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [switch]$SkipCodegen,
    [switch]$HostLib,
    [string]$Profile = 'release'
)

$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $AppDir 'rust\Cargo.toml'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo not found in PATH. Install the Rust toolchain first.'
    exit 1
}
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Error "rust core manifest not found at $Manifest"
    exit 1
}

# FRB 2.13.0 is the pinned codegen version; the crate pins the matching runtime.
$FrbVersion = '2.13.0'

if (-not $SkipCodegen) {
    if (-not (Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue)) {
        Write-Error "flutter_rust_bridge_codegen not found. Install it with: cargo install flutter_rust_bridge_codegen --version $FrbVersion --locked"
        exit 1
    }
    Write-Host '==> generating flutter_rust_bridge bindings...'
    Push-Location -LiteralPath $AppDir
    try {
        flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
        if ($LASTEXITCODE -ne 0) { throw 'flutter_rust_bridge_codegen generate failed' }
    }
    finally { Pop-Location }
}

function Resolve-NdkRoot {
    $ndkRoot = $env:ANDROID_NDK_HOME
    if (-not $ndkRoot) { $ndkRoot = $env:ANDROID_NDK_ROOT }
    if ($ndkRoot) { return $ndkRoot }
    $sdkRoot = $env:ANDROID_HOME
    if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
    if (-not $sdkRoot) {
        $localProps = Join-Path $AppDir 'android\local.properties'
        if (Test-Path -LiteralPath $localProps) {
            $line = Get-Content -LiteralPath $localProps | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
            if ($line) { $sdkRoot = ($line -replace '^sdk\.dir=', '') }
        }
    }
    if (-not $sdkRoot) { return $null }
    # Prefer the NDK revision the project already uses.
    $preferred = Join-Path $sdkRoot 'ndk\28.2.13676358'
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    $latest = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'ndk') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

$NdkRoot = Resolve-NdkRoot
if (-not $NdkRoot -or -not (Test-Path -LiteralPath $NdkRoot)) {
    Write-Error 'Android NDK not found. Set ANDROID_NDK_HOME or install an NDK under the Android SDK.'
    exit 1
}
Write-Host "==> NDK: $NdkRoot"

$Prebuilt = Join-Path $NdkRoot 'toolchains\llvm\prebuilt\windows-x86_64'
if (-not (Test-Path -LiteralPath $Prebuilt)) {
    Write-Error "NDK windows prebuilt toolchain not found under $NdkRoot"
    exit 1
}
$ApiLevel = 21
$Cc = Join-Path $Prebuilt "bin\aarch64-linux-android$ApiLevel-clang.cmd"
if (-not (Test-Path -LiteralPath $Cc)) { $Cc = Join-Path $Prebuilt "bin\aarch64-linux-android$ApiLevel-clang" }
if (-not (Test-Path -LiteralPath $Cc)) { Write-Error "aarch64 clang not found under $Prebuilt"; exit 1 }

$CcForward = $Cc.Replace('\', '/')
$env:CC_aarch64_linux_android = $CcForward
$env:AR_aarch64_linux_android = (Join-Path $Prebuilt 'bin\llvm-ar.exe').Replace('\', '/')
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $CcForward

Write-Host "==> CC: $CcForward"

$Target = 'aarch64-linux-android'
$JniDir = Join-Path $AppDir 'android\app\src\main\jniLibs\arm64-v8a'
New-Item -ItemType Directory -Force -Path $JniDir | Out-Null

$ProfileArgs = @()
if ($Profile -eq 'release') { $ProfileArgs = @('--release') }

Write-Host "==> cargo build --target $Target ($Profile)..."
Push-Location -LiteralPath $AppDir
try {
    cargo build --manifest-path $Manifest --target $Target @ProfileArgs
    if ($LASTEXITCODE -ne 0) { throw 'rust cross build failed' }
}
finally { Pop-Location }

$ProfileDir = if ($Profile -eq 'release') { 'release' } else { 'debug' }
$BuiltSo = Join-Path $AppDir "rust\target\$Target\$ProfileDir\libfqapi_core.so"
if (-not (Test-Path -LiteralPath $BuiltSo)) {
    Write-Error "rust build produced no $BuiltSo"
    exit 1
}

$DestSo = Join-Path $JniDir 'libfqapi_core.so'
Copy-Item -LiteralPath $BuiltSo -Destination $DestSo -Force
Write-Host "==> jniLibs: $DestSo"
Get-FileHash -Algorithm SHA256 -LiteralPath $DestSo | Format-List

if ($HostLib) {
    Write-Host '==> building host cdylib...'
    Push-Location -LiteralPath $AppDir
    try {
        cargo build --manifest-path $Manifest @ProfileArgs
        if ($LASTEXITCODE -ne 0) { throw 'host rust build failed' }
    }
    finally { Pop-Location }
    Write-Host "==> host library: rust\target\$ProfileDir\"
}
