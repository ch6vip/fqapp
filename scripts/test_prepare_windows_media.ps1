$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('windows-media-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'package/windows') -Force | Out-Null
$build = Join-Path $root 'build'
$settingsPath = Join-Path $root 'package_config.json'
$packageUri = [Uri]::new([IO.Path]::GetFullPath((Join-Path $root 'package')) + [IO.Path]::DirectorySeparatorChar)
@{packages = @(@{name = 'media_kit_libs_windows_video'; rootUri = $packageUri.AbsoluteUri})} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath
$global:mediaTestCalls = 0
$global:mediaTestMode = 'recover'
$global:mediaTestPayload = [Text.Encoding]::UTF8.GetBytes('verified archive fixture')
$hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($global:mediaTestPayload)).Replace('-', '').ToLowerInvariant()
$metadata = @(
    'set(LIBMPV "mpv.7z")',
    'set(LIBMPV_URL "https://github.com/example/releases/${LIBMPV}")',
    ('set(LIBMPV_MD5 "' + $hash + '")'),
    'set(ANGLE "ANGLE.7z")',
    'set(ANGLE_URL "https://github.com/example/releases/ANGLE.7z")',
    ('set(ANGLE_MD5 "' + $hash + '")')
) -join "`n"
Set-Content -LiteralPath (Join-Path $root 'package/windows/CMakeLists.txt') -Value $metadata
# Mock only the network boundary; execute the real checksum/retry script.
function curl.exe {
    param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    $global:mediaTestCalls++
    $outputIndex = [Array]::IndexOf($Arguments, '--output')
    $urlIndex = [Array]::IndexOf($Arguments, '--url')
    if ($outputIndex -lt 0 -or $urlIndex -lt 0) { throw 'Missing curl options' }
    if ($Arguments[$urlIndex + 1] -notmatch '^https://github.com/example/releases/(mpv|ANGLE)\.7z$') { throw 'CMake URL substitution failed' }
    $output = $Arguments[$outputIndex + 1]
    # The recovery case gets a truncated successful response first.
    if ($global:mediaTestMode -eq 'fail' -or $global:mediaTestCalls -eq 1) {
        [IO.File]::WriteAllText($output, 'truncated')
    } else {
        [IO.File]::WriteAllBytes($output, $global:mediaTestPayload)
    }
    $global:LASTEXITCODE = 0
}
try {
    $script = Join-Path $PSScriptRoot 'prepare_windows_media.ps1'
    & $script -PackageConfigPath $settingsPath -BuildDirectory $build -RetryDelaySeconds 0
    if ($global:mediaTestCalls -ne 3) { throw 'Expected one retry plus ANGLE download' }
    & $script -PackageConfigPath $settingsPath -BuildDirectory $build -RetryDelaySeconds 0
    if ($global:mediaTestCalls -ne 3) { throw 'Valid cached archives should not download again' }
    New-Item -ItemType Directory -Path (Join-Path $build 'libmpv') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $build 'libmpv/partial.dll'), 'partial extraction')
    [IO.File]::WriteAllText((Join-Path $build 'mpv.7z'), 'stale corrupt cache')
    & $script -PackageConfigPath $settingsPath -BuildDirectory $build -RetryDelaySeconds 0
    if (Test-Path (Join-Path $build 'libmpv')) { throw 'Partial extraction survived corrupt cache recovery' }
    if ($global:mediaTestCalls -ne 4) { throw 'Corrupt cached mpv was not replaced' }
    $global:mediaTestMode = 'fail'
    Remove-Item -LiteralPath (Join-Path $build 'mpv.7z') -Force
    $failed = $false
    try {
        & $script -PackageConfigPath $settingsPath -BuildDirectory $build -MaxAttempts 2 -RetryDelaySeconds 0
    } catch { $failed = $true }
    if (-not $failed) { throw 'Repeated integrity failures must stop the build' }
    if ((Test-Path (Join-Path $build 'mpv.7z')) -or (Test-Path (Join-Path $build 'mpv.7z.download'))) {
        throw 'Unverified partial archives must not survive a failed download'
    }
    Write-Host 'PASS: truncated download retries, valid cache reuse, corrupt cache recovery, and persistent corruption rejection.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
    Remove-Variable -Name mediaTestCalls,mediaTestMode,mediaTestPayload -Scope Global
}
