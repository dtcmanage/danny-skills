#Requires -Version 7.0
# Supported operator entry. Probe the actual target before forwarding any control request.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('approve', 'decline', 'hold', 'note', 'delegate', 'resume')]
    [string]$Verb,
    [Parameter(Mandatory)][string]$RunFolder,
    [string]$BuildStatePath,
    [string]$RunId,
    [string]$Operation,
    [string]$Reason,
    [switch]$Decline,
    [string]$Message,
    [string]$Delegate,
    [string]$NoteId,
    [switch]$Clear,
    [switch]$Evidence,
    [switch]$AllowTempRunFolder,
    [switch]$Json,
    # Disposable compatibility tests only; overrides receive the identical mandatory preflight.
    [string]$TargetPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$allowed = @{
    BuildStatePath = @('approve', 'decline', 'hold', 'delegate', 'resume')
    RunId = @('approve', 'decline', 'hold', 'delegate', 'resume')
    Operation = @('approve', 'decline', 'hold'); Reason = @('approve', 'decline', 'hold')
    Decline = @('approve'); Message = @('note'); Delegate = @('delegate')
    NoteId = @('note'); Clear = @('hold', 'note', 'delegate'); Evidence = @('note')
}
foreach ($name in $allowed.Keys) {
    if ($PSBoundParameters.ContainsKey($name) -and $Verb -notin $allowed[$name]) {
        throw "DT_JOB_CONTROL_USAGE: -$name is invalid for '$Verb'; nothing was recorded."
    }
}
if ($Verb -in @('approve', 'decline', 'hold') -and [string]::IsNullOrWhiteSpace($Operation)) { throw 'DT_JOB_CONTROL_USAGE: -Operation is required.' }
if ($Clear -and (($Verb -eq 'hold' -and $PSBoundParameters.ContainsKey('Reason')) -or
    ($Verb -eq 'note' -and $PSBoundParameters.ContainsKey('Message')) -or
    ($Verb -eq 'delegate' -and $PSBoundParameters.ContainsKey('Delegate')))) { throw 'DT_JOB_CONTROL_USAGE: -Clear cannot also set a value.' }
if ($Verb -eq 'hold' -and -not $Clear -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'DT_JOB_CONTROL_USAGE: hold requires -Reason or -Clear.' }
if ($Verb -eq 'note' -and ((-not $Clear -and [string]::IsNullOrWhiteSpace($Message)) -or ($PSBoundParameters.ContainsKey('NoteId') -and -not $Clear))) { throw 'DT_JOB_CONTROL_USAGE: note requires -Message or -Clear [-NoteId].' }
if ($Verb -eq 'delegate' -and -not $Clear -and [string]::IsNullOrWhiteSpace($Delegate)) { throw 'DT_JOB_CONTROL_USAGE: delegate requires -Delegate or -Clear.' }

# Resolve the skill directory link, not merely the script file (whose parent may be a link).
$skill = Get-Item -LiteralPath (Split-Path -Parent $PSScriptRoot)
$linked = $skill.ResolveLinkTarget($true)
$skillRoot = if ($linked) { $linked.FullName } else { $skill.FullName }
$target = [IO.Path]::GetFullPath($(if ($TargetPath) { $TargetPath } else { Join-Path $skillRoot 'scripts/dt-job.ps1' }))
$file = Get-Item -LiteralPath $target
$linked = $file.ResolveLinkTarget($true)
if ($linked) { $target = $linked.FullName }
$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()

# A separate process isolates exit/error behavior of old copies. No run arguments reach the probe.
$info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
foreach ($arg in @('-NoProfile', '-File', $target, 'capabilities', '-Json')) { $info.ArgumentList.Add($arg) }
$process = [Diagnostics.Process]::new(); $process.StartInfo = $info
try {
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $text = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "DT_JOB_CONTROL_PREFLIGHT: target refused capabilities (exit $($process.ExitCode)): $errorText" }
    try { $caps = $text | ConvertFrom-Json -ErrorAction Stop } catch { throw 'DT_JOB_CONTROL_PREFLIGHT: invalid capabilities JSON.' }
    if ($caps.control_contract -lt 1 -or $caps.decline -isnot [bool] -or $caps.decline -cne $true -or
        $caps.persists_reason -isnot [bool] -or $caps.persists_reason -cne $true -or
        $caps.strict_binding -isnot [bool] -or $caps.strict_binding -cne $true -or $caps.script_path -cne $target -or $caps.sha256 -cne $hash -or
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) {
        throw 'DT_JOB_CONTROL_PREFLIGHT: unsupported contract/capabilities or target path/hash mismatch.'
    }
} finally { $process.Dispose() }

$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -notin @('TargetPath', 'Verb')) { $forward[$name] = $PSBoundParameters[$name] }
}
$forward.Verb = if ($Verb -eq 'decline') { 'approve' } else { $Verb }
if ($Verb -eq 'decline') { $forward.Decline = $true }
# Keep the caller environment and all underlying operator/lease/identity checks intact.
& $target @forward
