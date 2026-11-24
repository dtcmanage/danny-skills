Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell-startup.ps1')
$savedDotnet = $env:DOTNET_MultiCoreJitMinNumCpus
$savedLegacy = $env:COMPlus_MultiCoreJitMinNumCpus
$root = Join-Path ([IO.Path]::GetTempPath()) ('dt-startup-profile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
try {
    # Begin with the optimization enabled so an inherited test-harness setting
    # cannot mask a missing launch-boundary call.
    $env:DOTNET_MultiCoreJitMinNumCpus = '1'
    $env:COMPlus_MultiCoreJitMinNumCpus = '1'
    Disable-DtPowerShellStartupProfile
    $code = @'
[Runtime.ProfileOptimization]::StartProfile('dt-isolation-oracle')
1..100 | ForEach-Object { @{ value = $_ } | ConvertTo-Json | Out-Null }
[Runtime.ProfileOptimization]::StartProfile($null)
[Console]::Out.WriteLine($env:DOTNET_MultiCoreJitMinNumCpus)
'@
    foreach ($mode in @('control', 'mitigated')) {
        $cache = Join-Path $root $mode
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path $PSHOME 'pwsh'
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.ArgumentList.Add('-NoProfile')
        $info.ArgumentList.Add('-NonInteractive')
        $info.ArgumentList.Add('-EncodedCommand')
        $info.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
        # XDG changes only the disposable Unix cache, never HOME, credentials or
        # CLAUDE_CONFIG_DIR. Windows keeps its native cache location and checks
        # propagation only; do not create the oracle in a real Windows user cache.
        if (-not $IsWindows) { $info.Environment['XDG_CACHE_HOME'] = $cache }
        if ($mode -eq 'control') {
            $info.Environment['DOTNET_MultiCoreJitMinNumCpus'] = '1'
            $info.Environment['COMPlus_MultiCoreJitMinNumCpus'] = '1'
        }
        foreach ($name in @('DOTNET_MultiCoreJitNoProfileGather', 'COMPlus_MultiCoreJitNoProfileGather')) { $null = $info.Environment.Remove($name) }
        if ($IsWindows) {
            $windowsCode = '[Console]::Out.WriteLine($env:DOTNET_MultiCoreJitMinNumCpus)'
            $info.ArgumentList[$info.ArgumentList.Count - 1] = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($windowsCode))
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            $null = $process.Start()
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { throw "startup profile $mode child did not finish" }
            $expected = if ($mode -eq 'control') { '1' } else { '65535' }
            if ($process.ExitCode -ne 0 -or $out.GetAwaiter().GetResult().Trim() -cne $expected) {
                throw "startup profile $mode child failed: exit=$($process.ExitCode); stderr=$($err.GetAwaiter().GetResult())"
            }
            if (-not $IsWindows) {
                $profile = Join-Path $cache 'powershell/dt-isolation-oracle'
                if ($mode -eq 'control' -and (-not (Test-Path $profile) -or (Get-Item $profile).Length -lt 64)) { throw 'control did not create a real runtime JIT profile' }
                if ($mode -eq 'mitigated' -and (Test-Path $profile)) { throw 'mitigated child still wrote the runtime JIT profile' }
            }
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
    'PASS: child startup environment and runtime JIT profile isolation'
}
finally {
    $env:DOTNET_MultiCoreJitMinNumCpus = $savedDotnet
    $env:COMPlus_MultiCoreJitMinNumCpus = $savedLegacy
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
