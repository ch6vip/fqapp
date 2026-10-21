param([string]$FlutterRoot = '', [switch]$SkipTests, [switch]$ApplySemanticsBackport)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $FlutterRoot) {
    $localFlutter = Join-Path $repoRoot '.tools\flutter'
    if (Test-Path -LiteralPath (Join-Path $localFlutter 'bin\flutter.bat')) { $FlutterRoot = $localFlutter }
    else { $FlutterRoot = Split-Path (Split-Path (Get-Command flutter -ErrorAction Stop).Source) }
}
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
$env:PATH = (Join-Path $repoRoot '.tools\bin') + ';' + $env:PATH
function Invoke-Checked([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "$program failed: $LASTEXITCODE" }
}
# Flutter 3.44's Windows LSP transport can fail with a non-ASCII workspace path.
$buildRoot = $repoRoot
if ($repoRoot -match '[^\x00-\x7f]') {
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($repoRoot))).Substring(0, 12)
    $buildRoot = Join-Path $env:TEMP "fqapp-build-$hash"
    if (Test-Path -LiteralPath $buildRoot) {
        $target = (Get-Item -LiteralPath $buildRoot).Target
        if ($target -ne $repoRoot) { throw "Build alias belongs to another directory: $buildRoot" }
    } else { New-Item -ItemType Junction -Path $buildRoot -Target $repoRoot | Out-Null }
}
$original = Get-Location
try {
    Set-Location -LiteralPath $buildRoot
    if ($ApplySemanticsBackport) {
        & (Join-Path $PSScriptRoot 'prepare_flutter_windows.ps1') -FlutterRoot $FlutterRoot
    }
    Invoke-Checked $flutter @('pub', 'get')
    Invoke-Checked $flutter @('analyze', '--no-pub')
    if (-not $SkipTests) {
        $testArgs = @('test', '--no-pub')
        if ($ApplySemanticsBackport) { $testArgs += '--dart-define=FQAPP_FLUTTER_SEMANTICS_PATCH=true' }
        Invoke-Checked $flutter $testArgs
        Invoke-Checked 'cargo' @('test', '--manifest-path', 'rust/Cargo.toml', '--locked', '--lib')
    }
    Invoke-Checked $flutter @('build', 'windows', '--release', '--no-pub')
    Invoke-Checked 'python' @('scripts/verify_windows_media.py')
    Invoke-Checked (Join-Path $FlutterRoot 'bin\dart.bat') @('compile', 'exe', 'scripts/verify_windows_player.dart', '-o', 'build/verify_windows_player.exe')
    Invoke-Checked (Join-Path $buildRoot 'build/verify_windows_player.exe') @()
    if (-not $SkipTests) {
        $fixture = Join-Path $buildRoot 'build\validation\windows-player\encrypted.mp4'
        Invoke-Checked $flutter @('test', 'integration_test/windows_playback_test.dart', '-d', 'windows', '--no-pub', "--dart-define=FQAPP_TEST_MEDIA=$fixture")
    }
    Invoke-Checked 'python' @('scripts/collect_windows_licenses.py')
    $bundle = Join-Path $buildRoot 'build\windows\x64\runner\Release'
    foreach ($required in @('fqapp.exe', 'flutter_windows.dll', 'fqapi_core.dll', 'data\app.so')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Missing bundle file: $required" }
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $bundle 'LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'WINDOWS.md') -Destination (Join-Path $bundle '使用说明.md')
    $dist = Join-Path $repoRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Raw
    if ($manifest -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$') { throw 'Cannot read application version' }
    $name = 'fqapp-desktop-' + $Matches[1] + '-windows-x64-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip'
    $archive = Join-Path $dist $name
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive
    Get-FileHash -LiteralPath $archive -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLower() + '  ' + $name } | Set-Content -LiteralPath ($archive + '.sha256')
    Write-Output "Bundle: $archive"
} finally { Set-Location -LiteralPath $original.Path }
