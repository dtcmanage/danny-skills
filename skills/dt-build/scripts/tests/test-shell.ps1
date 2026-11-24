# A fresh interpreter per call without starting another OS process. Real process/CLI tests
# continue to use pwsh. Never pool runspaces: functions, globals and modules must not leak.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell-startup.ps1')
Disable-DtPowerShellStartupProfile

if (-not ('DtTestShellHost' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Security;
using System.Management.Automation;
using System.Management.Automation.Host;
public sealed class DtTestShellUI : PSHostUserInterface {
    readonly PSHostRawUserInterface raw;
    readonly TextWriter errors;
    readonly TextWriter output;
    public DtTestShellUI(PSHostRawUserInterface raw, TextWriter errors, TextWriter output) { this.raw=raw; this.errors=errors; this.output=output; }
    public override PSHostRawUserInterface RawUI => raw;
    public override string ReadLine() { throw new NotSupportedException(); }
    public override SecureString ReadLineAsSecureString() { throw new NotSupportedException(); }
    public override void Write(string value) { output.Write(value); }
    public override void Write(ConsoleColor fg, ConsoleColor bg, string value) { output.Write(value); }
    public override void WriteLine(string value) { output.WriteLine(value); }
    public override void WriteErrorLine(string value) { errors.WriteLine(value); }
    public override void WriteDebugLine(string value) { }
    public override void WriteProgress(long id, ProgressRecord record) { }
    public override void WriteVerboseLine(string value) { }
    public override void WriteWarningLine(string value) { errors.WriteLine(value); }
    public override Dictionary<string,PSObject> Prompt(string caption,string message,Collection<FieldDescription> fields) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string caption,string message,string user,string target) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string caption,string message,string user,string target,PSCredentialTypes types,PSCredentialUIOptions options) { throw new NotSupportedException(); }
    public override int PromptForChoice(string caption,string message,Collection<ChoiceDescription> choices,int defaultChoice) { throw new NotSupportedException(); }
}
public sealed class DtTestShellHost : PSHost {
    readonly PSHost parent;
    readonly PSHostUserInterface ui;
    public int ExitCode = 0;
    public DtTestShellHost(PSHost parent, TextWriter errors, TextWriter output) { this.parent = parent; ui = new DtTestShellUI(parent.UI.RawUI,errors,output); }
    public override string Name => "dt-test-shell";
    public override Version Version => new Version(1,0);
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override PSHostUserInterface UI => ui;
    public override CultureInfo CurrentCulture => parent.CurrentCulture;
    public override CultureInfo CurrentUICulture => parent.CurrentUICulture;
    public override void SetShouldExit(int code) { ExitCode = code; }
    public override void EnterNestedPrompt() { throw new NotSupportedException(); }
    public override void ExitNestedPrompt() { throw new NotSupportedException(); }
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}
'@
}

