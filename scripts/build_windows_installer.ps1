param([string]$IsccPath = '', [string]$BundlePath = '')
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $BundlePath) { $BundlePath = Join-Path $repoRoot 'build\windows\x64\runner\Release' }
$BundlePath = [IO.Path]::GetFullPath($BundlePath)
if (-not $IsccPath) {
    $candidates = @(
        (Join-Path $repoRoot '.tools\inno\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $IsccPath) { throw 'Install Inno Setup or pass -IsccPath.' }
}
foreach ($file in @('fqapp.exe', 'flutter_windows.dll', 'fqapi_core.dll', 'libmpv-2.dll', 'data\app.so', 'LICENSE.txt', '使用说明.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BundlePath $file))) { throw "Incomplete Windows release bundle: $file" }
}
if (-not (Test-Path -LiteralPath (Join-Path $BundlePath 'licenses\fqapp-GPL-3.0.txt'))) { throw 'Run scripts/collect_windows_licenses.py before packaging.' }
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Raw
if ($manifest -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$') { throw 'Cannot read application version' }
$version = $Matches[1]
$dist = Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$installer = Join-Path $dist "fqapp-desktop-$version-windows-x64-setup.exe"
if (Test-Path -LiteralPath $installer) { throw "Installer already exists; preserve or explicitly archive it before rebuilding: $installer" }
& $IsccPath "/DBundleDir=$BundlePath" "/DRepoRoot=$repoRoot" "/DOutputDir=$dist" "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer\fqapp.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $installer)) { throw 'Installer compiler did not produce the expected file' }
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($installer + '.sha256'), "$hash  $([IO.Path]::GetFileName($installer))`n", [Text.UTF8Encoding]::new($false))
Write-Output "Installer: $installer"
Write-Output "SHA256: $hash"
