param(
    [string]$PackageConfigPath = '',
    [string]$BuildDirectory = '',
    [ValidateRange(1, 5)][int]$MaxAttempts = 3,
    [ValidateRange(0, 10)][int]$RetryDelaySeconds = 2
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $PackageConfigPath) { $PackageConfigPath = Join-Path $repoRoot '.dart_tool/package_config.json' }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $repoRoot 'build/windows/x64' }
$configPath = [IO.Path]::GetFullPath($PackageConfigPath)
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$package = @($config.packages | Where-Object { $_.name -eq 'media_kit_libs_windows_video' })
if ($package.Count -ne 1) { throw 'Expected one media_kit_libs_windows_video package. Run flutter pub get first.' }
$configUri = [Uri]::new($configPath)
$packageUri = [Uri]::new($configUri, [string]$package[0].rootUri)
$cmakePath = Join-Path $packageUri.LocalPath 'windows/CMakeLists.txt'
$cmake = Get-Content -LiteralPath $cmakePath -Raw
function Read-CmakeValue([string]$name) {
    $pattern = '(?m)^set\(' + [regex]::Escape($name) + '\s+"([^"]+)"\)'
    $match = [regex]::Match($cmake, $pattern)
    if (-not $match.Success) { throw "Missing $name in plugin metadata; refusing to guess archive identity." }
    return $match.Groups[1].Value
}
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
foreach ($name in @('LIBMPV', 'ANGLE')) {
    $fileName = Read-CmakeValue $name
    if ([IO.Path]::GetFileName($fileName) -ne $fileName) { throw "Invalid archive name: $fileName" }
    $url = (Read-CmakeValue ($name + '_URL')).Replace(('${' + $name + '}'), $fileName)
    $uri = [Uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $url.Contains('${')) { throw "Unexpected download URL: $url" }
    $expected = (Read-CmakeValue ($name + '_MD5')).ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{32}$') { throw "Invalid checksum metadata for $name" }
    $destination = Join-Path $BuildDirectory $fileName
    if (Test-Path -LiteralPath $destination) {
        $actual = (Get-FileHash -LiteralPath $destination -Algorithm MD5).Hash.ToLowerInvariant()
        if ($actual -eq $expected) { Write-Host "Verified existing $fileName"; continue }
        Write-Warning "Removing corrupt $fileName (MD5 $actual; expected $expected)"
        Remove-Item -LiteralPath $destination -Force
        $extractedName = if ($name -eq 'LIBMPV') { 'libmpv' } else { 'ANGLE' }
        $extracted = Join-Path $BuildDirectory $extractedName
        if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
    }
    $partial = $destination + '.download'
    $verified = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            Write-Host "Downloading $fileName (attempt $attempt/$MaxAttempts)"
            & curl.exe --fail --location --connect-timeout 20 --max-time 240 --output $partial --url $url
            if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
            $actual = (Get-FileHash -LiteralPath $partial -Algorithm MD5).Hash.ToLowerInvariant()
            if ($actual -ne $expected) {
                $size = (Get-Item -LiteralPath $partial).Length
                throw "Integrity check failed for $fileName ($size bytes; MD5 $actual; expected $expected)"
            }
            Move-Item -LiteralPath $partial -Destination $destination -Force
            $verified = $true
            break
        } catch {
            Write-Warning $_.Exception.Message
            if ($attempt -eq $MaxAttempts) { throw }
            if ($RetryDelaySeconds) { Start-Sleep -Seconds $RetryDelaySeconds }
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
    if (-not $verified) { throw "Could not verify $fileName" }
}