function Invoke-TestShell {
    param([string]$File, [string[]]$Arguments = @(), [string]$Command,
        [string]$Stdin = '')
    # Never delegate UI writes to the outer ConsoleHost: it caches Console.Error and
    # would retain a disposed capture writer after the first interpreter exits.
    $errorText = [IO.StringWriter]::new()
    $consoleOutput = [IO.StringWriter]::new()
    $shellHost = [DtTestShellHost]::new($Host, $errorText, $consoleOutput)
    $runspace = [runspacefactory]::CreateRunspace($shellHost)
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $environment = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    $oldIn = [Console]::In
    $oldError = [Console]::Error
    $oldOut = [Console]::Out
    $oldDirectory = [Environment]::CurrentDirectory
    try {
        [Console]::SetIn([IO.StringReader]::new($Stdin))
        [Console]::SetError($errorText)
        [Console]::SetOut($consoleOutput)
        [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        $runspace.SessionStateProxy.Path.SetLocation((Get-Location).ProviderPath) | Out-Null
        if ($File) {
            $tokens = foreach ($arg in $Arguments) {
                if ($arg -match '^-[A-Za-z][A-Za-z0-9]*$') { $arg }
                else { "'" + $arg.Replace("'", "''") + "'" }
            }
            # Scripts invoked here expose their status through LASTEXITCODE. CLI-only
            # implicit/explicit -File policy cases stay on the real executable in the suite.
            $Command = "`$global:LASTEXITCODE = 0; & '" + $File.Replace("'", "''") + "' " + ($tokens -join ' ') + '; exit $global:LASTEXITCODE'
        }
        $null = $ps.AddScript($Command)
        $output = @()
        $exceptionText = ''
        try { $output = @($ps.Invoke() | ForEach-Object { [string]$_ }) }
        catch { $shellHost.ExitCode = 1; $exceptionText = $_.Exception.Message }
        $errors = @($ps.Streams.Error | ForEach-Object { [string]$_ })
        if ($ps.InvocationStateInfo.State -eq 'Failed') { $shellHost.ExitCode = 1 }
        if ($consoleOutput.ToString()) { $output = @($consoleOutput.ToString().TrimEnd("`r", "`n") -split "\r?\n") + $output }
        $exitCode = if ($IsWindows) { $shellHost.ExitCode } else { $shellHost.ExitCode -band 255 }
        return [pscustomobject]@{ Output = $output; ExitCode = $exitCode; ErrorText = (($errors + $exceptionText + $errorText.ToString()) -join "`n").Trim() }
    }
    finally {
        [Console]::SetIn($oldIn)
        [Console]::SetError($oldError)
        [Console]::SetOut($oldOut)
        [Environment]::CurrentDirectory = $oldDirectory
        foreach ($key in @([Environment]::GetEnvironmentVariables().Keys)) {
            if (-not $environment.ContainsKey($key)) { [Environment]::SetEnvironmentVariable($key, $null) }
        }
        foreach ($key in $environment.Keys) { [Environment]::SetEnvironmentVariable($key, $environment[$key]) }
        $ps.Dispose()
        $runspace.Dispose()
        $errorText.Dispose()
        $consoleOutput.Dispose()
    }
}

function Invoke-TestPwsh {
    param([string]$Script)
    $result = Invoke-TestShell -File $Script -Arguments $args
    $global:LASTEXITCODE = $result.ExitCode
    $result.Output
    if ($result.ErrorText) {
        if ($result.ExitCode) { Write-Error $result.ErrorText -ErrorAction Continue }
        else { [Console]::Error.WriteLine($result.ErrorText) }
    }
}

function Invoke-TestShards {
    param([string]$Script, [int]$Count)
    $logs = Join-Path ([IO.Path]::GetTempPath()) ('dt-test-shards-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $logs | Out-Null
    $workers = @(); $code = 0
    try {
        foreach ($part in 1..$Count) {
            $command = "& '" + $Script.Replace("'", "''") + "' -Shard $part"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $out = Join-Path $logs "$part.log"; $err = Join-Path $logs "$part.stderr.log"
            $process = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
            $workers += @{ Process=$process; Out=$out; Err=$err }
        }
        while (@($workers | Where-Object { -not $_.Process.HasExited }).Count) { Start-Sleep -Milliseconds 50 }
        foreach ($worker in $workers) {
            $worker.Process.WaitForExit()
            Get-Content -LiteralPath $worker.Out | Write-Output
            Get-Content -LiteralPath $worker.Err | Write-Output
            if ($worker.Process.ExitCode -ne 0) { $code = 1 }
        }
        Write-Output "Shard logs: $logs"
    }
    finally {
        foreach ($worker in $workers) {
            if (-not $worker.Process.HasExited) { $worker.Process.Kill($true); $worker.Process.WaitForExit() }
            $worker.Process.Dispose()
        }
    }
    $global:LASTEXITCODE = $code
}
