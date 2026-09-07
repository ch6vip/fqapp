# Invoked only by build_backend_scripts_test.cjs inside a temporary fixture.
$ErrorActionPreference = 'Stop'

function go {
    $buildArguments = @($args)
    if ($buildArguments[0] -eq 'env') {
        foreach ($name in $buildArguments | Select-Object -Skip 1) {
            switch ($name) {
                'GOHOSTOS' { $env:FQAPP_FAKE_HOST_OS }
                'GOHOSTARCH' { $env:FQAPP_FAKE_HOST_ARCH }
                default { throw "unexpected go env query: $name" }
            }
        }
        $global:LASTEXITCODE = 0
        return
    }
    if ($buildArguments[0] -ne 'build') { throw 'unexpected fake go command' }
    $kind = if ($buildArguments -contains '-buildmode=c-shared') { 'jni' } else { 'standalone' }
    $record = [ordered]@{
        kind = $kind
        cwd = (Get-Location).Path
        GOOS = $env:GOOS
        GOARCH = $env:GOARCH
        CGO_ENABLED = $env:CGO_ENABLED
        CC = $env:CC
        CGO_CFLAGS = $env:CGO_CFLAGS
    }
    Add-Content -LiteralPath $env:FQAPP_FAKE_LOG -Value ($record | ConvertTo-Json -Compress)
    $outputIndex = [Array]::IndexOf($buildArguments, '-o')
    if ($outputIndex -lt 0) { throw 'missing fake go output argument' }
    $output = $buildArguments[$outputIndex + 1]
    $global:LASTEXITCODE = 0
    if ($env:FQAPP_FAKE_FAILURE -eq ($kind + '_empty')) { return }
    [System.IO.File]::WriteAllText($output, "built $kind")
    if ($kind -eq 'jni') {
        [System.IO.File]::WriteAllText([System.IO.Path]::ChangeExtension($output, '.h'), 'generated header')
    }
    if ($env:FQAPP_FAKE_FAILURE -eq ($kind + '_fail')) { $global:LASTEXITCODE = 9 }
}

function Get-BuildEnvironment {
    return [ordered]@{
        GOOS = $env:GOOS
        GOARCH = $env:GOARCH
        CGO_ENABLED = $env:CGO_ENABLED
        CC = $env:CC
        CGO_CFLAGS = $env:CGO_CFLAGS
    }
}

$beforeEnvironment = Get-BuildEnvironment
$beforeLocation = (Get-Location).Path
$failure = $null
try {
    $options = @{ SourceDir = $env:FQAPP_FAKE_SOURCE }
    if ($env:FQAPP_BUILD_JNI -eq '1') { $options.Jni = $true }
    if ($env:FQAPP_FORCE_RUNTIME -eq '1') { $options.ForceRuntime = $true }
    if ($env:FQAPP_FORCE_CONFIG -eq '1') { $options.ForceConfig = $true }
    & $env:FQAPP_BUILD_SCRIPT @options | Out-Null
} catch {
    $failure = $_.Exception.Message
}
$report = [ordered]@{
    failure = $failure
    beforeEnvironment = $beforeEnvironment
    afterEnvironment = Get-BuildEnvironment
    beforeLocation = $beforeLocation
    afterLocation = (Get-Location).Path
}
[System.IO.File]::WriteAllText($env:FQAPP_FAKE_REPORT, ($report | ConvertTo-Json -Depth 4))
