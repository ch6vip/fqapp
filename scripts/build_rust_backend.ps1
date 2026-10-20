<#
Builds the Rust native core (rust/ -> libfqapi_core.so) for Android
(arm64-v8a and armeabi-v7a) and copies each library into its
android/app/src/main/jniLibs/<abi> directory.

Both ABIs are always built: the split APK build packages both (see the
split-per-ABI build in .github/workflows/android-apk.yml), so building
only one would leave the packaging verification without the other
library and fail the build.
Cargo caches per target, so a rebuild with no Rust changes is fast.

This is the single entry point for the Rust build: it regenerates the
flutter_rust_bridge bindings, cross-compiles with the pinned NDK, and places the
shared library where Gradle packages it. Pass -HostLib to also build the host
cdylib used by desktop deployments.

Usage:
  .\scripts\build_rust_backend.ps1
  .\scripts\build_rust_backend.ps1 -SkipCodegen
  .\scripts\build_rust_backend.ps1 -HostLib
  .\scripts\build_rust_backend.ps1 -Profile debug

Unknown parameters are a hard error (PowerShell rejects them before the
script body runs). -Profile only accepts release|debug (ValidateSet). The NDK
must be exactly the pinned revision below; any other revision is a hard error,
never a silent fallback to the newest installed NDK.

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [switch]$SkipCodegen,
    [switch]$HostLib,
    [ValidateSet('release', 'debug')][string]$Profile = 'release'
)

$ErrorActionPreference = 'Stop'

# The NDK revision the project pins. Resolve-NdkRoot below only ever returns
# this revision or $null; the post-resolution check rejects an env override
# pointing anywhere else.
$PinnedNdkVersion = '28.2.13676358'

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

# Native commands (cargo, codegen) write progress to stderr, and PowerShell
# turns any stderr line into a NativeCommandError. With
# $ErrorActionPreference = 'Stop' that aborts the script *before* the copy step,
# so a successful compile looks like a failed build (see CRIT-012). Downgrading
# the preference for the duration of the native call keeps stderr on screen as
# ordinary output while leaving the real verdict to $LASTEXITCODE.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)" }
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
        Invoke-NativeCommand -Exe 'flutter_rust_bridge_codegen' `
            -Arguments @('generate', '--config-file', 'flutter_rust_bridge.yaml') `
            -FailureMessage 'flutter_rust_bridge_codegen generate failed'
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
    # Only the pinned revision is acceptable: falling back to the newest
    # installed NDK would silently change the toolchain the release was
    # built with.
    $preferred = Join-Path $sdkRoot "ndk\$PinnedNdkVersion"
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    return $null
}

$NdkRoot = Resolve-NdkRoot
if (-not $NdkRoot -or -not (Test-Path -LiteralPath $NdkRoot)) {
    Write-Error "Android NDK $PinnedNdkVersion not found. Set ANDROID_NDK_HOME to that revision or install NDK $PinnedNdkVersion under the Android SDK."
    exit 1
}
# An env override pointing at a different revision is a hard error, never a
# silent substitution.
if ((Split-Path -Leaf $NdkRoot.TrimEnd('\')) -ne $PinnedNdkVersion) {
    Write-Error "Resolved NDK is not the pinned revision $PinnedNdkVersion (resolved to $NdkRoot). Install the pinned revision and point at it."
    exit 1
}
Write-Host "==> NDK: $NdkRoot"

$Prebuilt = Join-Path $NdkRoot 'toolchains\llvm\prebuilt\windows-x86_64'
if (-not (Test-Path -LiteralPath $Prebuilt)) {
    Write-Error "NDK windows prebuilt toolchain not found under $NdkRoot"
    exit 1
}
$ApiLevel = 21

# Cross-compiles the Rust core for one Android ABI and installs it into
# that ABI's jniLibs directory. The armv7 target uses the armv7a NDK triple
# (armeabi-v7a with NEON, the same assumption the Flutter engine build
# makes for 32-bit ARM).
function Build-AndroidTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RustTarget,
        [Parameter(Mandatory = $true)][string]$ClangTriple,
        [Parameter(Mandatory = $true)][string]$Abi
    )
    $Cc = Join-Path $Prebuilt "bin\$ClangTriple$ApiLevel-clang.cmd"
    if (-not (Test-Path -LiteralPath $Cc)) { $Cc = Join-Path $Prebuilt "bin\$ClangTriple$ApiLevel-clang" }
    if (-not (Test-Path -LiteralPath $Cc)) { Write-Error "$ClangTriple clang not found under $Prebuilt"; exit 1 }

    $CcForward = $Cc.Replace('\', '/')
    $CcEnv = 'CC_' + ($RustTarget -replace '-', '_')
    $ArEnv = 'AR_' + ($RustTarget -replace '-', '_')
    $LinkerEnv = 'CARGO_TARGET_' + (($RustTarget -replace '-', '_').ToUpper()) + '_LINKER'
    Set-Item -Path "env:$CcEnv" -Value $CcForward
    Set-Item -Path "env:$ArEnv" -Value (Join-Path $Prebuilt 'bin\llvm-ar.exe').Replace('\', '/')
    Set-Item -Path "env:$LinkerEnv" -Value $CcForward

    Write-Host "==> CC ($Abi): $CcForward"

    $JniDir = Join-Path $AppDir "android\app\src\main\jniLibs\$Abi"
    New-Item -ItemType Directory -Force -Path $JniDir | Out-Null

    $ProfileArgs = @()
    if ($Profile -eq 'release') { $ProfileArgs = @('--release') }

    Write-Host "==> cargo build --target $RustTarget ($Profile)..."
    Push-Location -LiteralPath $AppDir
    try {
        Invoke-NativeCommand -Exe 'cargo' `
            -Arguments (@('build', '--manifest-path', $Manifest, '--target', $RustTarget) + $ProfileArgs) `
            -FailureMessage 'rust cross build failed'
    }
    finally { Pop-Location }

    $ProfileDir = if ($Profile -eq 'release') { 'release' } else { 'debug' }
    $BuiltSo = Join-Path $AppDir "rust\target\$RustTarget\$ProfileDir\libfqapi_core.so"
    if (-not (Test-Path -LiteralPath $BuiltSo)) {
        Write-Error "rust build produced no $BuiltSo"
        exit 1
    }

    $DestSo = Join-Path $JniDir 'libfqapi_core.so'
    Copy-Item -LiteralPath $BuiltSo -Destination $DestSo -Force
    Write-Host "==> jniLibs: $DestSo"
    Get-FileHash -Algorithm SHA256 -LiteralPath $DestSo | Format-List
}

Build-AndroidTarget -RustTarget 'aarch64-linux-android' -ClangTriple 'aarch64-linux-android' -Abi 'arm64-v8a'
Build-AndroidTarget -RustTarget 'armv7-linux-androideabi' -ClangTriple 'armv7a-linux-androideabi' -Abi 'armeabi-v7a'

if ($HostLib) {
    Write-Host '==> building host cdylib...'
    Push-Location -LiteralPath $AppDir
    try {
        Invoke-NativeCommand -Exe 'cargo' `
            -Arguments (@('build', '--manifest-path', $Manifest) + $ProfileArgs) `
            -FailureMessage 'host rust build failed'
    }
    finally { Pop-Location }
    Write-Host "==> host library: rust\target\$ProfileDir\"
}
