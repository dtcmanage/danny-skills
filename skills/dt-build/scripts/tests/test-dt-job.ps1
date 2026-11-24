param(
    [switch]$GeneratorDifferentialOnly,
    [string]$GeneratorPath,
    [string]$HeadMeasurementPath,
    [ValidateRange(0, 2)][int]$Shard = 0,
    [switch]$Serial
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:DT_BUILD_HEADLESS = '1' # Fixtures are automation, never borrow the test runner's director.
$script:passed = 0
$script:failed = 0
. (Join-Path $PSScriptRoot 'test-shell.ps1')

# Two independent fixture groups, each in its own process/environment and GUID temp root.
# Keep the public suite complete by default; the gate accounts for its two worker slots.
if ($Shard -eq 0 -and -not $GeneratorDifferentialOnly -and -not $Serial) {
    $logs = Join-Path ([IO.Path]::GetTempPath()) ('dt-job-shards-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $logs | Out-Null
    $workers = @()
    $wall = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($part in 1,2) {
            $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -Shard $part"
            if ($GeneratorPath) { $command += " -GeneratorPath '" + $GeneratorPath.Replace("'", "''") + "'" }
            if ($HeadMeasurementPath) { $command += " -HeadMeasurementPath '" + $HeadMeasurementPath.Replace("'", "''") + "'" }
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $out = Join-Path $logs "$part.log"; $err = Join-Path $logs "$part.stderr.log"
            $process = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
            $workers += @{ Process=$process; Out=$out; Err=$err }
        }
        while (@($workers | Where-Object { -not $_.Process.HasExited }).Count) { Start-Sleep -Milliseconds 50 }
        $totalPassed = 0; $totalFailed = 0; $exitCode = 0
        foreach ($worker in $workers) {
            $worker.Process.WaitForExit()
            $output = Get-Content -LiteralPath $worker.Out
            $output | Write-Output
            Get-Content -LiteralPath $worker.Err | Write-Output
            foreach ($line in $output) {
                if ($line -match '^SUMMARY: (\d+) passed, (\d+) failed$') { $totalPassed += [int]$Matches[1]; $totalFailed += [int]$Matches[2] }
            }
            if ($worker.Process.ExitCode -ne 0) { $exitCode = 1 }
        }
        Write-Output "SUMMARY: $totalPassed passed, $totalFailed failed; two shards, $([Math]::Round($wall.Elapsed.TotalSeconds,2))s; logs $logs"
    }
    finally {
        foreach ($worker in $workers) {
            if (-not $worker.Process.HasExited) { $worker.Process.Kill($true); $worker.Process.WaitForExit() }
            $worker.Process.Dispose()
        }
    }
    exit $exitCode
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failed++; Write-Output "ASSERT_FAIL: $Message"; return }
    $script:passed++
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$readEvidence = Join-Path $scriptDir 'read-evidence.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-job-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
# Start-Process -WindowStyle exists only on Windows; splat it so the same calls run on Linux.
$HiddenWindow = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }
# The exit-code cases use `cmd /c exit N` as the native command that fails with a known code. Off
# Windows a `cmd` stand-in on PATH runs `/c <command>` through sh, so every case text stays identical.
if (-not $IsWindows) {
    $cmdShimDir = Join-Path $tempRoot 'cmd-shim'
    New-Item -ItemType Directory -Path $cmdShimDir -Force | Out-Null
    $cmdShim = Join-Path $cmdShimDir 'cmd'
    [IO.File]::WriteAllText($cmdShim, "#!/bin/sh`n[ `"`$1`" = /c ] && shift`nexec /bin/sh -c `"`$*`"`n")
    & chmod +x $cmdShim
    $env:PATH = $cmdShimDir + [IO.Path]::PathSeparator + $env:PATH
}

function New-RunFolder {
    param([string]$Name)
    $path = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-DtJob {
    param([string[]]$Arguments)
    $result = Invoke-TestShell -File $dtJob -Arguments ($Arguments + @('-AllowTempRunFolder', '-Json'))
    $raw = $result.Output; $LASTEXITCODE = $result.ExitCode
    if ($LASTEXITCODE -ne 0) { throw "dt-job $($Arguments -join ' ') exited $LASTEXITCODE" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Get-JobRecord {
    param([string]$RunFolder, [string]$JobId)
    return (Get-Content -Raw -LiteralPath (Join-Path $RunFolder "jobs/$JobId.json") | ConvertFrom-Json)
}

function Get-EvidenceError {
    param([hashtable]$Arguments)
    # Match a child pwsh's working directory while capturing the unformatted exception.
    $originalDirectory = [Environment]::CurrentDirectory
    try {
        [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        & $readEvidence @Arguments | Out-Null
    }
    catch { return $_.Exception.Message }
    finally { [Environment]::CurrentDirectory = $originalDirectory }
    throw 'ASSERT_FAIL: read-evidence unexpectedly succeeded'
}

function Wait-JobState {
    param([string]$RunFolder, [string]$JobId, [scriptblock]$Until, [int]$TimeoutSec = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $record = Get-JobRecord -RunFolder $RunFolder -JobId $JobId
        if (& $Until $record) { return $record }
        Start-Sleep -Milliseconds 250
    }
    # Preserve the record and runner diagnostics in the suite log before fixture cleanup.
    Get-JobRecord -RunFolder $RunFolder -JobId $JobId | ConvertTo-Json -Depth 12 | Write-Host
    foreach ($file in @('runner.log','runner-stderr.log','stdout.log','stderr.log','spec.json')) {
        $path = Join-Path $RunFolder "jobs/$JobId/$file"
        if (Test-Path -LiteralPath $path) { Write-Host "DIAGNOSTIC: $path"; Get-Content -LiteralPath $path -Tail 40 | Write-Host }
    }
    throw "TIMEOUT waiting on $JobId in $RunFolder (status $((Get-JobRecord -RunFolder $RunFolder -JobId $JobId).status))"
}

function Wait-JobTerminal {
    param([string]$RunFolder, [string]$JobId, [int]$TimeoutSec = 60)
    return (Wait-JobState -RunFolder $RunFolder -JobId $JobId -TimeoutSec $TimeoutSec -Until { param($r) $r.status -notin @('queued', 'running') })
}

# A test that needs a job to be running holds it on a file, never on the clock.
function New-HeldJobCommand {
    param([string]$ReleasePath, [int]$ExitCode = 0)
    return "`$deadline = [DateTime]::UtcNow.AddSeconds(120); while (-not (Test-Path -LiteralPath '$($ReleasePath.Replace("'", "''"))') -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 100 }; exit $ExitCode"
}

function Test-ProcessGone {
    param($ProcessId)
    if (-not $ProcessId) { return $true }
    return ($null -eq (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))
}


function Test-GeneratorDifferential {
    $runnerPath = if ($GeneratorPath) { $GeneratorPath } else { Join-Path $scriptDir 'dt-job-runner.ps1' }
    # Frozen HEAD control (07a786f6c42c3aa2afc01b9820ff0c3f62952a86): keep this measurement stable after merge.
    $head = @'
function Get-DtJobCommandScript {
    # Exit like `pwsh -Command`: the outcome of the final statement decides. LASTEXITCODE is reset just
    # before that statement, so an earlier handled native failure does not leak into the exit code, while
    # a failing final native command keeps its real exit code instead of pwsh's flattened 1.
    param([Parameter(Mandatory)][string]$Command)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    $body = "`$global:LASTEXITCODE = 0`n$Command"
    if (@($errors).Count -eq 0 -and $null -ne $ast.EndBlock -and @($ast.EndBlock.Statements).Count -gt 0) {
        $offset = @($ast.EndBlock.Statements)[-1].Extent.StartOffset
        $body = $Command.Substring(0, $offset) + "`$global:LASTEXITCODE = 0; " + $Command.Substring($offset)
    }
    return "$body`n`$dtJobOk = `$?`nif (`$global:LASTEXITCODE -ne 0) { exit `$global:LASTEXITCODE }`nif (-not `$dtJobOk) { exit 1 }`nexit 0`n"
}
'@
    function Get-GeneratorText([string]$text) {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        return $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DtJobCommandScript'},$true).Extent.Text
    }
    $fnHead=Get-GeneratorText $head
    $fnCurrent=Get-GeneratorText ([IO.File]::ReadAllText($runnerPath))
$s=Join-Path $tempRoot 'inner native fail.ps1'; [IO.File]::WriteAllText($s,"cmd /c exit 3`n")
$ok=Join-Path $tempRoot 'inner no native.ps1'; [IO.File]::WriteAllText($ok,"Write-Output fine`n")
$cdfail=Join-Path $tempRoot 'inner cd fail.ps1'; [IO.File]::WriteAllText($cdfail,"Set-Location `$env:TEMP; cmd /c exit 3`n")
$wild=Join-Path $tempRoot 'inner[1].ps1'; [IO.File]::WriteAllText($wild,"cmd /c exit 3`n")
$log=Join-Path $tempRoot 'tee.log'
$cases=[ordered]@{
 '0a rc echo'='cmd /c exit 3; Write-Output "rc=$LASTEXITCODE"'
 '0b assign'='cmd /c exit 3; $code=$LASTEXITCODE'
 '0c if reader'='cmd /c exit 1; if ($LASTEXITCODE -eq 1) { Write-Output changes }'
 '0d if/else tolerate'='cmd /c exit 3; if ($LASTEXITCODE -eq 3) { Write-Output tolerated } else { exit 5 }'
 '0e || recovered'='cmd /c exit 3 || Write-Output recovered'
 'P3 bare'='cmd /c exit 3'
 'P3 if-exit'='cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
 'P3 plain exit'='cmd /c exit 3; exit $LASTEXITCODE'
 'P3 & script'="& '$s'"
 'P3 . script'=". '$s'"
 'P3 function'='function f { cmd /c exit 3 }; f'
 'P3 & block'='& { cmd /c exit 3 }'
 'P5 if $? else'='cmd /c exit 3; if ($?) { Write-Output ok } else { exit 5 }'
 'X outnull'='cmd /c exit 3 | Out-Null'
 'X multiline'="Write-Output a`ncmd /c exit 3"
 'X multiline2'="cmd /c exit 3`nWrite-Output b"
 'X noparse'='if ($true) {'
 'X tee'="cmd /c exit 3 2>&1 | Tee-Object -FilePath '$log'"
 # hunting for false success: HEAD non-zero, tree 0
 'H try-finally'='try { cmd /c exit 3 } finally { }'
 'H try-finally-cmdlet'='try { cmd /c exit 3 } finally { Write-Verbose done }'
 'H push try pop'='Push-Location $env:TEMP; try { cmd /c exit 3 } finally { Pop-Location }'
 'H try-catch'='try { cmd /c exit 3 } catch { Write-Output c }'
 'H if-compound'='if ($true) { cmd /c exit 3 }'
 'H if-then-echo'='if ($true) { cmd /c exit 3; Write-Output done }'
 'H foreach'='foreach ($i in 1..2) { cmd /c exit 3 }'
 'H for'='for ($i=0;$i -lt 1;$i++) { cmd /c exit 3 }'
 'H while'='$i=0; while ($i -lt 1) { $i++; cmd /c exit 3 }'
 'H switch'='switch (1) { 1 { cmd /c exit 3 } }'
 'H paren'='(cmd /c exit 3)'
 'H subexpr'='$(cmd /c exit 3)'
 'H array'='@(cmd /c exit 3)'
 'H assign'='$o = cmd /c exit 3'
 'H assign-echo'='$o = cmd /c exit 3; $o'
 'H paren pipe'='(cmd /c exit 3) | Out-Null'
 'H foreach-object'='1..2 | ForEach-Object { cmd /c exit 3 }'
 'H % alias'='1..2 | % { cmd /c exit 3 }'
 'H iex'='Invoke-Expression "cmd /c exit 3"'
 'H icm'='Invoke-Command { cmd /c exit 3 }'
 'H where'='1 | Where-Object { cmd /c exit 3; $true }'
 'H chain script'="Write-Output a && & '$s'"
 'H chain function'='function f { cmd /c exit 3 }; Write-Output a && f'
 'H chain block'='Write-Output a && & { cmd /c exit 3 }'
 'H chain native'='Write-Output a && cmd /c exit 3'
 'H script cd then fail'="& '$cdfail'"
 'H wildcard path'="& '$wild'"
 'H write-output paren'='Write-Output (cmd /c exit 3)'
 'H ternary'='$true ? (cmd /c exit 3) : 0'
 'H script then echo'="& '$s'; Write-Output done"
 # false failure: HEAD 0, tree non-zero
 'F then no-native script'="cmd /c exit 3; & '$ok'"
 'F then function'='function g { Write-Output hi }; cmd /c exit 3; g'
 'F then mkdir'="cmd /c exit 3; mkdir -Force '$tempRoot\m' | Out-Null"
 'F then compress'="cmd /c exit 3; Compress-Archive -Force -Path '$s' -DestinationPath '$tempRoot\a.zip'"
 'F git-like then block'='cmd /c exit 1; & { Write-Output handled }'
 'F then return'='cmd /c exit 3; return'
 # prefix placement
 'U using'='using namespace System.Text; cmd /c exit 0; Write-Output ok'
 'U param'='param($x=1) Write-Output $x'
 'U requires'="#requires -Version 7`nWrite-Output ok"
 'U comment only'='# nothing'
 'U trap'='trap { exit 9 }; throw "x"'
}

    $pinnedHead=@{
        '0a rc echo' = 0
        '0b assign' = 0
        '0c if reader' = 0
        '0d if/else tolerate' = 5
        '0e || recovered' = 3
        'P3 bare' = 3
        'P3 if-exit' = 0
        'P3 plain exit' = 0
        'P3 & script' = 3
        'P3 . script' = 3
        'P3 function' = 3
        'P3 & block' = 3
        'P5 if $? else' = 0
        'X outnull' = 3
        'X multiline' = 3
        'X multiline2' = 0
        'X noparse' = 1
        'X tee' = 3
        'H try-finally' = 3
        'H try-finally-cmdlet' = 3
        'H push try pop' = 3
        'H try-catch' = 3
        'H if-compound' = 3
        'H if-then-echo' = 3
        'H foreach' = 3
        'H for' = 3
        'H while' = 3
        'H switch' = 3
        'H paren' = 3
        'H subexpr' = 3
        'H array' = 3
        'H assign' = 3
        'H assign-echo' = 0
        'H paren pipe' = 3
        'H foreach-object' = 3
        'H % alias' = 3
        'H iex' = 3
        'H icm' = 3
        'H where' = 3
        'H chain script' = 3
        'H chain function' = 3
        'H chain block' = 3
        'H chain native' = 3
        'H script cd then fail' = 3
        'H wildcard path' = 3
        'H write-output paren' = 3
        'H ternary' = 3
        'H script then echo' = 0
        'F then no-native script' = 0
        'F then function' = 0
        'F then mkdir' = 0
        'F then compress' = 0
        'F git-like then block' = 0
        'F then return' = 0
        'U using' = 0
        'U param' = 0
        'U requires' = 0
        'U comment only' = 0
        'U trap' = 9
        'reader changed code'=0
        'reader scoped'=0
        'reader script scope'=0
        'reader nested string'=8
        'reader failure'=0
        'reader if else'=5
        'ScriptPath implicit'=0
        'ScriptPath explicit'=3
    }

    $cases['reader changed code']='cmd /c exit 3; if ($LASTEXITCODE -eq 3) { cmd /c exit 4 }'
    $cases['reader scoped']='cmd /c exit 3; if (${global:LASTEXITCODE} -ne 0) { exit ${global:LASTEXITCODE} }'
    $cases['reader script scope']='cmd /c exit 3; if ($script:LASTEXITCODE -ne 0) { exit $script:LASTEXITCODE }'
    $cases['reader nested string']='cmd /c exit 3; if ("rc=$global:LASTEXITCODE" -eq "rc=3") { Write-Output tolerated } else { exit 8 }'
    $cases['reader failure']='cmd /c exit 3; if ($LASTEXITCODE -eq 3) { Write-Error failed -ErrorAction Continue }'
    $cases['reader if else']='cmd /c exit 3; if ($LASTEXITCODE -eq 0) { exit 5 } else { Write-Output tolerated }'
    $cases['ScriptPath implicit']=$s
    $explicit=Join-Path $tempRoot 'explicit.ps1'
    Write-Utf8 $explicit 'cmd /c exit 3; exit $LASTEXITCODE'
    $cases['ScriptPath explicit']=$explicit

    # Only exact exits and exit guards depart from the frozen HEAD generator.
    $readerExpected=@{
        'P3 if-exit'=3; 'P3 plain exit'=3; 'reader scoped'=3; 'reader script scope'=3
    }
    # name | frozen HEAD exit | candidate B with null guard exit | command
    $pins = @'
exit-reader-plain|0|3|cmd /c exit 3; exit $LASTEXITCODE
exit-reader-scoped-braced|0|3|cmd /c exit 3; exit ${global:LASTEXITCODE}
gate-exit-code|0|3|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
gate-exit-1|0|1|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit 1 }
gate-not-taken-tolerated|0|0|cmd /c exit 3; if ($LASTEXITCODE -eq 1) { Write-Output t }
echo-reader|0|0|cmd /c exit 3; Write-Output "rc=$LASTEXITCODE"
assign-reader|0|0|cmd /c exit 3; $code=$LASTEXITCODE
ifelse-tolerate|1|1|cmd /c exit 5; if ($LASTEXITCODE -eq 5) { Write-Output ok } else { exit 1 }
same-code-rerun-plain|3|3|cmd /c exit 3; cmd /c exit 3
same-code-rerun-echo|3|3|cmd /c exit 3; if ($true) { cmd /c exit 3; Write-Output "rc=$LASTEXITCODE" }
env-is-not-exit-state|1|1|cmd /c exit 1; if ($true) { cmd /c exit 1; $env:LASTEXITCODE }
handled-earlier-cmdlet|0|0|cmd /c exit 3; Write-Output done
nested-try|3|3|Push-Location $env:TEMP; try { cmd /c exit 3 } finally { Pop-Location }
final-definition|0|0|cmd /c exit 3; function z {}
final-write-error|1|1|cmd /c exit 0; Write-Error x
or-chain|3|3|cmd /c exit 3 || Write-Output recovered
parse-error|1|1|if (
using-namespace|0|0|using namespace System.Text; [StringBuilder]::new() | Out-Null
param-first|3|3|param($x=3) cmd /c exit $x
unset-gate-ne|0|0|Set-Location $env:TEMP; if ($LASTEXITCODE -ne 0) { exit 1 }
unset-gate-eq|3|3|Set-Location $env:TEMP; if ($LASTEXITCODE -eq 0) { cmd /c exit 3 }
strict-unset|0|0|Set-StrictMode -Version Latest; Write-Output x
guard-two-statements|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { Write-Output failed; exit 9 }
guard-exit-then-statement|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit 9; Write-Output unreachable }
guard-with-else|5|5|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit 9 } else { exit 5 }
guard-env-read|0|0|$env:LASTEXITCODE='3'; cmd /c exit 3; if ($env:LASTEXITCODE -ne '3') { exit 9 }
guard-env-numeric|1|1|$env:LASTEXITCODE=3; cmd /c exit 3; if ($env:LASTEXITCODE -ne 0) { exit 1 }
exit-env-numeric|3|3|$env:LASTEXITCODE=3; cmd /c exit 3; exit $env:LASTEXITCODE
guard-env-braced-numeric|1|1|${env:LASTEXITCODE}=3; cmd /c exit 3; if (${env:LASTEXITCODE} -ne 0) { exit 1 }
exit-env-braced-numeric|3|3|${env:LASTEXITCODE}=3; cmd /c exit 3; exit ${env:LASTEXITCODE}
guard-numeric-or|1|1|cmd /c exit 3; if ($LASTEXITCODE -or 1) { exit 1 }
guard-numeric-and|0|0|cmd /c exit 3; if ($LASTEXITCODE -and 0) { exit 1 }
guard-numeric-xor|1|1|cmd /c exit 3; if ($LASTEXITCODE -xor 1) { exit 1 }
guard-numeric-band|0|0|cmd /c exit 3; if ($LASTEXITCODE -band 1) { exit 1 }
guard-numeric-plus|1|1|cmd /c exit 3; if ($LASTEXITCODE + 1) { exit 1 }
guard-numeric-like|0|0|cmd /c exit 3; if ($LASTEXITCODE -like 3) { exit 1 }
guard-numeric-match|0|0|cmd /c exit 3; if ($LASTEXITCODE -match 3) { exit 1 }
guard-string-literal|9|9|cmd /c exit 3; if ('$LASTEXITCODE' -eq '$LASTEXITCODE') { exit 9 }
strict-unset-guard|0|0|Set-StrictMode -Version Latest; if ($LASTEXITCODE -ne 0) { exit 9 }
guard-not-taken-exit|0|0|cmd /c exit 3; if ($LASTEXITCODE -eq 5) { exit 9 }
guard-parse-int|1|1|cmd /c exit 0; if ($LASTEXITCODE -ne [int]::Parse("x")) { exit 1 }
guard-strict-undefined|1|1|Set-StrictMode -Version Latest; cmd /c exit 0; if ($LASTEXITCODE -ne 0 -or $undefinedVar) { exit 1 }
guard-null-method|1|1|cmd /c exit 0; if ($LASTEXITCODE -eq 0 -and $null.Foo()) { exit 1 }
guard-bad-cast|1|1|cmd /c exit 0; if ([int]"x" -ne $LASTEXITCODE) { exit 1 }
guard-divide-zero|1|1|cmd /c exit 0; if ((1 / $LASTEXITCODE) -gt 5) { exit 1 }
guard-inline-throw|1|1|cmd /c exit 0; if (($LASTEXITCODE -ne 0) -or (throw "x")) { exit 1 }
guard-missing-command|1|1|cmd /c exit 0; if ($LASTEXITCODE -eq 0 -and (Get-NoSuchCommandZ)) { exit 1 }
guard-throwing-function|1|1|function check { throw "bad" }; cmd /c exit 0; if ($LASTEXITCODE -eq 0 -and (check)) { exit 1 }
guard-native-or|7|7|if ($LASTEXITCODE -ne 0 -or (cmd /c exit 7)) { exit 1 }
guard-native-or-after-zero|7|7|cmd /c exit 0; if ($LASTEXITCODE -ne 0 -or (cmd /c exit 7)) { exit 1 }
guard-native-first|7|7|if ((cmd /c exit 7) -or $LASTEXITCODE -eq 9) { exit 1 }
guard-native-scriptblock|2|2|if (& { cmd /c exit 2; $LASTEXITCODE -eq 9 }) { exit 1 }
guard-native-script|3|3|cmd /c exit 0; if ($LASTEXITCODE -ne 0 -or (& '{NATIVE_SCRIPT}')) { exit 1 }
guard-assignment|5|5|if (($global:LASTEXITCODE = 5) -eq 0) { exit 1 }
guard-scriptblock-expression|0|0|if (($LASTEXITCODE -ne 0) -or ({ $false } -eq $null)) { exit 1 }
guard-postincrement|1|1|cmd /c exit 0; if ($global:LASTEXITCODE++ -ne 0) { exit 1 }
guard-preincrement|1|1|cmd /c exit 0; if (++$global:LASTEXITCODE -eq 0) { exit 1 }
guard-postdecrement|-1|-1|cmd /c exit 0; if ($LASTEXITCODE-- -ne 0) { exit 1 }
guard-predecrement|1|1|cmd /c exit 0; if (--$global:LASTEXITCODE -ne 0) { exit 1 }
guard-increment-unset|1|1|if ($LASTEXITCODE++ -ne 0) { exit 1 }
guard-ref-set|5|5|cmd /c exit 0; if ($LASTEXITCODE -ne 0 -or ([ref]$global:LASTEXITCODE).set_Value(5)) { exit 1 }
guard-psvariable-set|5|5|cmd /c exit 0; if ($LASTEXITCODE -ne 0 -or $ExecutionContext.SessionState.PSVariable.Set('global:LASTEXITCODE',5)) { exit 1 }
guard-scriptproperty-native|7|7|cmd /c exit 0; $o=[pscustomobject]@{}; $o | Add-Member ScriptProperty P { cmd /c exit 7; $null }; if ($LASTEXITCODE -ne 0 -or $o.P) { exit 1 }
guard-scriptproperty-write|5|5|cmd /c exit 0; $o=[pscustomobject]@{}; $o | Add-Member ScriptProperty P { $global:LASTEXITCODE=5; $null }; if ($LASTEXITCODE -ne 0 -or $o.P) { exit 1 }
guard-scriptmethod-native|7|7|cmd /c exit 0; $o=[pscustomobject]@{}; $o | Add-Member ScriptMethod M { cmd /c exit 7; $null }; if ($LASTEXITCODE -ne 0 -or $o.M()) { exit 1 }
guard-tostring-override|7|7|$o=[pscustomobject]@{}; $o | Add-Member -Force ScriptMethod ToString { cmd /c exit 7; "z" }; cmd /c exit 0; if ("$o$LASTEXITCODE" -eq "q") { exit 1 }
guard-compound-or|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne 0 -or $false) { exit 9 }
guard-compound-and|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne 0 -and $true) { exit 9 }
guard-reversed|0|0|cmd /c exit 3; if (0 -ne $LASTEXITCODE) { exit 9 }
guard-parenthesized|0|0|cmd /c exit 3; if (($LASTEXITCODE -ne 0)) { exit 9 }
guard-parenthesized-left|0|0|cmd /c exit 3; if (($LASTEXITCODE) -ne 0) { exit 9 }
guard-parenthesized-right|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne (0)) { exit 9 }
guard-not|1|1|cmd /c exit 3; if (-not $LASTEXITCODE) { exit 1 }
guard-not-comparison|1|1|cmd /c exit 3; if (-not ($LASTEXITCODE -ne 0)) { exit 1 }
guard-bang|1|1|cmd /c exit 3; if (!$LASTEXITCODE) { exit 1 }
guard-second-variable|0|0|$x=0; cmd /c exit 3; if ($LASTEXITCODE -ne $x) { exit 9 }
guard-member-left|0|0|cmd /c exit 3; if ($LASTEXITCODE.ToString() -ne '0') { exit 9 }
guard-string-right|0|0|cmd /c exit 3; if ($LASTEXITCODE -ne '0') { exit 9 }
guard-shadowed-get-variable|0|0|function Get-Variable { throw 'x' }; cmd /c exit 0; if ($LASTEXITCODE -ne 0) { exit 4 }
guard-body-parse-error|0|1|cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit [int]::Parse("x") }
guard-body-strict-undefined|0|1|Set-StrictMode -Version Latest; cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit $undefinedVar }
strict-unset-exact-exit|0|1|Set-StrictMode -Version Latest; Write-Output x; exit $LASTEXITCODE
'@
    # Limitation: strict mode with an unset code on an exact exit fails closed, matching native -Command.
    # guard-parse-int, guard-strict-undefined, guard-null-method, guard-bad-cast,
    # guard-divide-zero and guard-inline-throw require HEAD's exact bytes AND exit,
    # so they are not reader exceptions.
    $exceptionNames=@('exit-reader-plain','exit-reader-scoped-braced','gate-exit-code','gate-exit-1','unset-gate-ne','strict-unset-guard','guard-not-taken-exit',
        'guard-shadowed-get-variable','guard-body-parse-error','guard-body-strict-undefined','strict-unset-exact-exit')
    foreach ($line in ($pins -split "`n")) {
        $parts=$line.TrimEnd("`r") -split '\|',4
        $cases[$parts[0]]=$parts[3].Replace('{NATIVE_SCRIPT}', $s)
        $pinnedHead[$parts[0]]=[int]$parts[1]
        if ($parts[0] -in $exceptionNames) { $readerExpected[$parts[0]]=[int]$parts[2] }
    }
    foreach ($variable in @('$lastexitcode','${LASTEXITCODE}','$global:LASTEXITCODE','$script:LASTEXITCODE','${local:LASTEXITCODE}','${private:LASTEXITCODE}')) {
        $name="exact-scope-$variable"
        $cases[$name]='cmd /c exit 3; exit '+$variable
        $pinnedHead[$name]=0; $readerExpected[$name]=3
    }
    $guardBytePins=@{}
    foreach ($scope in @('', 'global:', 'script:', 'local:', 'private:')) {
        foreach ($braced in @($false, $true)) {
            $variable=if($braced){'${'+$scope+'LASTEXITCODE}'}else{'$'+$scope+'LASTEXITCODE'}
            $name="exact-guard-scope-$variable"
            $cases[$name]='cmd /c exit 3; if ('+$variable+' -ne 0) { exit '+$variable+' }'
            $pinnedHead[$name]=0; $readerExpected[$name]=3; $guardBytePins[$name]=$true
        }
    }
    foreach ($prefix in @('', 'i', 'c')) {
        foreach ($op in @('eq','ne','gt','ge','lt','le')) {
            $name="exact-guard-operator-$prefix$op"
            $cases[$name]='cmd /c exit 3; if ($LASTEXITCODE -'+$prefix+$op+' 3) { exit 9 }'
            $pinnedHead[$name]=if($op -in @('ne','lt','le')){9}else{0}
            $readerExpected[$name]=if($op -in @('eq','ge','le')){9}else{0}
            $guardBytePins[$name]=$true
        }
    }
    # A newline inside braces is part of the variable name, so neither exact form applies.
    $cases['exit-braced-trailing-newline']='cmd /c exit 3; exit ${LASTEXITCODE' + "`n}"
    $pinnedHead['exit-braced-trailing-newline']=0
    $cases['guard-braced-trailing-newline']='cmd /c exit 3; if (${LASTEXITCODE' + "`n} -ne 0) { exit 9 }"
    $pinnedHead['guard-braced-trailing-newline']=9
    if (-not $IsWindows) {
        # Linux reports exit codes as one byte (exit -1 is 255), and `mkdir` there is the system program,
        # not PowerShell's function, so that case uses the cmdlet it stands for on Windows.
        foreach ($table in @($pinnedHead, $readerExpected)) { foreach ($key in @($table.Keys)) { $table[$key] = $table[$key] -band 0xFF } }
        if ($cases.Contains('F then mkdir')) { $cases['F then mkdir'] = "cmd /c exit 3; New-Item -ItemType Directory -Force -Path '$tempRoot/m' | Out-Null" }
    }
    $measurements=@('HEAD control commit: 07a786f6c42c3aa2afc01b9820ff0c3f62952a86')
    foreach($name in $cases.Keys) {
        $command=$cases[$name]
        $isScript=$name.StartsWith('ScriptPath ')
        $headScript=& { . ([scriptblock]::Create($fnHead)); Get-DtJobCommandScript $command }
        try {
            $currentScript=& { . ([scriptblock]::Create($fnCurrent)); Get-DtJobCommandScript $command }
        }
        catch {
            Assert-True $false "current generator did not throw: $name"
            continue
        }
        if ($name -eq 'gate-exit-code') {
            # Pin the qualified null guard and the measured status-preserving tail.
            $exactGuardScript = 'cmd /c exit 3; if ($null -eq (Microsoft.PowerShell.Utility\Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore)) { $global:LASTEXITCODE = 0 }; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }' + "`n`$dtJobOk = `$?`nif (-not `$dtJobOk) { exit 1 }`nexit 0`n"
            Assert-True ($currentScript -ceq $exactGuardScript) 'exact guard bytes include qualified null guard at final statement and measured status-preserving exit 0 tail'
        }
        if ($guardBytePins.ContainsKey($name)) {
            $guard='if ($null -eq (Microsoft.PowerShell.Utility\Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore)) { $global:LASTEXITCODE = 0 }; '
            $exactGuardScript=$command.Insert($command.IndexOf('if ('), $guard)+"`n`$dtJobOk = `$?`nif (-not `$dtJobOk) { exit 1 }`nexit 0`n"
            Assert-True ($currentScript -ceq $exactGuardScript) "allowlisted guard exact bytes: $name"
        }
        $path=Join-Path $tempRoot 'differential.ps1'
        Write-Utf8 $path $headScript
        $launch=if($isScript){$command}else{$path}
        # ScriptPath and unset-variable exit status exercise the executable's CLI policy.
        # The other generated programs end in an explicit exit, handled by the isolated host.
        if ($isScript) { $null = & pwsh -NoProfile -NonInteractive -File $launch 2>&1; $headCode = $LASTEXITCODE }
        elseif ($name -eq 'strict-unset-exact-exit') { $null = & pwsh -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($headScript))) 2>&1; $headCode = $LASTEXITCODE }
        else { $headCode = (Invoke-TestShell -Command $headScript).ExitCode }
        Assert-True ($headCode -eq $pinnedHead[$name]) "HEAD pin: $name measured=$headCode pinned=$($pinnedHead[$name])"
        Write-Utf8 $path $currentScript
        if ($isScript) { $null = & pwsh -NoProfile -NonInteractive -File $launch 2>&1; $currentCode = $LASTEXITCODE }
        elseif ($name -eq 'strict-unset-exact-exit') { $null = & pwsh -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($currentScript))) 2>&1; $currentCode = $LASTEXITCODE }
        else { $currentCode = (Invoke-TestShell -Command $currentScript).ExitCode }
        $expected=if($readerExpected.ContainsKey($name)){$readerExpected[$name]}else{$pinnedHead[$name]}
        Assert-True ($currentCode -eq $expected) "differential: $name HEAD=$headCode current=$currentCode expected=$expected"
        if(-not $isScript -and -not $readerExpected.ContainsKey($name)) {
            Assert-True ($currentScript -ceq $headScript) "non-reader generated bytes match HEAD: $name"
        }
        $measurements += "$name | HEAD=$headCode | current=$currentCode | expected=$expected | allowed_reader=$($readerExpected.ContainsKey($name))"
    }

    # Exercise actual dt-job start on disposable scripts and job state, with fake native work.
    $copyRoot=Join-Path $tempRoot 'job-copy/skills/dt-build/scripts'
    New-Item -ItemType Directory -Path $copyRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $scriptDir '*') -Destination $copyRoot -Recurse
    $copySecurityRoot=Join-Path $tempRoot 'job-copy/scripts/security'
    New-Item -ItemType Directory -Path $copySecurityRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $scriptDir '../../../scripts/security/redact-secrets.ps1') -Destination $copySecurityRoot
    $copyRun=New-RunFolder 'exact-form-jobs'
    foreach ($case in @(
        @{command='cmd /c exit 3; exit $LASTEXITCODE';code=3},
        @{command='cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }';code=3},
        @{command='cmd /c exit 3; Write-Output handled';code=0}
    )) {
        $started=& pwsh -NoProfile -File (Join-Path $copyRoot 'dt-job.ps1') start -RunFolder $copyRun -Command $case.command -AllowTempRunFolder -Json | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0) "temp-copy dt-job starts: $($case.command)"
        $record=Wait-JobTerminal $copyRun $started.job_id
        Assert-True ($record.exit_code -eq $case.code -and $record.status -eq $(if($case.code){'failed'}else{'succeeded'})) "temp-copy dt-job exact form: $($case.command) exit=$($record.exit_code)"
    }

    $savedWrapperEnv=@{}
    foreach($name in @('CODEX_HOME','DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_MODEL_ROUTER_CLAUDE_CREDENTIALS','DT_FAKE_REPORT_FILE','DT_BUILD_STATE_DIR')) {
        $savedWrapperEnv[$name]=[Environment]::GetEnvironmentVariable($name)
    }
    try {
    $repoRoot=(Resolve-Path (Join-Path $scriptDir '../../..')).Path
    $env:DT_BUILD_STATE_DIR=Join-Path $tempRoot 'build-state'
    $routerState = Join-Path $tempRoot 'router-state'
    Write-Utf8 -Path (Join-Path $routerState 'last-check.json') -Content (@{ checked_at = (Get-Date).ToString('o') } | ConvertTo-Json)
    $env:DT_MODEL_ROUTER_STATE = $routerState
    $fakeTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
    Write-Utf8 -Path $fakeTransport -Content @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
return [pscustomobject]@{ id = 'fake' }
'@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeTransport
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $tempRoot 'missing-claude-credentials.json'
    $codexHome = Join-Path $tempRoot 'codex-home'
    Write-Utf8 -Path (Join-Path $codexHome 'models_cache.json') -Content '{"fetched_at":"fixture","models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}]}'
    Write-Utf8 -Path (Join-Path $codexHome 'auth.json') -Content '{"auth_mode":"fixture"}'
    $env:CODEX_HOME = $codexHome
    $fakeCodex = Join-Path $tempRoot 'fake-codex.ps1'
    Write-Utf8 -Path $fakeCodex -Content @'
if ($args -contains '--version') { Write-Output 'codex-cli fixture'; exit 0 }
if ($args -contains 'debug') { Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_HOME 'models_cache.json'); exit 0 }
$outIndex = [Array]::IndexOf([object[]]$args, '--output-last-message')
$outPath = [string]$args[$outIndex + 1]
[void][Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText($outPath, [System.IO.File]::ReadAllText($env:DT_FAKE_REPORT_FILE))
'@
    $fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
    Write-Utf8 -Path $fakeClaude -Content @'
if ($args -contains '--version') { Write-Output 'claude-cli fixture'; exit 0 }
[void][Console]::In.ReadToEnd()
$usage = [ordered]@{}; $usage['claude-sonnet-5'] = @{ inputTokens = 10; outputTokens = 20; costUSD = 0.01 }
Write-Output (@{ type = 'result'; is_error = $false; result = [System.IO.File]::ReadAllText($env:DT_FAKE_REPORT_FILE); total_cost_usd = 0.01; modelUsage = $usage } | ConvertTo-Json -Depth 5 -Compress)
'@
    $project = Join-Path $tempRoot 'project'
    Write-Utf8 -Path (Join-Path $project 'README.md') -Content 'fixture'
    & git -C $project init -q
    $prompt = Join-Path $tempRoot 'prompt.md'
    Write-Utf8 -Path $prompt -Content "RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`nfixture"
    $reportFile = Join-Path $tempRoot 'fake-report.md'
    $env:DT_FAKE_REPORT_FILE = $reportFile

    $report=@('DT_BUILD_REPORT_VERSION: 3','RUN_ID: fixture-run','chunk_id: fixture-chunk','attempt: 1','VERDICT:','PASS','CHANGED_FILES:','NONE','COMMANDS_AND_RESULTS:','NONE','EVIDENCE_PATHS:','NONE','UNRESOLVED_BLOCKERS:','NONE','DISCOVERED_ENHANCEMENTS:','NONE','CONTINUATION_STATE:','NONE') -join "`n"
    foreach($lane in @('codex','claude')) {
        foreach($valid in @($true,$false)) {
            Write-Utf8 $reportFile $(if($valid){$report}else{'invalid fixture report'})
            foreach($generation in @('HEAD','current')) {
                $out=Join-Path $tempRoot "wrapper-$lane-$valid-$generation.md"
                $wrapper=Join-Path $scriptDir "invoke-$lane-chunk.ps1"
                $cli=if($lane -eq 'codex'){$fakeCodex}else{$fakeClaude}
                $model=if($lane -eq 'claude'){"-Model 'claude-sonnet-5'"}else{''}
                $command="& '$wrapper' -ProjectPath '$project' -PromptPath '$prompt' -OutputPath '$out' -$($lane.Substring(0,1).ToUpper()+$lane.Substring(1))CliPath '$cli' $model -Tier standard -Effort medium -SelectionReason 'runner differential fixture' -Attempt 1 -Json"
                $fn=if($generation -eq 'HEAD'){$fnHead}else{$fnCurrent}
                $generated=& { . ([scriptblock]::Create($fn)); Get-DtJobCommandScript $command }
                $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($generated))
                $wrapperLog=Join-Path $tempRoot "wrapper-$lane-$valid-$generation.log"
                & pwsh -NoProfile -NonInteractive -EncodedCommand $encoded *> $wrapperLog
                $code=$LASTEXITCODE
                $expected=if($valid){0}else{1}
                $prov=Get-Content -Raw "$out.provenance.json" | ConvertFrom-Json
                Assert-True ($code -eq $expected -and $prov.pass -eq $valid) "real wrapper job: $lane $generation valid=$valid exit=$code expected=$expected log=$(Get-Content $wrapperLog -Tail 3)"
                $measurements += "wrapper $lane valid=$valid $generation | exit=$code | expected=$expected"
            }
        }
    }
    } finally {
        foreach($name in $savedWrapperEnv.Keys){[Environment]::SetEnvironmentVariable($name,$savedWrapperEnv[$name])}
    }

    $measurements | Write-Output
    if($HeadMeasurementPath){Write-Utf8 $HeadMeasurementPath ($measurements -join "`n")}
}

$exitCode = 0
$junctionLink = $null
$pinEnvNames = @('DT_BUILD_STATE_DIR', 'DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID', 'DT_JOB_DIR', 'DT_BUILD_RUN_PIN_VENDOR', 'DT_BUILD_RUN_PIN_MODEL')
$pinSavedEnv = @{}
foreach ($name in $pinEnvNames) { $pinSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
$savedRouterState = $env:DT_MODEL_ROUTER_STATE
$savedAlertTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$savedDmLog = $env:DT_TEST_DM_LOG
try {
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID, Env:DT_JOB_DIR -ErrorAction SilentlyContinue
    # The generator's real-job smoke cases run before the main fixture setup too.
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'registry'
    $env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
    if ($Shard -ne 2) { Test-GeneratorDifferential }
    if($GeneratorDifferentialOnly){
        Write-Output "SUMMARY: $script:passed passed, $script:failed failed"
        if($script:failed){exit 1}; exit 0
    }
    # FS-115: every alert this suite raises goes to a fake transport, never Danny's real Discord.
    $env:DT_TEST_DM_LOG = Join-Path $tempRoot 'dms.jsonl'
    $fakeAlertTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
    Write-Utf8 $fakeAlertTransport @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
if ([string]$request['uri'] -like '*/messages') {
    $content = ([string]$request['body'] | ConvertFrom-Json).content
    [System.IO.File]::AppendAllText($env:DT_TEST_DM_LOG, (([ordered]@{ content = $content } | ConvertTo-Json -Compress) + "`n"))
}
return [pscustomobject]@{ id = 'fake' }
'@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeAlertTransport
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'registry'
    $suiteRegistry = $env:DT_BUILD_STATE_DIR
    $env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
    New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_STATE -Force | Out-Null
    Assert-True ([IO.Path]::GetFullPath($env:DT_MODEL_ROUTER_STATE).StartsWith([IO.Path]::GetFullPath($tempRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'router state stays under the suite temp directory'
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue
    if ($Shard -ne 2) {
    # FS-101: fixtures opt into temp storage explicitly; raw calls exercise the default guard.
    foreach ($verb in @('start', 'register-run', 'lease', 'note')) {
        $newTemp = Join-Path $tempRoot "refused-$verb"
        $raw = Invoke-TestPwsh -Script $dtJob $verb -RunFolder $newTemp -Command "'unused'" 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_TEMP_RUN_FOLDER' -and ($raw -join ' ') -match '\.dt-build/adhoc/') "$verb refuses a new temp run and names durable default"
        Assert-True (-not (Test-Path -LiteralPath $newTemp)) "$verb refusal creates no folder"
    }
    $guardProbe = @'
param($dtJob, $root)
. $dtJob
$env:TEMP = Join-Path $root 'alternate-temp'
$env:TMP = Join-Path $root 'alternate-tmp'
$results = foreach ($path in @((Join-Path $env:TEMP '../alternate-temp/new'), (Join-Path $env:TMP 'NEW').ToUpperInvariant())) {
    try { Assert-DtJobRunFolder $path; $false } catch { $_.Exception.Message -match 'DT_JOB_TEMP_RUN_FOLDER' }
}
try { Assert-DtJobRunFolder (Join-Path $root 'alternate-temp-sibling/new'); $results += $true } catch { $results += $false }
$results | ConvertTo-Json -Compress
'@
    $probePath = Join-Path $tempRoot 'guard-probe.ps1'
    Write-Utf8 $probePath $guardProbe
    $guardResults = ((& pwsh -NoProfile -File $probePath $dtJob $scriptDir) -join "`n") | ConvertFrom-Json
    Assert-True ($guardResults.Count -eq 3 -and @($guardResults | Where-Object { -not $_ }).Count -eq 0) 'TEMP TMP normalization case and path boundary guard'
    $tempRun = Join-Path $tempRoot 'explicit-temp'
    $tempJob = Invoke-DtJob @('start', '-RunFolder', $tempRun, '-Command', "'temp fixture'")
    Assert-True ((Wait-JobTerminal $tempRun $tempJob.job_id).status -eq 'succeeded') 'explicit temp opt-in creates and runs a job'
    $warningPath = Join-Path $tempRoot 'temp-warning.txt'
    $raw = & pwsh -NoProfile -File $dtJob start -RunFolder $tempRun -Command "'existing temp'" -Json 2>$warningPath
    $existingTempJob = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and @(Get-Content $warningPath).Count -eq 1 -and (Get-Content -Raw $warningPath) -match 'WARNING: DT_JOB_TEMP_RUN_FOLDER') 'existing temp run accepts start with exactly one stderr warning'
    $null = Wait-JobTerminal $tempRun $existingTempJob.job_id
    foreach ($verb in @('status', 'wait', 'reconcile', 'cancel')) {
        $raw = & pwsh -NoProfile -File $dtJob $verb -RunFolder $tempRun -JobId $tempJob.job_id -TimeoutSec 1 -Json 2>$warningPath
        Assert-True ($LASTEXITCODE -eq 0 -and -not (Get-Content -Raw $warningPath)) "$verb works on existing temp run without warning"
    }
    $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $tempRun -Evidence -Message 'Fixture evidence recorded.' -Json 2>$warningPath
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Get-Content -Raw $warningPath)) 'evidence notes work in existing temp run'
    $raw = Invoke-TestPwsh -Script $readEvidence -RunFolder $tempRun -JobId $tempJob.job_id -File spec -Lines 1-10
    Assert-True ($LASTEXITCODE -eq 0 -and ($raw -join ' ') -match 'temp fixture') 'evidence reads work in existing temp run'
    $copiedRun = Join-Path $tempRoot 'copied-run'
    Copy-Item -LiteralPath $tempRun -Destination $copiedRun -Recurse
    $sourceRoot = [IO.Path]::GetFullPath($tempRun)
    Assert-True ($sourceRoot.StartsWith([IO.Path]::GetFullPath($tempRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'migration source stays within isolated fixtures'
    Rename-Item -LiteralPath $sourceRoot -NewName 'old-temp-unavailable'
    foreach ($file in @('stdout', 'stderr', 'summary', 'spec')) {
        $raw = Invoke-TestPwsh -Script $readEvidence -RunFolder $copiedRun -JobId $tempJob.job_id -File $file -Lines 1-10 -Json
        $read = ($raw -join "`n") | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $read.path.StartsWith([IO.Path]::GetFullPath($copiedRun), [StringComparison]::OrdinalIgnoreCase)) "$file evidence follows a copied run when the original path is unavailable"
    }

    # FS-103: keep pages resident long enough for several tree samples, in a descendant.
    $memoryRun = New-RunFolder 'memory'
    $memoryScript = Join-Path $tempRoot 'allocate-memory.ps1'
    Write-Utf8 $memoryScript '$buffer = [byte[]]::new(200MB); for ($i = 0; $i -lt $buffer.Length; $i += 4096) { $buffer[$i] = 1 }; Start-Sleep -Seconds 8; [GC]::KeepAlive($buffer)'
    $memoryJob = Invoke-DtJob @('start', '-RunFolder', $memoryRun, '-Command', "& pwsh -NoProfile -File '$($memoryScript.Replace("'", "''"))'", '-Kind', 'test')
    $memoryRecord = Wait-JobTerminal $memoryRun $memoryJob.job_id
    Assert-True ($memoryRecord.status -eq 'succeeded' -and $memoryRecord.peak_memory_gb -gt 0.1) 'resident descendant memory records a measured peak over 0.1 GB'
    Assert-True ($memoryRecord.peak_memory_gb -eq [math]::Round($memoryRecord.peak_memory_gb, 2)) 'peak is rounded to 0.01 GB'
    $memoryStatus = Invoke-DtJob @('status', '-RunFolder', $memoryRun, '-JobId', $memoryJob.job_id)
    Assert-True ($memoryStatus.peak_memory_gb -eq $memoryRecord.peak_memory_gb) 'single job JSON exposes peak'
    $memoryStatus = Invoke-DtJob @('status', '-RunFolder', $memoryRun)
    Assert-True ($memoryStatus.jobs[0].peak_memory_gb -eq $memoryRecord.peak_memory_gb) 'run JSON exposes peak per job'

    # Exercise the real wait loop with an unavailable sampler and a completed fake process.
    & {
        $runnerPath = Join-Path $scriptDir 'dt-job-runner.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $waitFunction = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-DtJobProcess' }, $true)
        . ([scriptblock]::Create($waitFunction.Extent.Text))
        function Get-DtJobSettingSec { param($Name, $Default) return $Default }
        function Get-DtJobTreeMemoryGB { param($RootPid) throw 'fixture sampler unavailable' }
        $script:DtJobHeartbeatSec = 30
        $script:peakMemoryGB = $null; $script:memorySamplingFailed = $false
        $jobDir = $memoryRun; $paths = [pscustomobject]@{ Root = $memoryRun }; $JobId = 'sample-failure'
        $fake = [pscustomobject]@{ HasExited = $false; Id = $PID }
        $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
        $output = [IO.MemoryStream]::new()
        try {
            $finished = Wait-DtJobProcess -Process $fake -WorkDir $memoryRun -Outputs @($output)
            Assert-True $finished 'sampler failure never fails or interrupts the job wait'
            Assert-True ($script:memorySamplingFailed -and $null -eq $script:peakMemoryGB) 'unavailable sampler retains a null peak'
        } finally { $output.Dispose() }
    }

    # FS-102: actual script arguments exercise quoted and bare command replacements.
    $relaunchRun = New-RunFolder 'relaunch'
    $argScript = Join-Path $tempRoot 'echo-args.ps1'
    Write-Utf8 $argScript 'param($PromptPath, $OutputPath); Write-Output "$PromptPath|$OutputPath"'
    $originalCommand = "& '$argScript' -PromptPath 'old prompt.txt' -OutputPath old-output.txt"
    $originalJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', $originalCommand, '-Category', 'fixture', '-Model', 'fixture-model', '-Mutates', 'fixture-key', '-TimeoutSec', '40')
    $null = Wait-JobTerminal $relaunchRun $originalJob.job_id
    $originalSpecPath = Join-Path $relaunchRun "jobs/$($originalJob.job_id)/spec.json"
    $originalSpecText = Get-Content -Raw $originalSpecPath
    Push-Location $tempRoot
    try { $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id) }
    finally { Pop-Location }
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    $retrySpec = Get-Content -Raw (Join-Path $relaunchRun "jobs/$($retry.job_id)/spec.json") | ConvertFrom-Json
    Assert-True ($retry.job_id -ne $originalJob.job_id -and $retrySpec.command -ceq $originalCommand -and $retrySpec.relaunched_from -eq $originalJob.job_id) 'FromJob creates a new id with copied command and spec ancestry'
    Assert-True ($retryRecord.category -eq 'fixture' -and $retryRecord.model -eq 'fixture-model' -and $retryRecord.mutates[0] -eq 'fixture-key' -and $retryRecord.expected_sec -eq 40) 'FromJob copies metadata and expected duration'
    Assert-True ($retrySpec.environment.DT_MODEL_ROUTER_STATE -eq $env:DT_MODEL_ROUTER_STATE -and $retryRecord.working_directory -eq (Get-JobRecord $relaunchRun $originalJob.job_id).working_directory) 'FromJob preserves environment and working directory'
    $events = @(Get-Content (Join-Path $relaunchRun 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.job_id -eq $retry.job_id -and $_.type -eq 'recorded' })[0].relaunched_from -eq $originalJob.job_id) 'start event records ancestry'
    foreach ($type in @('launched', 'process_started')) {
        Assert-True (@($events | Where-Object { $_.job_id -eq $retry.job_id -and $_.type -eq $type })[0].relaunched_from -eq $originalJob.job_id) "$type event records ancestry"
    }
    $status = Invoke-DtJob @('status', '-RunFolder', $relaunchRun, '-JobId', $retry.job_id)
    Assert-True ($status.relaunched_from -eq $originalJob.job_id) 'single job status exposes ancestry'
    $status = Invoke-DtJob @('status', '-RunFolder', $relaunchRun)
    Assert-True (@($status.jobs | Where-Object { $_.job_id -eq $retry.job_id })[0].relaunched_from -eq $originalJob.job_id) 'run status exposes ancestry'
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id, '-PromptPath', "new prompt's.txt", '-OutputPath', 'new output.txt', '-Category', 'replacement', '-TimeoutSec', '9', '-Mutates', '')
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and (Get-Content -Raw $retryRecord.output_path).Trim() -ceq "new prompt's.txt|new output.txt") 'quoted and bare arguments replaced exactly and execute with literal values'
    Assert-True ($retryRecord.category -eq 'replacement' -and $retryRecord.expected_sec -eq 9 -and $retryRecord.mutates.Count -eq 0) 'explicit start parameters override copied values including empty lists'
    Assert-True ((Get-Content -Raw $originalSpecPath) -ceq $originalSpecText) 'relaunch leaves original spec unchanged'
    $missingJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', "Write-Output '-PromptPath fake -OutputPath fake'; Write-Output done -OutputPathSuffix untouched")
    $null = Wait-JobTerminal $relaunchRun $missingJob.job_id
    foreach ($name in @('PromptPath', 'OutputPath')) {
        $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $relaunchRun -FromJob $missingJob.job_id "-$name" replacement -AllowTempRunFolder 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_FROMJOB_NO_ARG') "$name override refuses absent exact argument including quoted decoys"
    }
    $releaseRetry = Join-Path $tempRoot 'release-retry'
    $heldRetry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', (New-HeldJobCommand $releaseRetry))
    $null = Wait-JobState $relaunchRun $heldRetry.job_id -Until { param($r) $r.status -eq 'running' -and $r.pid }
    $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $relaunchRun -FromJob $heldRetry.job_id -AllowTempRunFolder 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_FROMJOB_RUNNING') 'FromJob refuses a live running job'
    $null = Invoke-DtJob @('cancel', '-RunFolder', $relaunchRun, '-JobId', $heldRetry.job_id)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $heldRetry.job_id, '-Command', "'override command'")
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'cancelled job relaunch accepts explicit command override'
    $scriptJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-ScriptPath', $argScript, '-ArgumentList', 'one,two')
    $null = Wait-JobTerminal $relaunchRun $scriptJob.job_id
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $scriptJob.job_id)
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and (Get-Content -Raw $retryRecord.output_path).Trim() -eq 'one,two|') 'script path and argument list survive relaunch'
    $failedJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', 'exit 7', '-Kind', 'test', '-Vendor', 'fixture', '-DependsOn', $scriptJob.job_id)
    $null = Wait-JobTerminal $relaunchRun $failedJob.job_id
    $failedLog = Get-Content -Raw (Join-Path $relaunchRun "jobs/$($failedJob.job_id)/stderr.log")
    Assert-True ($failedLog -match 'FAILED COMMAND \(exit=7\): exit 7') 'failed job retains its invocation even when child emits no output'
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $failedJob.job_id)
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'failed' -and $retryRecord.exit_code -eq 7 -and $retryRecord.depends_on[0] -eq $scriptJob.job_id) 'failed job relaunch preserves command and dependencies'
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $failedJob.job_id, '-ScriptPath', $argScript, '-ArgumentList', 'replacement', '-Kind', 'command', '-Vendor', 'replacement', '-Model', 'new-model', '-DependsOn', '', '-ExclusiveReason', '', '-RunId', 'new-run')
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and $retryRecord.kind -eq 'command' -and $retryRecord.vendor -eq 'replacement' -and $retryRecord.model -eq 'new-model' -and $retryRecord.run_id -eq 'new-run' -and $retryRecord.depends_on.Count -eq 0 -and -not $retryRecord.exclusive_reason -and (Get-Content -Raw $retryRecord.output_path).Trim() -eq 'replacement|') 'explicit script arguments kind vendor model run dependencies and exclusivity override copied values'
    $argumentProbe = @'
param($dtJob)
. $dtJob
$command = 'worker -PromptPath "old prompt.txt" -OutputPath:old.txt -OutputPathSuffix keep; Write-Output ''-PromptPath decoy'''
$command = Set-DtJobCommandArgument $command PromptPath 'new prompt.txt'
Set-DtJobCommandArgument $command OutputPath 'new output.txt'
'@
    Write-Utf8 $probePath $argumentProbe
    $replaced = ((& pwsh -NoProfile -File $probePath $dtJob) -join "`n")
    Assert-True ($LASTEXITCODE -eq 0 -and $replaced -ceq "worker -PromptPath 'new prompt.txt' -OutputPath:'new output.txt' -OutputPathSuffix keep; Write-Output '-PromptPath decoy'") 'double quotes and colon values replace exactly while unrelated arguments and strings stay unchanged'
    # A reboot leaves a running record with dead process identities until reconcile.
    $deadRecord = Get-JobRecord $relaunchRun $originalJob.job_id
    $deadRecord.status = 'running'; $deadRecord.pid = 2147483646; $deadRecord.runner_pid = 2147483646
    Write-Utf8 (Join-Path $relaunchRun "jobs/$($originalJob.job_id).json") ($deadRecord | ConvertTo-Json -Depth 8)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id)
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'FromJob accepts a dead running record after reboot'
    $null = Invoke-DtJob @('reconcile', '-RunFolder', $relaunchRun)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id)
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'FromJob accepts reconciled orphaned jobs'

    $pinRun = New-RunFolder 'pin-run'
    $pinState = Join-Path $pinRun '_build-state.md'
    Write-Utf8 $pinState "updated_utc: fixture`nrun_status: runnable`nlast_consumed_event_seq: 0`n"
    $registrationArgs = @('register-run', '-RunFolder', $pinRun, '-RunId', 'pin-run', '-BuildStatePath', $pinState, '-PinnedHost', 'codex', '-Managed')
    $raw = Invoke-TestPwsh -Script $dtJob pin -RunFolder $pinRun -Vendor codex -Model fixture *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'pin refuses an unregistered run'
    $null = Invoke-DtJob $registrationArgs
    foreach ($missing in @(@('-Vendor', 'codex'), @('-Model', 'fixture'))) {
        $raw = Invoke-TestPwsh -Script $dtJob pin -RunFolder $pinRun @missing 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_USAGE') 'pin requires both vendor and model'
    }
    $pinned = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Vendor', 'codex', '-Model', 'gpt-fixture')
    Assert-True ($pinned.pin.vendor -eq 'codex' -and $pinned.pin.model -eq 'gpt-fixture' -and [bool]$pinned.pin.set_utc) 'pin saves vendor model and timestamp'
    $pinStatus = Invoke-DtJob @('status', '-RunFolder', $pinRun)
    Assert-True ($pinStatus.pin -eq 'codex gpt-fixture') 'run status carries pin label'
    foreach ($identity in @('DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID')) {
        try {
            [Environment]::SetEnvironmentVariable($identity, 'fixture')
            $raw = Invoke-TestPwsh -Script $dtJob pin -RunFolder $pinRun -Clear 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_OPERATOR_ONLY') "$identity cannot clear a pin"
        } finally { [Environment]::SetEnvironmentVariable($identity, $null) }
    }
    $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $pinRun -Kind worker -Vendor claude -Command "'refused'" 2>&1
    # PowerShell's error view colors and wraps the message to the console width; match the plain text.
    $plain = (($raw -join ' ') -replace '\x1b\[[0-9;]*m', '' -replace '\s+\|\s+', ' ' -replace '\s+', ' ')
    Assert-True ($LASTEXITCODE -ne 0 -and $plain -match 'DT_JOB_PIN_VENDOR: run is pinned to codex \(gpt-fixture\); worker vendor claude refused') 'worker vendor mismatch refused before job creation'
    $env:DT_BUILD_RUN_PIN_VENDOR = 'claude'; $env:DT_BUILD_RUN_PIN_MODEL = 'stale'
    foreach ($kind in @('worker', 'command')) {
        $pinJob = Invoke-DtJob @('start', '-RunFolder', $pinRun, '-Kind', $kind, '-Vendor', 'codex', '-Command', "'pinned'")
        $spec = Get-Content -Raw (Join-Path $pinRun "jobs/$($pinJob.job_id)/spec.json") | ConvertFrom-Json
        Assert-True ($spec.environment.DT_BUILD_RUN_PIN_VENDOR -eq 'codex' -and $spec.environment.DT_BUILD_RUN_PIN_MODEL -eq 'gpt-fixture') "$kind spec carries authoritative registry pin"
        $null = Wait-JobTerminal $pinRun $pinJob.job_id
        $pinWait = Invoke-DtJob @('wait', '-RunFolder', $pinRun, '-JobId', $pinJob.job_id, '-All', '-TimeoutSec', '1')
        Assert-True ($pinWait.pin -eq 'codex gpt-fixture') "$kind wait carries pin label"
        $singleWait = Invoke-DtJob @('wait', '-RunFolder', $pinRun, '-JobId', $pinJob.job_id, '-TimeoutSec', '1')
        Assert-True ($singleWait.result -eq 'finished' -and $singleWait.pin -eq 'codex gpt-fixture') "$kind single-job wait needs neither -Any nor -All"
    }
    $null = Invoke-DtJob @('lease', '-RunFolder', $pinRun, '-Action', 'acquire', '-CoordinatorId', 'pin-reader', '-Host', 'codex', '-LaunchedBy', 'watcher')
    $resumeArgs = @('-RunFolder', $pinRun, '-RunId', 'pin-run', '-BuildStatePath', $pinState, '-CoordinatorId', 'pin-reader')
    $resumeRaw = & pwsh -NoProfile -File (Join-Path $scriptDir 'read-resume-record.ps1') @resumeArgs
    $resume = ($resumeRaw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $resume.pin.model -eq 'gpt-fixture') 'resume record carries top-level pin object'
    $null = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Clear')
    $pinStatus = Invoke-DtJob @('status', '-RunFolder', $pinRun)
    Assert-True ($null -eq $pinStatus.pin) 'clear removes registry pin and status is null'
    $resumeRaw = & pwsh -NoProfile -File (Join-Path $scriptDir 'read-resume-record.ps1') @resumeArgs
    $resume = ($resumeRaw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $null -eq $resume.pin) 'resume record pin is null after clear'
    $registered = Invoke-DtJob ($registrationArgs + @('-PinVendor', 'claude', '-PinModel', 'claude-fixture'))
    Assert-True ($registered.pin.vendor -eq 'claude' -and $registered.pin.model -eq 'claude-fixture') 'register-run stores a pin'
    $registered = Invoke-DtJob $registrationArgs
    Assert-True ($registered.pin.model -eq 'claude-fixture') 're-registration preserves operator pin'
    $null = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Clear')
    $pinJob = Invoke-DtJob @('start', '-RunFolder', $pinRun, '-Command', "'unpinned'")
    $spec = Get-Content -Raw (Join-Path $pinRun "jobs/$($pinJob.job_id)/spec.json") | ConvertFrom-Json
    Assert-True (-not $spec.environment.PSObject.Properties['DT_BUILD_RUN_PIN_VENDOR'] -and -not $spec.environment.PSObject.Properties['DT_BUILD_RUN_PIN_MODEL']) 'unpinned registry removes inherited pin hints'
    $null = Wait-JobTerminal $pinRun $pinJob.job_id
    foreach ($name in $pinEnvNames) { [Environment]::SetEnvironmentVariable($name, $pinSavedEnv[$name]) }
    # Keep the suite's temp registry: restoring the outer value here sent later fixtures (launch-delegate,
    # approval-queue) into Danny's real run registry, where they raised a real irreversible-fixture alert.
    $env:DT_BUILD_STATE_DIR = $suiteRegistry
    # Tests that exercise operator verbs must not inherit the outer worker identity.
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue

    # Live discovery uses the actual Git admin directory, not the ledger or tree file timestamps.
    $treeRepo = New-RunFolder 'tree-repo'
    $treeRun = Join-Path $treeRepo '.dt-build/run'
    New-Item -ItemType Directory -Path $treeRun -Force | Out-Null
    $addedTree = Join-Path $tempRoot 'added tree'
    & git -C $treeRepo init -q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture init failed' }
    & git -C $treeRepo -c user.name=Fixture -c user.email=fixture@example.test commit -q --allow-empty -m fixture | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture commit failed' }
    & git -C $treeRepo worktree add -q -b feat/live $addedTree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture add failed' }
    $treeProbe = ". '$dtJob'; [ordered]@{ live = @(Get-DtJobLiveWorktrees -RunFolder '$treeRun'); future = @(Get-DtJobLiveWorktrees -RunFolder '$treeRun' -SinceUtc ([DateTime]::UtcNow.AddDays(1))); missing = @(Get-DtJobWorktrees -RunFolder '$treeRun') } | ConvertTo-Json -Depth 5"
    $treeResult = ((& pwsh -NoProfile -Command $treeProbe) -join "`n") | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'worktree discovery probe failed' }
    Assert-True ($treeResult.live.Count -eq 1 -and $treeResult.live[0].path -eq [IO.Path]::GetFullPath($addedTree) -and $treeResult.live[0].branch -eq 'feat/live' -and $treeResult.live[0].head -match '^[0-9a-f]{40}$' -and $null -ne $treeResult.live[0].created_utc) 'live worktree discovery returns the added tree, branch, HEAD and admin creation time, excluding main'
    Assert-True ($treeResult.future.Count -eq 0) 'live discovery excludes trees before a future SinceUtc'
    Assert-True ($treeResult.missing.Count -eq 0) 'a missing worktree ledger returns no rows'
    Write-Utf8 -Path (Join-Path $treeRun 'worktrees.jsonl') -Content "{broken`n{}`n"
    $treeResult = ((& pwsh -NoProfile -Command $treeProbe) -join "`n") | ConvertFrom-Json
    Assert-True ($treeResult.missing.Count -eq 0) 'malformed worktree ledger lines are ignored'

    # FS-20: dt-job dot-sourced through a skill junction must resolve its alert script in the real repo.
    $realSkillRoot = Split-Path -Parent $scriptDir
    $realRepoRoot = Split-Path -Parent (Split-Path -Parent $realSkillRoot)
    $junctionLink = Join-Path $tempRoot 'dt-build'
    # A junction on Windows; Linux and the Mac link skills with symlinks.
    New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $junctionLink -Target $realSkillRoot | Out-Null
    $junctionJob = Join-Path $junctionLink 'scripts/dt-job.ps1'
    $alertPath = (& pwsh -NoProfile -Command ". '$($junctionJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript" | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $alertPath -PathType Leaf)) "junction dt-job load resolves an existing alert script ($alertPath)"
    Assert-True ($alertPath.StartsWith($realRepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and -not $alertPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'junction alert path belongs to the real repo, not the junction parent'
    $directPath = (& pwsh -NoProfile -Command ". '$($dtJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript" | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and $directPath -eq $alertPath) 'direct and junction loads resolve the same alert path'
    $fallbackProbe = "function Get-Item { param([string]`$LiteralPath) [pscustomobject]@{} }; . '$($dtJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript"
    $fallbackPath = (& pwsh -NoProfile -Command $fallbackProbe | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and $fallbackPath -eq $directPath) 'a missing ResolveLinkTarget falls back to the unresolved path without throwing'
    [IO.Directory]::Delete($junctionLink); $junctionLink = $null

    # Start and succeed with the command evaluated directly by the runner.
    $rf = New-RunFolder 'succeed'
    $release = Join-Path $rf "release's.txt"
    $heldCommand = New-HeldJobCommand $release
    $start = Invoke-DtJob @('start', '-RunFolder', $rf, '-Kind', 'test', '-Category', 'fixture', '-Command', "'ok'; $heldCommand")
    Assert-True ($start.job_id -eq 'j-0001') 'first job id is j-0001'
    Assert-True ($start.status -in @('running', 'queued')) 'start returns at once with a live status'
    Write-Utf8 $release 'release'
    $record = Wait-JobTerminal -RunFolder $rf -JobId $start.job_id
    Assert-True ($record.status -eq 'succeeded') "succeeded job status was $($record.status)"
    Assert-True ($record.exit_code -eq 0) 'succeeded job exit code 0'
    Assert-True ([bool]$record.pid -and [bool]$record.process_start_utc) 'pid and process_start_utc recorded'
    Assert-True ([bool]$record.ended -and [bool]$record.command_sha256 -and $record.kind -eq 'test' -and $record.category -eq 'fixture') 'ledger fields recorded'
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $start.job_id)
    Assert-True ($envelope.verdict -eq 'pass' -and $envelope.exit_code -eq 0) 'envelope verdict pass'
    Assert-True (@($envelope.excerpt) -contains 'ok') 'envelope excerpt holds stdout tail'
    Assert-True ((Test-Path -LiteralPath $envelope.evidence.stdout) -and -not $envelope.truncated) 'envelope names stdout evidence and is not truncated'

    # Job evidence uses the record's paths, with the same selectors and ledger as -Path.
    $evidenceRecord = Get-JobRecord -RunFolder $rf -JobId $start.job_id
    $jobDir = Join-Path $rf "jobs/$($start.job_id)"
    $expectedPaths = [ordered]@{ summary = $evidenceRecord.summary_path; stdout = $evidenceRecord.output_path; stderr = $evidenceRecord.stderr_path; spec = (Join-Path $jobDir 'spec.json') }
    foreach ($name in $expectedPaths.Keys) {
        $actual = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -JobId $start.job_id -File $name -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
        $expectedLines = @(Get-Content -LiteralPath $expectedPaths[$name] -TotalCount 3)
        Assert-True ($actual.path -eq $expectedPaths[$name] -and @($actual.lines).Count -eq $expectedLines.Count) "$name resolves the recorded job evidence path"
        for ($i = 0; $i -lt $expectedLines.Count; $i++) {
            Assert-True ($actual.lines[$i] -eq "$($i + 1): $($expectedLines[$i])") "$name reads the expected evidence line"
        }
    }
    $defaultRead = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -JobId $start.job_id -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
    Assert-True ($defaultRead.path -eq $evidenceRecord.summary_path -and (@($defaultRead.warnings) -join ' ') -match 'repeat_read') 'JobId defaults to summary and shares repeat-read tracking'
    $jobGrep = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -JobId $start.job_id -File stdout -Grep '^ok$' -Context 1 -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($jobGrep.lines) -contains '1: ok') 'JobId supports grep and context'
    foreach ($missingPath in @((Join-Path $jobDir 'result.json'), (Join-Path $rf "jobs/$($start.job_id).xml"))) {
        $miss = Get-EvidenceError @{ RunFolder = $rf; Path = $missingPath; Lines = '1-3' }
        Assert-True ($miss.Contains('READ_EVIDENCE_MISSING:') -and $miss.Contains("job $($start.job_id) has: summary.json, stdout.log, stderr.log, spec.json (use -JobId $($start.job_id) -File <name>)")) "job path miss lists existing evidence and the JobId form ($miss)"
    }
    Push-Location $rf
    try {
        $miss = Get-EvidenceError @{ RunFolder = $rf; Path = 'approvals.json'; Lines = '1-3' }
        Assert-True (-not $miss.Contains('did you mean')) 'run-root miss does not suggest the same path'
        Push-Location $jobDir
        try {
            $miss = Get-EvidenceError @{ RunFolder = $rf; Path = 'approvals.json'; Lines = '1-3' }
            Assert-True ($miss.Contains("did you mean $(Join-Path $rf 'approvals.json')")) 'bare approvals miss suggests the run folder'
        } finally { Pop-Location }
    } finally { Pop-Location }
    $badArgs = Get-EvidenceError @{ RunFolder = $rf; Path = $evidenceRecord.output_path; JobId = $start.job_id; Lines = '1-3' }
    Assert-True ($badArgs.Contains('READ_EVIDENCE_ARGS')) 'Path plus JobId fails with the argument error'
    $unknown = Get-EvidenceError @{ RunFolder = $rf; JobId = 'j-9999'; Lines = '1-3' }
    Assert-True ($unknown.Contains('READ_EVIDENCE_NO_JOB: j-9999')) 'unknown JobId has the specific missing-record error'
    $sparseRun = New-RunFolder 'evidence-sparse'
    $sparseDir = Join-Path $sparseRun 'jobs/j-0001'
    Write-Utf8 (Join-Path $sparseDir 'stdout.log') 'only stdout exists'
    $miss = Get-EvidenceError @{ RunFolder = $sparseRun; Path = (Join-Path $sparseDir 'output.log'); Lines = '1-3' }
    Assert-True ($miss.Contains('has: stdout.log (use -JobId j-0001 -File <name>)')) 'job miss lists only files that exist'
    Write-Utf8 (Join-Path $sparseRun 'jobs/j-0001.json') (@{ job_id = 'j-0001'; summary_path = (Join-Path $sparseDir 'summary.json') } | ConvertTo-Json)
    $miss = Get-EvidenceError @{ RunFolder = $sparseRun; JobId = 'j-0001'; Lines = '1-3' }
    Assert-True ($miss.StartsWith("READ_EVIDENCE_MISSING: $(Join-Path $sparseDir 'summary.json')")) 'resolved missing job file retains the missing-path error'

    # Hundreds of finished records force trimming after accounting for the hint.
    $manyRun = New-RunFolder 'evidence-many'
    $manyIds = @(1..300 | ForEach-Object { 'j-{0:D4}' -f $_ })
    foreach ($id in $manyIds) {
        $copy = $evidenceRecord | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $copy.job_id = $id
        Write-Utf8 (Join-Path $manyRun "jobs/$id.json") ($copy | ConvertTo-Json -Depth 8)
    }
    foreach ($arguments in @(@('status', '-RunFolder', $manyRun), @('wait', '-RunFolder', $manyRun, '-JobId', ($manyIds -join ','), '-All', '-TimeoutSec', '1'))) {
        $reply = Invoke-DtJob $arguments
        Assert-True ($reply.evidence_hint -is [string] -and $reply.evidence_hint.Length -lt 400 -and $reply.evidence_hint.Contains('-JobId <job>')) 'large envelope retains its bounded evidence hint'
        Assert-True ($reply.truncated -and @($reply.jobs).Count -lt 300 -and [Text.Encoding]::UTF8.GetByteCount(($reply | ConvertTo-Json -Depth 8 -Compress)) -le 8192) '300-job envelope including hint is trimmed within 8 KB'
    }
    $events = @(Get-Content -LiteralPath (Join-Path $rf 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $seqs = @($events | ForEach-Object { [int]$_.seq })
    Assert-True (($seqs -join ',') -eq ((1..$seqs.Count) -join ',')) 'event seq is monotonic from 1'
    Assert-True ((@($events | Where-Object { -not ($_.job_id -and $_.ts_utc -and $_.type -and $_.status) })).Count -eq 0) 'every event carries job_id, ts_utc, type, status'
    $all = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($all.job_count -eq 1 -and $all.jobs[0].status -eq 'succeeded') 'run status lists jobs'

    # A wrapper can exit successfully while its report records unfinished/failed work.
    $workerRun = New-RunFolder 'worker-outcomes'
    $fakeWrapper = Join-Path $workerRun 'fake-wrapper.ps1'
    Write-Utf8 $fakeWrapper @'
param([string]$OutputPath, [string]$ReportVerdict, [switch]$OmitReport, [switch]$WrapperFailure)
if ($OmitReport) { exit 0 }
[IO.File]::WriteAllText($OutputPath, "DT_BUILD_REPORT_VERSION: 3`nVERDICT: $ReportVerdict`nCHANGED_FILES:`nNONE`n")
@{ pass = (-not $WrapperFailure); failure_category = $(if ($WrapperFailure) { 'environment' } else { $null }); termination_reason = $(if ($WrapperFailure) { 'fixture wrapper failure' } else { $null }) } | ConvertTo-Json | Set-Content -LiteralPath "$OutputPath.provenance.json"
exit 0
'@
    foreach ($case in @('BLOCKED', 'PASS', 'FAIL', 'PARTIAL', 'missing', 'wrapper-failure')) {
        $report = Join-Path $workerRun "report $case.md"
        $reportVerdict = if ($case -eq 'wrapper-failure') { 'PASS' } else { $case }
        $extra = if ($case -eq 'missing') { ' -OmitReport' } elseif ($case -eq 'wrapper-failure') { ' -WrapperFailure' } else { '' }
        $worker = Invoke-DtJob @('start', '-RunFolder', $workerRun, '-Kind', 'worker', '-Command', "& '$fakeWrapper' -OutputPath '$report' -ReportVerdict '$reportVerdict'$extra")
        $workerRecord = Wait-JobTerminal -RunFolder $workerRun -JobId $worker.job_id
        $summary = Invoke-DtJob @('status', '-RunFolder', $workerRun, '-JobId', $worker.job_id)
        $expectedVerdict = if ($case -in @('BLOCKED', 'FAIL', 'wrapper-failure')) { 'fail' } else { 'pass' }
        Assert-True ($workerRecord.status -eq 'succeeded' -and $workerRecord.exit_code -eq 0 -and $summary.verdict -eq $expectedVerdict) "$case keeps successful ledger state and summarizes worker outcome"
        Assert-True ($summary.report_verdict -eq $(if ($case -eq 'missing') { $null } else { $reportVerdict })) "$case extracts report verdict through a path containing spaces"
        if ($case -in @('BLOCKED', 'FAIL', 'PARTIAL')) { Assert-True (@($summary.blockers) -contains "report verdict $case; see $report") "$case summary points to report evidence" }
        if ($case -in @('BLOCKED', 'PASS')) {
            $persisted = Get-Content -Raw -LiteralPath $workerRecord.summary_path | ConvertFrom-Json
            Assert-True ($persisted.report_verdict -eq $reportVerdict -and $persisted.verdict -eq $expectedVerdict -and $persisted.wrapper_pass -eq $true -and $null -eq $persisted.failure_category) "$case persists worker outcome in summary.json"
        }
        if ($case -eq 'PASS') {
            Assert-True (@($summary.blockers).Count -eq 0) 'PASS report has no invented blocker'
            foreach ($name in @('report', 'provenance')) {
                $expectedPath = if ($name -eq 'report') { $report } else { "$report.provenance.json" }
                $actual = (Invoke-TestPwsh -Script $readEvidence -RunFolder $workerRun -JobId $worker.job_id -File $name -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
                $expectedLines = @(Get-Content -LiteralPath $expectedPath -TotalCount 3)
                Assert-True ($actual.path -eq $expectedPath -and @($actual.lines).Count -eq $expectedLines.Count) "$name resolves the worker wrapper artifact"
                for ($i = 0; $i -lt $expectedLines.Count; $i++) {
                    Assert-True ($actual.lines[$i] -eq "$($i + 1): $($expectedLines[$i])") "$name reads the expected worker artifact line"
                }
            }
        }
        if ($case -eq 'wrapper-failure') {
            Assert-True ($summary.wrapper_pass -eq $false -and $summary.failure_category -eq 'environment' -and @($summary.blockers) -contains 'wrapper reported failure (environment)') 'wrapper provenance failure overrides a PASS report'
        } elseif ($case -eq 'missing') {
            Assert-True ($null -eq $summary.wrapper_pass -and $null -eq $summary.failure_category -and $null -eq $summary.report_verdict -and @($summary.blockers).Count -eq 0) 'absent report and provenance preserve legacy pass with null outcomes'
        } else { Assert-True ($summary.wrapper_pass -eq $true -and $null -eq $summary.failure_category) "$case reads boolean provenance pass" }
        $wait = Invoke-DtJob @('wait', '-RunFolder', $workerRun, '-JobId', $worker.job_id, '-All', '-TimeoutSec', '1')
        Assert-True ($wait.jobs[0].report_verdict -eq $summary.report_verdict -and $wait.jobs[0].failure_category -eq $summary.failure_category) "$case wait JSON carries report outcome"
        $runSummary = Invoke-DtJob @('status', '-RunFolder', $workerRun)
        foreach ($reply in @($wait, $runSummary)) {
            Assert-True ($reply.evidence_hint.Contains('-JobId <job> -File summary|stdout|stderr|spec|report|provenance') -and $reply.evidence_hint.Contains('jobs/events.jsonl') -and $reply.evidence_hint.Length -lt 400 -and $reply.evidence_hint -notmatch '[\r\n]') "$case envelope has the one-line evidence hint"
            Assert-True ([Text.Encoding]::UTF8.GetByteCount(($reply | ConvertTo-Json -Depth 8 -Compress)) -le 8192) "$case envelope with evidence hint stays within 8 KB"
        }
        $row = @($runSummary.jobs | Where-Object job_id -eq $worker.job_id)[0]
        Assert-True ($row.report_verdict -eq $summary.report_verdict -and $row.failure_category -eq $summary.failure_category) "$case run status carries report outcome"
        $waitText = Invoke-TestPwsh -Script $dtJob wait -RunFolder $workerRun -JobId $worker.job_id -All -TimeoutSec 1
        Assert-True (($waitText -join "`n") -match $(if ($case -eq 'missing') { 'evidence=' } else { "verdict=$reportVerdict" })) "$case terminal check-in text carries available verdict"
    }
    # Probe parser and corrupt-artifact cases without spawning another process for each.
    & {
        . $dtJob
        $fixtureRecord = $workerRecord
        $specPath = Join-Path $workerRun "jobs/$($fixtureRecord.job_id)/spec.json"
        $quotedReport = Join-Path $workerRun "Danny's report.md"
        Write-Utf8 $quotedReport "VERDICT:`nBLOCKED`nPASS`nCHANGED_FILES:`nNONE"
        $simpleReport = Join-Path $workerRun 'simple.md'
        Write-Utf8 $simpleReport 'VERDICT: PARTIAL'
        $fixtureRecord.working_directory = $workerRun
        foreach ($command in @("wrapper -OutputPath '$($quotedReport.Replace("'", "''"))'", "wrapper -OutputPath `"$quotedReport`"", 'wrapper -OutputPath simple.md')) {
            Write-Utf8 $specPath (@{ command = $command } | ConvertTo-Json)
            $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
            Assert-True ($outcome.report_path -eq $(if ($command.EndsWith('simple.md')) { $simpleReport } else { $quotedReport }) -and $outcome.report_verdict -eq $(if ($command.EndsWith('simple.md')) { 'PARTIAL' } else { 'BLOCKED' })) 'single/double/bare OutputPath parser reads first VERDICT entry'
        }
        Write-Utf8 $specPath (@{ command = "wrapper -OutputPath '$quotedReport" } | ConvertTo-Json)
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.report_path -and $null -eq $outcome.report_verdict) 'unclosed quote returns null outcome'
        Write-Utf8 $specPath '{malformed'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'malformed spec never throws'
        Write-Utf8 $specPath (@{ command = $null; script_path = $fakeWrapper } | ConvertTo-Json)
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'script specs have no command outcome'
        Write-Utf8 $specPath (@{ command = "wrapper -OutputPath '$simpleReport'" } | ConvertTo-Json)
        Write-Utf8 $simpleReport 'VERDICT: unknown'
        Write-Utf8 "$simpleReport.provenance.json" '{malformed'
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.report_verdict -and $null -eq $outcome.wrapper_pass -and $null -eq $outcome.failure_category) 'unknown verdict and malformed provenance remain nullable'
        Write-Utf8 "$simpleReport.provenance.json" (@{ pass = 'false'; failure_category = @('bad'); termination_reason = 3 } | ConvertTo-Json)
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.wrapper_pass -and $null -eq $outcome.failure_category -and $null -eq $outcome.termination_reason) 'malformed provenance field types are not coerced'
        Write-Utf8 $simpleReport 'VERDICT: PASS'
        Write-Utf8 "$simpleReport.provenance.json" (@{ pass = $false; failure_category = ('x' * 1200); termination_reason = 'worker stopped' } | ConvertTo-Json)
        $summary = New-DtJobEnvelope -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($summary.verdict -eq 'fail' -and $summary.failure_category.Length -le 400 -and $summary.truncated -and @($summary.truncated_evidence) -contains "$simpleReport.provenance.json" -and (Get-DtJobEnvelopeBytes $summary) -le 8192) 'long provenance failure stays bounded and retains truncation evidence'
        Assert-True ((Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).termination_reason -eq 'worker stopped') 'helper returns provenance termination reason'
        $fixtureRecord.status = 'running'; $fixtureRecord.started = [DateTime]::UtcNow.AddHours(-1).ToString('o')
        $activity = Get-DtJobActivity -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($activity.stalled -and $activity.line -match 'verdict=PASS') 'stalled running check-in appends report verdict'
        $fixtureRecord.kind = 'test'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'non-worker jobs ignore OutputPath'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record ([pscustomobject]@{})).report_path) 'incomplete record never throws'
    }

    # Changed files reported from the job's changed-files.txt.
    $changedJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "Set-Content -LiteralPath (Join-Path `$env:DT_JOB_DIR 'changed-files.txt') -Value 'src/a.txt'; 'done'")
    Wait-JobTerminal -RunFolder $rf -JobId $changedJob.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $changedJob.job_id)
    Assert-True (@($envelope.changed_files) -contains 'src/a.txt') 'envelope reports changed files'

    # FS-129: reject expansion by the runner before a nested PowerShell starts (j-0148 shape).
    $rf = New-RunFolder 'nested-expansion'
    $unsafeCommand = 'pwsh -NoProfile -Command "Set-Location ''X''; & ''python.exe'' script.py --fixture; exit $LASTEXITCODE"'
    $refusedCommands = @(
        $unsafeCommand,
        'pwsh.exe -c "exit ${LASTEXITCODE}"',
        '& ''C:\Program Files\PowerShell\7\pwsh.exe'' -CommandWithArgs "Write-Output $env:PATH"',
        'powershell -Command "Write-Output $(Get-Date)"',
        '& ''C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'' -Command:"exit $code"',
        '& ''/usr/bin/pwsh'' -c "Write-Output $name"',
        'PWSH -COMMAND "Write-Output $(1 + 2)"'
    )
    foreach ($commandText in $refusedCommands) {
        $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $rf -Command $commandText -AllowTempRunFolder -Json 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_NESTED_EXPANSION') "refuses unsafe nested expansion: $commandText"
        Assert-True (-not (Test-Path (Join-Path $rf 'jobs/j-0001.json'))) 'refusal queues no job'
    }
    Assert-True (($raw -join ' ') -match 'single-quote' -and ($raw -join ' ') -match '-File <script>') 'refusal suggests safe alternatives'
    $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $rf -Command $unsafeCommand -AllowTempRunFolder -Json 2>&1
    Assert-True (($raw -join ' ') -match '\$LASTEXITCODE') 'j-0148 refusal names the expanded variable'
    $safeScript = Join-Path $rf 'safe.ps1'
    Write-Utf8 $safeScript 'exit 0'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Write-Output $PSVersionTable.PSVersion; exit 0'))
    $allowedCommands = @(
        'pwsh -NoProfile -Command ''Write-Output $PSVersionTable.PSVersion; exit 0''',
        "pwsh -NoProfile -File '$safeScript'",
        'pwsh -NoProfile -Command "Write-Output ok; exit 0"',
        'cmd /c exit 0',
        "pwsh -NoProfile -EncodedCommand $encoded"
    )
    foreach ($commandText in $allowedCommands) {
        $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', $commandText)
        Assert-True ((Wait-JobTerminal $rf $job.job_id).status -eq 'succeeded') "allows and runs safe command: $commandText"
    }
    $sourceJob = $job
    $beforeCount = @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count
    $raw = Invoke-TestPwsh -Script $dtJob start -RunFolder $rf -FromJob $sourceJob.job_id -Command $unsafeCommand -AllowTempRunFolder -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_NESTED_EXPANSION') 'FromJob validates an overridden command'
    # Simulate an unsafe legacy spec; neither relaunch path may queue it unchanged.
    $legacySpecPath = Join-Path $rf "jobs/$($sourceJob.job_id)/spec.json"
    $legacySpec = Get-Content -Raw $legacySpecPath | ConvertFrom-Json
    $legacySpec.command = $unsafeCommand
    Write-Utf8 $legacySpecPath ($legacySpec | ConvertTo-Json -Depth 8)
    $legacyRecordPath = Join-Path $rf "jobs/$($sourceJob.job_id).json"
    $legacyRecord = Get-JobRecord $rf $sourceJob.job_id
    $legacyRecord.status = 'cancelled'
    Write-Utf8 $legacyRecordPath ($legacyRecord | ConvertTo-Json -Depth 8)
    foreach ($relaunch in @(@('start', '-FromJob'), @('requeue', '-JobId'))) {
        $raw = Invoke-TestPwsh -Script $dtJob $relaunch[0] -RunFolder $rf $relaunch[1] $sourceJob.job_id -AllowTempRunFolder -Json 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_NESTED_EXPANSION') "$($relaunch[0]) rejects an unsafe stored command"
    }
    Assert-True (@(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count -eq $beforeCount) 'relaunch refusals queue no additional jobs'

    # Failure exit code from a plain native command, without a nested shell script.
    $rf = New-RunFolder 'fail'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'cmd /c exit 3')
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 3) "failure recorded exit 3 (status $($record.status), exit $($record.exit_code))"
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    Assert-True ($envelope.verdict -eq 'fail' -and @($envelope.blockers).Count -ge 1) 'failed envelope names a blocker'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "[Console]::Error.WriteLine('boom on stderr'); exit 2")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    Assert-True ($envelope.exit_code -eq 2 -and (@($envelope.stderr_excerpt) -contains 'boom on stderr')) 'failed envelope carries a stderr tail'
    # A pwsh child that writes its error as CLIXML: one long line, _xHHHH_ escapes, ANSI colours, message at the end.
    $clixmlPath = Join-Path $tempRoot 'clixml-stderr.txt'
    $esc = '_x001B_'
    $longPath = 'D:\fixture\' + ('deep\' * 60) + 'run-independent.ps1'
    $clixml = "#< CLIXML`r`n<Objs Version=`"1.1.0.1`" xmlns=`"http://schemas.microsoft.com/powershell/2004/04`"><S S=`"Error`">$esc[31;1mException: $esc[0m$longPath:147$esc[0m_x000D__x000A_</S><S S=`"Error`">$esc[31;1mLine |_x000D__x000A_</S><S S=`"Error`">     | $esc[31;1m~~~~~~~~~~$esc[0m_x000D__x000A_</S><S S=`"Error`">     | $esc[31;1mDIRECT_FILE_CAPTURE_FAILED &amp; settled$esc[0m_x000D__x000A_</S></Objs>"
    Write-Utf8 -Path $clixmlPath -Content $clixml
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "[Console]::Error.Write([System.IO.File]::ReadAllText('$clixmlPath')); exit 1")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    $errText = @($envelope.stderr_excerpt) -join "`n"
    Assert-True ($errText.Contains('| DIRECT_FILE_CAPTURE_FAILED & settled') -and -not $errText.Contains('CLIXML') -and -not $errText.Contains('_x001B_') -and -not $errText.Contains('~~~') -and -not $errText.Contains([char]27)) "a CLIXML stderr reaches the envelope as plain readable lines ($errText)"

    # Exit semantics: handled codes succeed; final callers propagate native codes.
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "cmd /c exit 3; 'done'")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'succeeded' -and $record.exit_code -eq 0) "earlier native failure with a succeeding final statement exits 0 ($($record.status), $($record.exit_code))"
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'first'; cmd /c exit 4")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 4) "failing final native command keeps its exit code ($($record.status), $($record.exit_code))"

    foreach ($failureCode in @(0, 7)) {
        $command = 'cmd /c exit ' + $failureCode + '; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
        $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', $command)
        $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
        $expectedStatus = if ($failureCode -eq 0) { 'succeeded' } else { 'failed' }
        Assert-True ($record.status -eq $expectedStatus -and $record.exit_code -eq $failureCode) "final conditional exit preserves native code $failureCode ($($record.status), $($record.exit_code))"
    }

    foreach ($case in @(
        @{ command = 'cmd /c exit 3; Write-Output "rc=$LASTEXITCODE"'; code = 0 },
        @{ command = 'cmd /c exit 3; $code=$LASTEXITCODE'; code = 0 },
        @{ command = 'cmd /c exit 1; if ($LASTEXITCODE -eq 1) { Write-Output changes }'; code = 0 },
        @{ command = 'cmd /c exit 3; if ($LASTEXITCODE -eq 3) { Write-Output tolerated } else { exit 5 }'; code = 5 },
        @{ command = 'cmd /c exit 3; if ($LASTEXITCODE -eq 0) { exit 5 } else { Write-Output tolerated }'; code = 5 },
        @{ command = 'cmd /c exit 3; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'; code = 3 },
        @{ command = 'cmd /c exit 3; exit $LASTEXITCODE'; code = 3 },
        @{ command = 'cmd /c exit 3; if ($?) { Write-Output ok } else { exit 5 }'; code = 0 }
    )) {
        $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', $case.command)
        $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
        $expectedStatus = if ($case.code -eq 0) { 'succeeded' } else { 'failed' }
        Assert-True ($record.status -eq $expectedStatus -and $record.exit_code -eq $case.code) "final statement: $($case.command) => $($record.status), $($record.exit_code)"
    }

    $nativeScript=Join-Path $tempRoot 'native failure with spaces.ps1'
    Write-Utf8 $nativeScript 'cmd /c exit 3'
    # -ScriptPath bypasses generation; pwsh -File still returns 0 without exit.
    $job=Invoke-DtJob @('start','-RunFolder',$rf,'-ScriptPath',$nativeScript)
    $record=Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'succeeded' -and $record.exit_code -eq 0) '-ScriptPath keeps HEAD pwsh -File semantics for an implicit native code'
    Write-Utf8 $nativeScript "cmd /c exit 3`nexit `$LASTEXITCODE"
    $job=Invoke-DtJob @('start','-RunFolder',$rf,'-ScriptPath',$nativeScript)
    $record=Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 3) '-ScriptPath preserves an explicit native exit'

    # -TimeoutSec is an expected duration, never a kill.
    $rf = New-RunFolder 'timeout'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 4', '-TimeoutSec', '1')
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id -TimeoutSec 30
    Assert-True ($record.status -eq 'succeeded' -and $record.timeout_sec -eq 0 -and $record.expected_sec -eq 1) "a job past its expected time runs to completion ($($record.status), $($record.timeout_sec), $($record.expected_sec))"

    # No job is stopped on time: -TimeoutSec becomes the expected duration.
    $rf = New-RunFolder 'agent-no-limit'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Write-Output ok # invoke-codex-chunk.ps1 -Category complex-coding', '-TimeoutSec', '660')
    $rec = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($rec.timeout_sec -eq 0 -and $rec.expected_sec -eq 660) "a wrapper job has no time limit, 660 s expected ($($rec.timeout_sec), $($rec.expected_sec))"
    $driver = Join-Path $rf 'driver.ps1'
    Set-Content -LiteralPath $driver -Value "& (Join-Path 'x' 'invoke-claude-chunk.ps1') -TimeoutMs 600000`nexit 0" -Encoding utf8
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-ScriptPath', $driver, '-TimeoutSec', '900')
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $job.job_id).timeout_sec -eq 0) 'a driver script that calls a wrapper has no time limit'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Write-Output ok', '-TimeoutSec', '900')
    $rec = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($rec.timeout_sec -eq 0 -and $rec.expected_sec -eq 900) 'a test or command job has no time limit either'

    # Check-ins: a silent agent job is reported stalled; a working one reports its activity.
    $rf = New-RunFolder 'stall'
    $env:DT_JOB_HEARTBEAT_SEC = '1'; $env:DT_JOB_STALL_SEC = '4'
    try {
        $quietRelease = Join-Path $rf 'quiet-release.txt'; $busyRelease = Join-Path $rf 'busy-release.txt'
        # Watch only this fixture directory; concurrent verification logs are not worker activity.
        Push-Location $rf
        try {
        $quiet = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', ((New-HeldJobCommand $quietRelease) + ' # invoke-codex-chunk.ps1'), '-TimeoutSec', '5')
        $busyCommand = (New-HeldJobCommand $busyRelease).Replace('Start-Sleep -Milliseconds 100', "Write-Output 'step'; Start-Sleep -Milliseconds 100")
        $busy = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', ($busyCommand + ' # invoke-codex-chunk.ps1'))
        } finally { Pop-Location }
        Start-Sleep -Seconds 7
        $checkin = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', "$($quiet.job_id),$($busy.job_id)", '-Any', '-TimeoutSec', '1')
        $q = @($checkin.progress | Where-Object { $_.job_id -eq $quiet.job_id })[0]
        $b = @($checkin.progress | Where-Object { $_.job_id -eq $busy.job_id })[0]
        Assert-True ($checkin.result -eq 'wait_timeout' -and $q.stalled -and $q.line -match 'STALLED' -and $q.line -match 'past its expected 1 min') "a silent agent job is reported stalled at a check-in ($($q.line))"
        Assert-True (-not $b.stalled -and $b.idle_sec -lt 4 -and $b.line -match 'last activity') "a working agent job reports activity, not a stall ($($b.line))"
        $status = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $quiet.job_id)
        Assert-True ($status.activity -match 'STALLED') "status shows a running job's activity ($($status.activity))"
        $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
        Assert-True (@($runStatus.stalled) -contains $quiet.job_id -and @($runStatus.stalled) -notcontains $busy.job_id) "run status names stalled jobs up front ($(@($runStatus.stalled) -join ','))"
        $text = Invoke-TestPwsh -Script $DtJob wait -RunFolder $rf -JobId $busy.job_id -Any -TimeoutSec 1
        Assert-True ((@($text) -join "`n") -match "$($busy.job_id) running \d+ min, last activity") "text check-in lists progress ($(@($text) -join ' | '))"
        Write-Utf8 $quietRelease 'release'
        $doneQuiet = Wait-JobTerminal -RunFolder $rf -JobId $quiet.job_id -TimeoutSec 30
        Assert-True ($doneQuiet.status -eq 'succeeded') "a stalled agent job is never stopped on time ($($doneQuiet.status))"
        Write-Utf8 $busyRelease 'release'
        Wait-JobTerminal -RunFolder $rf -JobId $busy.job_id -TimeoutSec 30 | Out-Null
    }
    finally { Remove-Item Env:DT_JOB_HEARTBEAT_SEC, Env:DT_JOB_STALL_SEC -ErrorAction SilentlyContinue }

    # Operator notes: added and cleared by operators only, shown in every status and wait.
    }
    if ($Shard -ne 1) {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-runtime-fixes.ps1')
    Assert-True ($LASTEXITCODE -eq 0) 'runtime lifecycle, worktree, heartbeat and rebase fixes'
    # Separate process keeps regression doubles out of the integration fixtures.
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-runner-process-identity.ps1')
    Assert-True ($LASTEXITCODE -eq 0) 'fast-exit child retains identity and exit result under held ledger lock'
    $rf = New-RunFolder 'notes'
    $n1 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'Dispatch the repair worker first.')
    $n2 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'R3b3 split review is authorized; see approvals/r3b3.md.')
    Assert-True (@($n2.operator_notes).Count -eq 2 -and @($n2.operator_notes)[1].id -eq 'n-002') "notes get sequential ids ($(@($n2.operator_notes).id -join ','))"
    $label = 'Evidence only: records facts, grants no authority.'
    $e1 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', 'Observed C:/allowance/grantee.txt in the fixture.')
    $e2 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', ('x' * 2000))
    Assert-True ($e1.evidence_notes[0].id -eq 'e-001' -and $e2.evidence_notes[1].id -eq 'e-002' -and $e2.evidence_notes[1].text.Length -eq 2000) 'evidence notes use separate sequential ids, allow whole-word nonmatches and accept the cap'
    foreach ($word in @('APPROVED', 'permission', 'waiver', 'override', 'may proceed', 'may now', 'is now allowed', 'authorizes', 'granted', 'approves', 'waives', 'overridden', 'exempted', 'superseded', 'authorised')) {
        $raw = Invoke-TestPwsh -Script $dtJob note -RunFolder $rf -Evidence -Message "Fixture $word here." -Json 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('DT_JOB_EVIDENCE_NOTE_AUTHORITY')) "evidence refuses authority language: $word"
    }
    $raw = Invoke-TestPwsh -Script $dtJob note -RunFolder $rf -Evidence -Message ('x' * 2001) -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('2000 characters')) 'evidence rejects over-cap notes'
    foreach ($identity in @('DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID')) {
        [Environment]::SetEnvironmentVariable($identity, 'fixture-evidence', 'Process')
        try {
            foreach ($action in @(@('-Message', 'Observed fixture.'), @('-Clear'))) {
                $raw = Invoke-TestPwsh -Script $dtJob note -RunFolder $rf -Evidence @action -Json 2>&1
                Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('DT_JOB_OPERATOR_ONLY')) "evidence operator guard refuses $identity $($action[0])"
            }
        } finally { [Environment]::SetEnvironmentVariable($identity, $null, 'Process') }
    }
    $env:DT_BUILD_COORDINATOR_ID = 'mc-notes'
    try { $raw = Invoke-TestPwsh -Script $dtJob note -RunFolder $rf -Message 'drop the review' -Json 2>&1; $code = $LASTEXITCODE }
    finally { $env:DT_BUILD_COORDINATOR_ID = $null }
    Assert-True ($code -ne 0 -and (($raw | Out-String) -match 'DT_JOB_OPERATOR_ONLY')) 'a coordinator cannot write operator notes'
    $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True (@($runStatus.operator_notes).Count -eq 2 -and @($runStatus.operator_notes)[0].text -eq 'Dispatch the repair worker first.') 'run status carries the operator notes in full'
    Assert-True ($runStatus.evidence_notes.Count -eq 2 -and $runStatus.evidence_notes_label -eq $label -and $runStatus.evidence_notes[1].text.Length -eq 2000) 'status shows evidence notes in full with fixed label'
    $statusText = (Invoke-TestPwsh -Script $dtJob status -RunFolder $rf | Out-String)
    Assert-True ($statusText.Contains($label) -and $statusText.IndexOf('operator note n-001:') -lt $statusText.IndexOf('evidence note e-001:')) 'status text prints evidence after operator notes'
    $read = Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path (Join-Path $rf 'evidence-notes.json') -Lines 1-20 -Json
    Assert-True ($LASTEXITCODE -eq 0 -and ($read -join "`n").Contains('e-001')) 'read-evidence resolves evidence-notes.json'
    $missingEvidence = Get-EvidenceError @{ RunFolder = $rf; Path = 'evidence-notes.json'; Lines = '1-20' }
    Assert-True ($missingEvidence.Contains('did you mean') -and $missingEvidence.Contains((Join-Path $rf 'evidence-notes.json'))) 'bare evidence filename suggests the run-folder path like operator notes'


    $release = Join-Path $rf 'release.txt'
    $noteJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release))
    $w = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', $noteJob.job_id, '-Any', '-TimeoutSec', '1')
    Assert-True (@($w.operator_notes).Count -eq 2) 'every wait check-in carries the operator notes'
    Assert-True ($w.evidence_notes.Count -eq 2 -and $w.evidence_notes_label -eq $label) 'wait carries evidence notes and fixed label'
    $text = Invoke-TestPwsh -Script $dtJob wait -RunFolder $rf -JobId $noteJob.job_id -Any -TimeoutSec 1
    Assert-True ((@($text) -join "`n") -match 'operator note n-001: Dispatch the repair worker first\.' -and @($text)[-1] -match '^wait_timeout') "text check-ins list notes and keep wait_timeout last ($(@($text) -join ' | '))"
    Write-Utf8 $release 'release'
    Assert-True (($text -join "`n").Contains($label) -and ($text -join "`n").Contains('evidence note e-001:')) 'wait text prints labeled evidence notes'
    $ec = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Clear', '-NoteId', 'e-001')
    $e3 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', 'Third observation.')
    Assert-True ($ec.evidence_notes.Count -eq 1 -and $ec.evidence_notes[0].id -eq 'e-002' -and $e3.evidence_notes[-1].id -eq 'e-003') 'evidence targeted clear preserves remaining ids'
    $ec = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Clear')
    $afterEvidenceClear = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True (@($ec.evidence_notes).Count -eq 0 -and $afterEvidenceClear.operator_notes.Count -eq 2) 'evidence clear leaves operator notes unchanged'
    Wait-JobTerminal -RunFolder $rf -JobId $noteJob.job_id | Out-Null
    $cleared = Invoke-DtJob @('note', '-RunFolder', $rf, '-Clear', '-NoteId', 'n-001')
    Assert-True (@($cleared.operator_notes).Count -eq 1 -and @($cleared.operator_notes)[0].id -eq 'n-002') 'clear -NoteId removes one note'
    $n3 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'Third.')
    Assert-True (@($n3.operator_notes)[-1].id -eq 'n-003') 'ids are never reused'
    $all = Invoke-DtJob @('note', '-RunFolder', $rf, '-Clear')
    Assert-True (@($all.operator_notes).Count -eq 0) 'clear alone removes every note'

    # Dependency chain: a failure blocks two levels downstream.
    $rf = New-RunFolder 'deps'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release -ExitCode 1))
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-DependsOn', $a.job_id)
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', $b.job_id)
    Assert-True ($b.status -eq 'queued' -and $c.status -eq 'queued') 'dependents wait queued'
    Write-Utf8 $release 'release'
    Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
    $rb = Wait-JobTerminal -RunFolder $rf -JobId $b.job_id
    $rc = Wait-JobTerminal -RunFolder $rf -JobId $c.job_id
    Assert-True ($rb.status -eq 'blocked' -and $rb.status_reason -match [regex]::Escape($a.job_id)) "level-1 dependent blocked with reason ($($rb.status): $($rb.status_reason))"
    Assert-True ($rc.status -eq 'blocked' -and $rc.status_reason -match [regex]::Escape($b.job_id)) "level-2 dependent blocked with reason ($($rc.status): $($rc.status_reason))"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rf "jobs/$($b.job_id)/stdout.log"))) 'blocked job never ran'
    $late = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'late'", '-DependsOn', $c.job_id)
    Assert-True ($late.status -eq 'blocked') 'job depending on an already-blocked job is blocked at start'
    $okA = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'a2'")
    $okB = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b2'", '-DependsOn', $okA.job_id)
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $okB.job_id).status -eq 'succeeded') 'dependent starts after its dependency succeeds'
    # Older run records predate memory measurements and must still requeue.
    $legacy = Get-JobRecord $rf $b.job_id
    $legacy.PSObject.Properties.Remove('peak_memory_gb')
    Write-Utf8 (Join-Path $rf "jobs/$($b.job_id).json") ($legacy | ConvertTo-Json -Depth 12)
    $legacyStatus = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $b.job_id)
    Assert-True ($null -eq $legacyStatus.peak_memory_gb) 'legacy status exposes a null peak'
    $requeued = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $b.job_id, '-DependsOn', $okA.job_id)
    Assert-True ($requeued.job_id -ne $b.job_id -and $requeued.requeued_from -eq $b.job_id) 'requeue allocates a new identity'
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $requeued.job_id).status -eq 'succeeded') 'requeued blocked consumer runs after replacement dependency succeeds'
    Assert-True ((Get-JobRecord $rf $b.job_id).status -eq 'blocked') 'original blocked record stays terminal'
    $oldSpec = [IO.File]::ReadAllText((Join-Path $rf "jobs/$($b.job_id)/spec.json"))
    Assert-True ($oldSpec -ceq [IO.File]::ReadAllText((Join-Path $rf "jobs/$($requeued.job_id)/spec.json"))) 'requeue preserves the complete spec'
    $unchanged = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $c.job_id)
    Assert-True ($unchanged.status -eq 'blocked' -and (Get-JobRecord $rf $unchanged.job_id).depends_on[0] -eq $b.job_id) 'omitted dependency override preserves the original chain'
    $restartedTail = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $c.job_id, '-DependsOn', $requeued.job_id)
    Assert-True ((Wait-JobTerminal $rf $restartedTail.job_id).status -eq 'succeeded') 'a multi-level chain restarts against new predecessor IDs'
    $raw = Invoke-TestPwsh -Script $dtJob requeue -RunFolder $rf -JobId $okA.job_id -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n") -match 'DT_JOB_REQUEUE_STATE') 'requeue rejects a succeeded job'
    $countBefore = @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count
    Invoke-TestPwsh -Script $dtJob requeue -RunFolder $rf -JobId $b.job_id -DependsOn j-9999 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0 -and @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count -eq $countBefore) 'unknown dependency fails without allocating a job'
    $heldRelease = Join-Path $rf 'requeue-held.txt'
    $held = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $heldRelease))
    $cancelSource = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'cancel-copy'", '-DependsOn', $held.job_id)
    Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $cancelSource.job_id) | Out-Null
    $cancelCopy = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $cancelSource.job_id)
    Assert-True ($cancelCopy.status -eq 'queued') 'cancelled job requeues and waits on its original dependency'
    Write-Utf8 $heldRelease 'release'
    Assert-True ((Wait-JobTerminal $rf $cancelCopy.job_id).status -eq 'succeeded' -and (Get-JobRecord $rf $cancelSource.job_id).status -eq 'cancelled') 'cancelled source remains terminal while new job succeeds'

    # Mutation key: a second job on the same key queues until the key frees.
    $rf = New-RunFolder 'mutates'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'worktree:main')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'worktree:main')
    Assert-True ($a.status -eq 'running') 'key holder runs'
    Assert-True ($b.status -eq 'queued') 'second job on the same key queues'
    $other = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'other'", '-Mutates', 'worktree:other')
    Assert-True ($other.status -eq 'running') 'job on a different key runs'
    Write-Utf8 $release 'release'
    $ra = Wait-JobTerminal -RunFolder $rf -JobId $a.job_id
    $rb = Wait-JobTerminal -RunFolder $rf -JobId $b.job_id
    Assert-True ($rb.status -eq 'succeeded') "queued key job ran after release ($($rb.status))"
    Assert-True (([DateTime]$rb.started).ToUniversalTime() -ge ([DateTime]$ra.ended).ToUniversalTime()) 'second key job started after the first ended'
    Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $rf 'jobs/locks') -Filter 'key-*.lock')).Count -eq 0) 'key locks released'

    # Cancel queued and cancel running.
    $rf = New-RunFolder 'cancel'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'k')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'k')
    $cb = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $b.job_id)
    Assert-True ($cb.status -eq 'cancelled') 'queued job cancelled'
    Write-Utf8 $release 'release'
    Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
    Start-Sleep -Seconds 2
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $b.job_id).status -eq 'cancelled') 'cancelled queued job stays cancelled after its key frees'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rf "jobs/$($b.job_id)/stdout.log"))) 'cancelled queued job never launched'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'cancel-release.txt')), '-Mutates', 'k2')
    $rc = Wait-JobState -RunFolder $rf -JobId $c.job_id -Until { param($r) [bool]$r.pid }
    $cc = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $c.job_id)
    Assert-True ($cc.status -eq 'cancelled') 'running job cancelled'
    Start-Sleep -Seconds 1
    Assert-True ((Test-ProcessGone $rc.pid) -and (Test-ProcessGone $rc.runner_pid)) 'cancelled running job processes stopped'
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $c.job_id).status -eq 'cancelled') 'cancel is not overwritten by the runner'
    Assert-True (-not (Test-Path -Path (Join-Path $rf 'jobs/locks/key-k2-*.lock'))) 'cancel frees the mutation key'

    # FS-96: job custody must retain a grandchild after its intermediate parent exits.
    if ($IsWindows) {
        $rf = New-RunFolder 'cancel-process-tree'
        $directMarker = 'dt-job-child-' + [guid]::NewGuid().ToString('N')
        do {
            $pingMarker = '127.0.0.' + (Get-Random -Minimum 2 -Maximum 255)
        } while (@(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like "*$pingMarker*" }).Count -gt 0)
        $fixture = Join-Path $rf 'launch-tree.ps1'
        $custodyScript = (Join-Path $scriptDir 'worker-process-tree.ps1').Replace("'", "''")
        Write-Utf8 $fixture @"
`$ErrorActionPreference = 'Stop'
. '$custodyScript'
if ((Initialize-WorkerProcessJob) -ne 'job_object' -or -not `$script:WorkerJobKillOnClose) { throw 'fixture requires kill-on-close job custody' }
`$psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
`$psi.Arguments = '/c start /b ping -n 300 $pingMarker'
`$intermediate = [Diagnostics.Process]::Start(`$psi)
`$intermediate.WaitForExit()
`$psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
foreach (`$arg in @('-NoProfile', '-Command', 'Start-Sleep 300  # $directMarker')) { `$psi.ArgumentList.Add(`$arg) }
`$null = [Diagnostics.Process]::Start(`$psi)
Start-Sleep 300
"@
        $treeJob = $null
        try {
            $treeJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "& '$($fixture.Replace("'", "''"))'")
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'")
                $pingChildren = @($processes | Where-Object { $_.Name -ieq 'ping.exe' -and $_.CommandLine -like "*$pingMarker*" })
                $directChildren = @($processes | Where-Object { $_.Name -ieq 'pwsh.exe' -and $_.CommandLine -like "*$directMarker*" })
                if ($pingChildren.Count -gt 0 -and $directChildren.Count -gt 0) { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-True ($pingChildren.Count -eq 1 -and $directChildren.Count -eq 1) 'cancel fixture starts an orphan grandchild and a direct child after cmd exits'
            Assert-True (Test-ProcessGone $pingChildren[0].ParentProcessId) 'cancel fixture intermediate parent has exited'
            $cancelled = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $treeJob.job_id)
            Assert-True ($cancelled.status -eq 'cancelled') 'process tree job is cancelled'
            $remaining = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -like "*$pingMarker*" -or $_.CommandLine -like "*$directMarker*" })
            Assert-True ($remaining.Count -eq 0) 'cancel removes the orphan grandchild and direct child markers'

            $deadRecord = Get-JobRecord -RunFolder $rf -JobId $treeJob.job_id
            $deadProbe = ". '$($dtJob.Replace("'", "''"))'; `$deadPidRecord = Get-Content -Raw -LiteralPath '$((Join-Path $rf "jobs/$($treeJob.job_id).json").Replace("'", "''"))' | ConvertFrom-Json; @(Stop-DtJobProcesses -Record `$deadPidRecord).Count"
            $deadCount = & pwsh -NoProfile -Command $deadProbe
            Assert-True ($LASTEXITCODE -eq 0 -and "$deadCount" -eq '0' -and (Test-ProcessGone $deadRecord.pid) -and (Test-ProcessGone $deadRecord.runner_pid)) 'Stop-DtJobProcesses returns an empty array for dead pids'
        }
        finally {
            if ($treeJob) { Invoke-TestPwsh -Script $dtJob cancel -RunFolder $rf -JobId $treeJob.job_id -Json | Out-Null }
            Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -like "*$pingMarker*" -or $_.CommandLine -like "*$directMarker*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    } else { Write-Output 'SKIP: FS-96 Windows process tree cancellation and dead-pid regressions' }

    # Race: cancel against launch. Whatever wins, a cancelled job never does its work.
    foreach ($delayMs in @(700, 1100, 1500)) {
        $rf = New-RunFolder "race-$delayMs"
        $marker = Join-Path $rf 'marker.txt'
        $release = Join-Path $rf 'release.txt'; $workRelease = Join-Path $rf 'work-release.txt'
        $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'race')
        $workCommand = (New-HeldJobCommand $workRelease).Replace('exit 0', "Set-Content -LiteralPath '$($marker.Replace("'", "''"))' -Value 'ran'")
        $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', $workCommand, '-Mutates', 'race')
        Start-Sleep -Milliseconds $delayMs
        $cancel = Start-Process -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-File', "`"$dtJob`"", 'cancel', '-RunFolder', "`"$rf`"", '-JobId', $b.job_id, '-Json') -PassThru @HiddenWindow
        Write-Utf8 $release 'release'
        $cancel.WaitForExit()
        Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
        Write-Utf8 $workRelease 'release'
        Start-Sleep -Seconds 3
        $rb = Get-JobRecord -RunFolder $rf -JobId $b.job_id
        Assert-True ($rb.status -eq 'cancelled') "race ($delayMs ms): job ended cancelled ($($rb.status))"
        Assert-True (-not (Test-Path -LiteralPath $marker)) "race ($delayMs ms): cancelled job never did its work"
    }

    # Reconcile: a killed job becomes orphaned (never succeeded) and its keys free.
    $rf = New-RunFolder 'orphan'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'release.txt')), '-Mutates', 'shared')
    $ra = Wait-JobState -RunFolder $rf -JobId $a.job_id -Until { param($r) [bool]$r.pid }
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'after'", '-Mutates', 'shared')
    Assert-True ($b.status -eq 'queued') 'job queues behind the soon-killed key holder'
    Stop-Process -Id ([int]$ra.runner_pid) -Force
    Stop-Process -Id ([int]$ra.pid) -Force
    Start-Sleep -Milliseconds 500
    $rec = Invoke-DtJob @('reconcile', '-RunFolder', $rf)
    Assert-True (@($rec.orphaned) -contains $a.job_id) 'reconcile reports the orphan'
    $ra = Get-JobRecord -RunFolder $rf -JobId $a.job_id
    Assert-True ($ra.status -eq 'orphaned') "killed job is orphaned ($($ra.status))"
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $b.job_id).status -eq 'succeeded') 'reconcile freed the key and started the queued job'

    # PID reuse: a live PID whose start time does not match is not alive.
    $rf = New-RunFolder 'pid-reuse'
    $now = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    $base = [ordered]@{ run_id = 'pid-reuse'; kind = 'command'; category = $null; vendor = $null; model = $null; runner_pid = $null; runner_start_utc = $null; command_sha256 = 'x'; depends_on = @(); mutates = @(); status = 'running'; status_reason = $null; exit_code = $null; timeout_sec = 0; working_directory = $rf; output_path = 'x'; stderr_path = 'x'; summary_path = 'x'; queued = $now; started = $now; ended = $null; last_progress = $now }
    $reused = [ordered]@{ job_id = 'j-0001'; pid = $PID; process_start_utc = '2000-01-01T00:00:00.0000000Z' } + $base
    $live = [ordered]@{ job_id = 'j-0002'; pid = $PID; process_start_utc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } + $base
    Write-Utf8 (Join-Path $rf 'jobs/j-0001.json') ($reused | ConvertTo-Json)
    Write-Utf8 (Join-Path $rf 'jobs/j-0002.json') ($live | ConvertTo-Json)
    $rec = Invoke-DtJob @('reconcile', '-RunFolder', $rf)
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId 'j-0001').status -eq 'orphaned') 'start-time mismatch on a live PID is not alive'
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId 'j-0002').status -eq 'running') 'matching PID and start time is alive'

    # Envelope cap: one very long line and many lines.
    $rf = New-RunFolder 'envelope'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "1..3000 | ForEach-Object { 'y' * 300 }; 'z' * 5000")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $raw = (Invoke-TestPwsh -Script $dtJob status -RunFolder $rf -JobId $job.job_id -Json) -join "`n"
    $envelope = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 8192) "envelope within 8 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True ($envelope.truncated -eq $true) 'envelope marks truncation'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.stdout) 'truncation names the full stdout evidence path'
    Assert-True ((@($envelope.excerpt | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'every envelope line within 400 characters'
    Assert-True (@($envelope.excerpt).Count -ge 1 -and $envelope.excerpt[-1].StartsWith('zzz')) 'excerpt keeps the stdout tail'
    $summary = Get-Content -Raw -LiteralPath (Get-JobRecord -RunFolder $rf -JobId $job.job_id).summary_path | ConvertFrom-Json
    Assert-True ($summary.status -eq 'succeeded') 'runner wrote the bounded summary'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "1..3000 | ForEach-Object { 'y' * 300 }; 1..200 | ForEach-Object { [Console]::Error.WriteLine('e' * 600) }; exit 1")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $raw = (Invoke-TestPwsh -Script $dtJob status -RunFolder $rf -JobId $job.job_id -Json) -join "`n"
    $envelope = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 8192) "failed envelope with stderr within 8 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True (@($envelope.stderr_excerpt).Count -ge 1 -and (@($envelope.stderr_excerpt | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'stderr tail present and line-capped'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.stderr) 'stderr truncation names the full stderr evidence path'
    $long = [ordered]@{ job_id = 'j-0099'; status = 'failed'; status_reason = ('r' * 1000); exit_code = 1 }
    Write-Utf8 (Join-Path $rf 'jobs/j-0099.json') ($long | ConvertTo-Json)
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', 'j-0099')
    Assert-True ($envelope.truncated -eq $true -and $envelope.status_reason.Length -le 400) 'cut status_reason marks truncation'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.job_file) 'cut status_reason names the job file as evidence'

    # read-evidence: cap, log entry, repeat-read warning.
    $rf = New-RunFolder 'evidence'
    $evidenceFile = Join-Path $rf 'big.log'
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 5000; $i++) { $lines.Add(('line {0} ' -f $i) + ('x' * 100)) }
    $lines[9] = 'LONG ' + ('q' * 1000)
    Write-Utf8 $evidenceFile (($lines -join "`n") + "`n")
    $raw = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000' -Json) -join "`n"
    $read = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 16384) "read-evidence reply within 16 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True ($read.truncated -eq $true -and $read.evidence_path -eq $evidenceFile) 'read-evidence marks truncation with the evidence path'
    Assert-True ((@($read.lines | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'read-evidence lines within 400 characters'
    $grep = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Grep '^LONG' -Context 1 -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($grep.lines).Count -eq 3 -and $grep.lines[1].StartsWith('10: LONG') -and $grep.truncated) 'grep with context returns the hit and neighbours, line-capped'
    $first = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($first.warnings).Count -eq 0 -and @($first.lines).Count -eq 3) 'first read of a range has no warning'
    $second = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True ((@($second.warnings) -join ' ') -match 'repeat_read') 'repeat read of an unchanged range warns'
    Add-Content -LiteralPath $evidenceFile -Value 'appended'
    $third = (Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($third.warnings).Count -eq 0) 'read after the file changed is not a repeat'
    $log = @(Get-Content -LiteralPath (Join-Path $rf 'jobs/reads.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($log.Count -eq 5) "reads.jsonl has one entry per call ($($log.Count))"
    Assert-True ((@($log | Where-Object { -not ($_.path -and $_.sha256 -and $null -ne $_.bytes_returned -and $_.selector) })).Count -eq 0) 'each read log entry has path, selector, sha256, bytes'
    Assert-True ($log[1].selector.mode -eq 'grep' -and $log[1].selector.pattern -eq '^LONG' -and $log[3].repeat_read -eq $true) 'read log records pattern and repeat flag'
    # Text mode: the warning and the truncation marker count against the 16 KB cap.
    $rf = New-RunFolder 'evidence-text'
    Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000' | Out-Null
    $text = @(Invoke-TestPwsh -Script $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000')
    $textBytes = ($text | ForEach-Object { [System.Text.Encoding]::UTF8.GetByteCount($_) + [Environment]::NewLine.Length } | Measure-Object -Sum).Sum
    Assert-True ($textBytes -le 16384) "text-mode read with warning and marker within 16 KB ($textBytes bytes)"
    Assert-True ($text[0].StartsWith('WARNING repeat_read') -and $text[-1].StartsWith('[truncated: true')) 'text-mode read shows the warning and the truncation marker'

    # Concurrent readers: a tight status loop never turns a finishing job into a failure.
    $rf = New-RunFolder 'contention'
    $stopFile = Join-Path $rf 'stop.txt'
    $loopScript = Join-Path $tempRoot 'status-loop.ps1'
    Write-Utf8 $loopScript @'
param([string]$DtJob, [string]$RunFolder, [string]$Stop)
. $DtJob -RunFolder $RunFolder
$jobsDir = Join-Path $RunFolder 'jobs'
while (-not (Test-Path -LiteralPath $Stop)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $jobsDir -Filter 'j-*.json' -File -ErrorAction SilentlyContinue)) {
        # A slow foreign reader (Get-Content's share mode) holding the record open blocks a replace.
        try { $held = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); Start-Sleep -Milliseconds 20; $held.Dispose() } catch { }
        try { New-DtJobEnvelope -RunFolder $RunFolder -Record (Read-DtJobText -Path $f.FullName | ConvertFrom-Json) | Out-Null } catch { }
    }
}
'@
    New-Item -ItemType Directory -Path (Join-Path $rf 'jobs') -Force | Out-Null
    $loop = Start-Process -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-File', "`"$loopScript`"", '-DtJob', "`"$dtJob`"", '-RunFolder', "`"$rf`"", '-Stop', "`"$stopFile`"") -PassThru @HiddenWindow
    try {
        $ids = @(1..8 | ForEach-Object { (Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "Start-Sleep -Milliseconds 300; 'ok $_'")).job_id })
        $states = @($ids | ForEach-Object { (Wait-JobTerminal -RunFolder $rf -JobId $_).status })
    }
    finally {
        Write-Utf8 $stopFile 'stop'
        if (-not $loop.WaitForExit(10000)) { $loop.Kill() }
    }
    Assert-True ((@($states | Where-Object { $_ -ne 'succeeded' })).Count -eq 0) "every job under a tight status loop succeeded ($($states -join ','))"
    Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $rf 'jobs') -Recurse -File -Filter '*.tmp')).Count -eq 0) 'no stray temp files after contended writes'

    # Lists under pwsh -File: comma-separated keys and dependencies split.
    $rf = New-RunFolder 'lists'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'a,b')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'a')
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $a.job_id).mutates) -join '|') -eq 'a|b') 'comma-separated -Mutates splits into two keys'
    Assert-True ($a.status -eq 'running' -and $b.status -eq 'queued') 'one-key job queues behind the two-key job sharing a key'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', "$($a.job_id), $($b.job_id)")
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $c.job_id).depends_on) -join '|') -eq "$($a.job_id)|$($b.job_id)") 'comma-separated -DependsOn resolves both jobs'
    Write-Utf8 $release 'release'
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $c.job_id).status -eq 'succeeded') 'job with two dependencies runs after both succeed'

    # Environment pass-through: allow-listed caller variables reach the job; secrets only when named.
    $rf = New-RunFolder 'env'
    $env:DT_PROBE_VAR = 'hello'; $env:PROBE_PASS = 'passed'; $env:DT_PROBE_TOKEN = 'unnamed-secret'; $env:PROBE_API_KEY = 'named-secret'
    try {
        $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-PassEnv', 'PROBE_PASS,PROBE_API_KEY', '-Command', "'env=[{0}][{1}][{2}][{3}]' -f `$env:DT_PROBE_VAR, `$env:PROBE_PASS, `$env:DT_PROBE_TOKEN, `$env:PROBE_API_KEY")
    }
    finally {
        Remove-Item Env:DT_PROBE_VAR, Env:PROBE_PASS, Env:DT_PROBE_TOKEN, Env:PROBE_API_KEY -ErrorAction SilentlyContinue
    }
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $stdout = Get-Content -Raw -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/stdout.log")
    Assert-True ($stdout.Trim() -eq 'env=[hello][passed][][named-secret]') "caller environment reaches the job ($($stdout.Trim()))"
    Assert-True (-not ((Get-Content -Raw -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/spec.json")) -match 'unnamed-secret')) 'unnamed secret-looking variable never written to the spec'

    # Runner died but child lives: reconcile leaves it running, and a check-in reports it stalled.
    $rf = New-RunFolder 'expire'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'release.txt')), '-TimeoutSec', '20', '-Mutates', 'exp')
    $record = Wait-JobState -RunFolder $rf -JobId $job.job_id -Until { param($r) [bool]$r.pid }
    Stop-Process -Id ([int]$record.runner_pid) -Force
    Start-Sleep -Milliseconds 500
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $job.job_id).status -eq 'running') 'a live child stays running'
    $record = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Remove-Item -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/heartbeat.json") -Force -ErrorAction SilentlyContinue
    $record.started = [DateTime]::UtcNow.AddSeconds(-60).ToString('o')
    Write-Utf8 (Join-Path $rf "jobs/$($job.job_id).json") ($record | ConvertTo-Json -Depth 8)
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    $after = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($after.status -eq 'running') "a job past its expected time is never ended by reconcile ($($after.status))"
    $env:DT_JOB_STALL_SEC = '30'
    try { $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf) } finally { Remove-Item Env:DT_JOB_STALL_SEC -ErrorAction SilentlyContinue }
    Assert-True (@($runStatus.stalled) -contains $job.job_id) 'a job whose runner died shows as stalled'
    Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $job.job_id) | Out-Null
    Start-Sleep -Milliseconds 500
    Assert-True (Test-ProcessGone $record.pid) 'cancel stops the child'
    Assert-True (-not (Test-Path -Path (Join-Path $rf 'jobs/locks/key-exp-*.lock'))) 'a cancelled job frees its key'

    # A partial last line in events.jsonl does not wedge later transitions.
    $rf = New-RunFolder 'partial-event'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'one'")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $eventsPath = Join-Path $rf 'jobs/events.jsonl'
    $lastSeq = [int](@(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })[-1].seq)
    [System.IO.File]::AppendAllText($eventsPath, '{"seq":99,"job_')
    $job2 = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'two'")
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $job2.job_id).status -eq 'succeeded') 'transition succeeds after a partial event line'
    $parsed = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { } })
    $after = @($parsed | Where-Object { $_.job_id -eq $job2.job_id } | ForEach-Object { [int]$_.seq })
    # The first job's record turns terminal before its final event lands, so read the
    # predecessor seq from the events written before job two, not from the earlier snapshot.
    $lastSeq = [int](@($parsed | Where-Object { $_.job_id -ne $job2.job_id -and $after.Count -ge 1 -and [int]$_.seq -lt $after[0] } | ForEach-Object { [int]$_.seq } | Measure-Object -Maximum).Maximum)
    Assert-True ($after.Count -ge 1 -and $after[0] -eq $lastSeq + 1 -and (($after -join ',') -eq (($lastSeq + 1)..($lastSeq + $after.Count) -join ','))) "events continue at the next seq ($lastSeq -> $($after -join ','))"

    # FS-133: host-disruptive stops name other registered builds, using only fake alerts.
    & {
        . $dtJob
        foreach ($wording in @('power off', 'power-off', 'SHUTDOWN', 'shut down', 'reboot', 'restart the machine', 'restart host', 'restart the PC', 'hard reset', 'pull the plug')) {
            Assert-True (Test-DtJobHostDisruption -Operation 'fixture' -Message "Please $wording SNOWWHITE.") "host disruption recognizes $wording in Message"
            Assert-True (Test-DtJobHostDisruption -Operation $wording -Message 'Fixture.') "host disruption recognizes $wording in Operation"
        }
        foreach ($wording in @('restart the app', 'review shutdowns', 'power officer', 'rebooting documentation')) {
            Assert-True (-not (Test-DtJobHostDisruption -Operation 'review' -Message $wording)) "host disruption excludes unrelated wording: $wording"
        }
    }
    $hostRegistry = $env:DT_BUILD_STATE_DIR
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'host-conflict-registry'
    $hostA = New-RunFolder 'host-a'
    $hostB = New-RunFolder 'host-b'
    $releaseA = Join-Path $hostA 'release'
    $releaseB = Join-Path $hostB 'release'
    try {
        foreach ($fixture in @(@($hostA, 'host-a'), @($hostB, 'host-b'))) {
            $state = Join-Path $fixture[0] '_build-state.md'
            Write-Utf8 $state "run_status: runnable`nlast_consumed_event_seq: 0`n"
            Invoke-DtJob @('register-run', '-RunFolder', $fixture[0], '-RunId', $fixture[1], '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed') | Out-Null
        }
        $ownJob = Invoke-DtJob @('start', '-RunFolder', $hostA, '-Command', (New-HeldJobCommand $releaseA))
        $otherJob = Invoke-DtJob @('start', '-RunFolder', $hostB, '-Command', (New-HeldJobCommand $releaseB), '-Kind', 'test')
        $null = Wait-JobState $hostA $ownJob.job_id { param($r) $r.status -eq 'running' }
        $otherRecord = Wait-JobState $hostB $otherJob.job_id { param($r) $r.status -eq 'running' }
        # A fixed summer instant verifies Eastern daylight time independently of the host timezone.
        $otherRecord.started = '2026-07-01T16:30:00Z'
        Write-Utf8 (Join-Path $hostB "jobs/$($otherJob.job_id).json") ($otherRecord | ConvertTo-Json -Depth 8)
        Invoke-DtJob @('await-danny', '-RunFolder', $hostA, '-Operation', 'crash-recovery', '-Message', 'Please POWER OFF SNOWWHITE.') | Out-Null
        $awaiting = (Get-Content -Raw (Join-Path $hostA 'approvals.json') | ConvertFrom-Json).awaiting
        $conflicts = @($awaiting.host_conflicts)
        Assert-True ($conflicts.Count -eq 1 -and $conflicts[0].run_id -ceq 'host-b' -and $conflicts[0].job_id -ceq $otherJob.job_id) 'disruptive stop records only the other build running job, excluding its own'
        Assert-True ($conflicts[0].kind -ceq 'test' -and ([datetime]$conflicts[0].started_utc).ToUniversalTime() -eq ([datetime]'2026-07-01T16:30:00Z').ToUniversalTime() -and $conflicts[0].run_folder -ceq $hostB) 'host conflict records kind, start instant and run folder'
        $status = Invoke-DtJob @('status', '-RunFolder', $hostA)
        Assert-True (($status.awaiting.host_conflicts | ConvertTo-Json -Compress) -ceq ($conflicts | ConvertTo-Json -Compress)) 'status JSON exposes the persisted host conflicts inside awaiting'
        $dm = @((Get-Content $env:DT_TEST_DM_LOG | ForEach-Object { ($_ | ConvertFrom-Json).content }) | Where-Object { $_ -match 'Build host-a needs a decision' })[-1]
        Assert-True ($dm.Contains("host-b/$($otherJob.job_id) (started 2026-07-01 12:30 PM ET)") -and $dm.Contains('Wait for them before powering off') -and -not $dm.Contains("host-a/$($ownJob.job_id)")) 'fake alert names the other job with Eastern daylight time and wait instruction'
        Invoke-DtJob @('await-danny', '-RunFolder', $hostA, '-Operation', 'reboot-host', '-Message', 'Crash recovery fixture.') | Out-Null
        $status = Invoke-DtJob @('status', '-RunFolder', $hostA)
        Assert-True (@($status.awaiting.host_conflicts).Count -eq 1) 'disruption in Operation also collects conflicts'
        Invoke-DtJob @('await-danny', '-RunFolder', $hostA, '-Operation', 'manual-review', '-Message', 'Review fixture output.') | Out-Null
        $awaiting = (Get-Content -Raw (Join-Path $hostA 'approvals.json') | ConvertFrom-Json).awaiting
        Assert-True (-not $awaiting.PSObject.Properties['host_conflicts']) 'non-disruptive stop records no host conflicts'
        $dm = (Get-Content $env:DT_TEST_DM_LOG | Select-Object -Last 1 | ConvertFrom-Json).content
        Assert-True (-not $dm.Contains('Other builds still have running jobs')) 'non-disruptive fake alert has no host warning'
        Invoke-DtJob @('unregister-run', '-RunFolder', $hostB) | Out-Null
        Invoke-DtJob @('await-danny', '-RunFolder', $hostA, '-Operation', 'shutdown', '-Message', 'Crash recovery fixture.') | Out-Null
        $status = Invoke-DtJob @('status', '-RunFolder', $hostA)
        Assert-True (@($status.awaiting.host_conflicts).Count -eq 0) 'unregistered jobs are not scanned and own running jobs remain excluded'
    } finally {
        Write-Utf8 $releaseA 'release'
        Write-Utf8 $releaseB 'release'
        $env:DT_BUILD_STATE_DIR = $hostRegistry
    }

    # Round-two regressions run in an isolated process and the suite's private registry.
    $roundTwoScript = Join-Path $tempRoot 'director-regressions.ps1'
    Write-Utf8 $roundTwoScript @'
param($Runtime, $Root)
. $Runtime
$env:DT_BUILD_HEADLESS = $null
$env:DT_BUILD_COORDINATOR_ID = $null
$env:DT_JOB_ID = $null
$env:CC_SESSION_NAME = 'Reopened director'
$env:CC_SESSION_ID = 'reopened-session'
$env:CODEX_THREAD_ID = 'codex-reopened-thread'
$env:CLAUDE_CODE_SESSION_ID = 'claude-reopened-session'
$LaunchedBy = 'interactive'
$AllowTempRunFolder = $true
$Json = $true
$script:DtJobExplicitParams = @()
$script:failures = @()
function Check($Condition, $Message) { if (-not $Condition) { $script:failures += $Message } }
# Deterministic ancestry, including misleading wrapper names and headless children.
function Get-Process { param([int]$Id, $ErrorAction); [pscustomobject]@{ Id=$Id; ProcessName=$script:names[$Id] } }
function ps { param([string]$o, [int]$p); $script:parents[$p] }
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction); [pscustomobject]@{ ParentProcessId=$script:parents[[int]($Filter -replace 'ProcessId=', '')] } }
function Get-DtJobProcessArguments { param([int]$ProcessId); $script:arguments[$ProcessId] }
function Get-DtJobProcessStartUtc { param([int]$ProcessId); '2026-11-24T00:00:00Z' }
$script:names = @{ $PID='pwsh'; 900001='codex-code-mode'; 900002='node'; 900003='claude'; 900004='codex'; 900005='systemd' }
$script:parents = @{ $PID=900001; 900001=900002; 900002=900003; 900003=900004; 900004=900005; 900005=1 }
$script:arguments = @{ 900001=@('codex-code-mode'); 900002=@('node','claude'); 900003=@('claude','-p','prompt'); 900004=@('codex') }
$found = Get-DtJobLaunchingDirector
Check ($found.pid -eq 900004) 'skips wrappers and claude -p to interactive codex'
Check ($found.session_id -ceq 'codex-reopened-thread') 'Codex provider thread wins over inherited Claude and CC ids'
foreach ($argv in @(@('codex','--model','e','resume','e'), @('codex','resume','e'), @('codex','--config','key="e"','e'), @('codex','-C','/tmp','exec'))) {
    $expected = $argv[-1] -ceq 'exec' -or $argv[1] -ceq '--config'
    Check ((Test-DtJobCodexHeadless -Arguments $argv) -eq $expected) ('Codex first-subcommand parsing: ' + ($argv -join ' '))
}
$script:arguments[900003] = @('claude')
Check ((Get-DtJobLaunchingDirector).session_id -ceq 'claude-reopened-session') 'Claude provider session wins over CC id'
$script:arguments[900003] = @('claude','-p','prompt')
$CoordinatorId = 'explicit-coordinator'
Check ($null -eq (Get-DtJobLaunchingDirector)) 'explicit CoordinatorId never records director'
try { Assert-DtJobOperator -VerbName 'director takeover' -RunFolder $Root -AllowLiveCoordinator; Check $false 'explicit CoordinatorId refused' } catch { Check ($_ -match 'DT_JOB_OPERATOR_ONLY') 'explicit CoordinatorId refused' }
$CoordinatorId = $null
$script:DtJobExplicitParams = @('CoordinatorId')
Check ($null -eq (Get-DtJobLaunchingDirector)) 'even an empty explicitly passed CoordinatorId excludes director registration'
$script:DtJobExplicitParams = @()
$script:arguments[900003] = @('claude','--print','prompt')
Check ((Get-DtJobLaunchingDirector).pid -eq 900004) 'skips claude --print'
$script:arguments[900003] = @('codex','exec','prompt'); $script:names[900003]='codex'
Check ((Get-DtJobLaunchingDirector).pid -eq 900004) 'skips codex exec'
$script:arguments[900004] = @('codex','exec','prompt')
Check ($null -eq (Get-DtJobLaunchingDirector)) 'headless-only systemd ancestry has no director'
$script:parents[900002] = 900005
Check ($null -eq (Get-DtJobLaunchingDirector)) 'node and codex-code-mode never become directors'
$LaunchedBy = 'watcher'
Check ($null -eq (Get-DtJobLaunchingDirector)) 'watcher launch has no director'
$LaunchedBy = 'interactive'
Remove-Item Function:Get-Process
Remove-Item Function:ps
Remove-Item Function:Get-CimInstance
Remove-Item Function:Get-DtJobProcessStartUtc
# Reload real process identity implementation, then supply a stable interactive caller.
. $Runtime
$LaunchedBy = 'interactive'; $AllowTempRunFolder=$true; $Json=$true
$script:caller = New-DtJobDirector -Name 'Reopened director' -Identity ([pscustomobject]@{ pid=$PID; pid_start_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); session_id='reopened-session' })
function Get-DtJobLaunchingDirector { $script:caller }
foreach ($mode in @('register-run','status','approve','resume')) {
    $RunFolder = Join-Path $Root $mode
    New-Item -ItemType Directory -Force $RunFolder | Out-Null
    $BuildStatePath = Join-Path $RunFolder '_build-state.md'; $RunId = 'takeover-' + $mode; $PinnedHost='codex'
    [IO.File]::WriteAllText($BuildStatePath, "run_status: runnable`nlast_consumed_event_seq: 0`n")
    $script:DtJobExplicitParams=@()
    Invoke-DtJobRegisterRun | Out-Null
    $saved = Get-DtJobApprovals -RunFolder $RunFolder
    $saved.delegate.pid_start_utc='2000-01-01T00:00:00Z'
    if ($mode -ne 'resume') {
        $saved.awaiting=[pscustomobject]@{ operation='review'; seq=1; delegated_to='Old director' }
        Set-DtJobRunState -BuildStatePath $BuildStatePath -RunStatus 'awaiting_danny'
    }
    Save-DtJobApprovals -RunFolder $RunFolder -Approvals $saved
    $Operation='review'
    switch ($mode) {
        'register-run' { Invoke-DtJobRegisterRun | Out-Null }
        'status' { Invoke-DtJobStatus | Out-Null }
        'approve' { Invoke-DtJobApprove | Out-Null }
        'resume' { Invoke-DtJobResume | Out-Null }
    }
    $after = Get-DtJobApprovals -RunFolder $RunFolder
    Check (Test-DtJobDirectorAlive $after.delegate) "$mode takes over dead process"
    Check (@($after.director_replacements).Count -eq 1 -and $after.director_replacements[0].previous.pid_start_utc -eq '2000-01-01T00:00:00Z' -and $after.director_replacements[0].replacement.session_id -eq 'reopened-session') "$mode persists replacement identities"
    Check (Test-DtJobSameInstant (Get-DtJobRegistryEntry -RunFolder $RunFolder).director.pid_start_utc $script:caller.pid_start_utc) "$mode updates registered identity"
    Check (-not (Test-Path (Join-Path $RunFolder 'notifications.jsonl'))) "$mode sends no DM"
    if ($mode -in @('register-run','status')) { Check ($after.awaiting.delegated_to -eq 'Reopened director') "$mode transfers pending stop" }
    Invoke-DtJobStatus | Out-Null
    Check (@((Get-DtJobApprovals -RunFolder $RunFolder).director_replacements).Count -eq 1) "$mode preserves live director and history"
}
# A different interactive session cannot gain authority via status or re-registration.
$saved = Get-DtJobApprovals -RunFolder $RunFolder
$saved.delegate.pid_start_utc='2000-01-01T00:00:00Z'
Save-DtJobApprovals -RunFolder $RunFolder -Approvals $saved
$originalCaller = $script:caller
$script:caller = New-DtJobDirector -Name 'Unrelated interactive session' -Identity ([pscustomobject]@{pid=$PID;pid_start_utc=$originalCaller.pid_start_utc;session_id='different-session'})
$before = Get-Content -Raw (Join-Path $RunFolder 'approvals.json')
Invoke-DtJobStatus | Out-Null
Invoke-DtJobRegisterRun | Out-Null
Check ((Get-Content -Raw (Join-Path $RunFolder 'approvals.json')) -ceq $before) 'different-id status and registration preserve authority'
$script:caller = $originalCaller
Update-DtJobReopenedDirector -RunFolder $RunFolder
# Cleared environment cannot hide a coordinator or job process tree.
$leasePath = Join-Path $RunFolder 'coordinator.lease'
[IO.File]::WriteAllText($leasePath, ([pscustomobject]@{pid=$PID;pid_start_utc=$originalCaller.pid_start_utc;launched_by='interactive'} | ConvertTo-Json))
Check (Test-DtJobAutomationCaller) 'live coordinator ancestry detected without environment'
$otherFolder = $RunFolder; $RunFolder = Join-Path $Root 'unrelated-run'
Check (Test-DtJobAutomationCaller) 'coordinator cannot register as director of another run'
$RunFolder = $otherFolder
try { Assert-DtJobOperator -VerbName 'director takeover' -RunFolder $RunFolder -AllowLiveCoordinator; Check $false 'coordinator tree refused' } catch { Check ($_ -match 'DT_JOB_OPERATOR_ONLY') 'coordinator tree refused' }
Remove-Item $leasePath
$jobDir = Join-Path $RunFolder 'jobs'; New-Item -ItemType Directory -Force $jobDir | Out-Null
$jobPath = Join-Path $jobDir 'j-automation.json'
[IO.File]::WriteAllText($jobPath, ([pscustomobject]@{job_id='j-automation';runner_pid=$PID;runner_start_utc=$originalCaller.pid_start_utc} | ConvertTo-Json))
Check (Test-DtJobAutomationCaller) 'live job ancestry detected without environment'
$otherFolder = $RunFolder; $RunFolder = Join-Path $Root 'unrelated-run'
Check (Test-DtJobAutomationCaller) 'job cannot register as director of another run'
$RunFolder = $otherFolder
Remove-Item $jobPath
# Explicit names must resolve to their own live registered owner.
$script:DtJobExplicitParams=@('Delegate'); $Delegate='Other session'
$before = Get-Content -Raw (Join-Path $RunFolder 'approvals.json')
foreach ($verb in @('register-run','delegate')) {
    try { if ($verb -eq 'delegate') { Invoke-DtJobDelegate | Out-Null } else { Invoke-DtJobRegisterRun | Out-Null }; Check $false "$verb refuses unresolved delegate" }
    catch { Check ($_ -match 'DT_JOB_DELEGATE_UNRESOLVED') "$verb refuses unresolved delegate clearly" }
}
Check ((Get-Content -Raw (Join-Path $RunFolder 'approvals.json')) -ceq $before) 'refused delegate preserves authority'
$Delegate='Reopened director'
Invoke-DtJobDelegate | Out-Null
Check ((Get-DtJobDirector -RunFolder $RunFolder).pid -eq $PID) 'matching caller name keeps own identity'
$script:caller = New-DtJobDirector -Name 'Different launcher' -Identity ([pscustomobject]@{pid=999999;pid_start_utc='2000-01-01T00:00:00Z'})
Invoke-DtJobDelegate | Out-Null
Check ((Get-DtJobDirector -RunFolder $RunFolder).pid -eq $PID) 'named delegate resolves its own registered identity'
$shape = @((Get-DtJobDirector -RunFolder $RunFolder).PSObject.Properties.Name | Sort-Object) -join ','
Check ($shape -eq 'name,pid,pid_start_utc,session_id,set_utc') 'director record shape is explicit'
$saved = Get-DtJobApprovals -RunFolder $RunFolder
$saved.delegate = New-DtJobDirector -Name 'Dead director' -Identity ([pscustomobject]@{pid=999999;pid_start_utc='2000-01-01T00:00:00Z'})
$saved.awaiting = [pscustomobject]@{operation='review';seq=1;message='Review'}
Save-DtJobApprovals -RunFolder $RunFolder -Approvals $saved
$script:attempts=0; $script:retryRequested=$false
function Send-DtJobRunAlert { param($RunFolder, $Key, $Message, [switch]$RetryUntilDelivered, [switch]$RecordPending); $script:attempts++; $script:retryRequested = $script:retryRequested -or $RetryUntilDelivered; 'failed' }
Invoke-DtJobSchedule -RunFolder $RunFolder
Check ($script:attempts -eq 1 -and -not $script:retryRequested) 'scheduling makes one escalation send attempt'
Invoke-DtJobSchedule -RunFolder $RunFolder
Check ($script:attempts -eq 2) 'next scheduling pass retries undelivered escalation'
[pscustomobject]@{ failures=@($script:failures) } | ConvertTo-Json -Depth 8 -Compress

'@
    $roundTwo = Invoke-TestShell -File $roundTwoScript -Arguments @($dtJob, (New-RunFolder 'director-regressions'))
    Assert-True ($roundTwo.ExitCode -eq 0) ('director regression fixture completes: ' + ($roundTwo.Output -join ' '))
    if ($roundTwo.ExitCode -eq 0) {
        $regressionResult = ($roundTwo.Output -join "`n") | ConvertFrom-Json
        Assert-True (@($regressionResult.failures).Count -eq 0) ('director regressions: ' + ($regressionResult.failures -join '; '))
    }

    # FS-110: launch-time delegation uses the operator verb's record and safety checks.
    # Exercise discovery/registration with a deterministic owning CLI process, while retaining
    # real PID/start-time liveness. Other fixtures explicitly identify themselves as headless.
    $autoRun = New-RunFolder 'automatic-director'
    $autoState = Join-Path $autoRun '_build-state.md'
    Write-Utf8 $autoState "run_status: runnable`nlast_consumed_event_seq: 0`n"
    $autoScript = Join-Path $autoRun 'register.ps1'
    Write-Utf8 $autoScript @'
param($Runtime, $Folder, $State, [switch]$HeadlessFixture)
. $Runtime
$env:DT_BUILD_HEADLESS = $null
$env:CC_SESSION_ID = 'cc-director-fixture'
$env:CODEX_THREAD_ID = 'codex-director-fixture'
$env:CC_SESSION_NAME = 'Director fixture'
$LaunchedBy = 'interactive'
function Get-Process {
    param([int]$Id, $ErrorAction)
    $actual = Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
    if ($Id -ne $PID) { $actual | Add-Member -NotePropertyName ProcessName -NotePropertyValue codex -Force }
    return $actual
}
function Get-DtJobProcessArguments { param([int]$ProcessId); if ($HeadlessFixture) { @('codex', 'exec', '--json') } else { @('codex') } }
$RunFolder = $Folder; $BuildStatePath = $State; $RunId = Split-Path -Leaf $Folder; $PinnedHost = 'codex'
$Json = $true
Invoke-DtJobRegisterRun
'@
    $autoEnv = @{}
    foreach ($key in @('DT_BUILD_HEADLESS', 'CC_SESSION_ID', 'CC_SESSION_NAME')) { $autoEnv[$key] = [Environment]::GetEnvironmentVariable($key) }
    try { $auto = Invoke-TestShell -File $autoScript -Arguments @($dtJob, $autoRun, $autoState) }
    finally { foreach ($key in $autoEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $autoEnv[$key]) } }
    Assert-True ($auto.ExitCode -eq 0) 'interactive registration succeeds without explicit Delegate'
    $autoApproval = Get-Content -Raw (Join-Path $autoRun 'approvals.json') | ConvertFrom-Json
    Assert-True ($autoApproval.delegate.name -ceq 'Director fixture' -and $autoApproval.delegate.session_id -ceq 'codex-director-fixture' -and $autoApproval.delegate.pid -and $autoApproval.delegate.pid_start_utc) 'automatic director records provider identity and owning process identity'
    $autoDirector = $autoApproval.delegate
    $headlessRun = New-RunFolder 'headless-director'
    $headlessState = Join-Path $headlessRun '_build-state.md'
    Write-Utf8 $headlessState "run_status: runnable`nlast_consumed_event_seq: 0`n"
    try { $headless = Invoke-TestShell -File $autoScript -Arguments @($dtJob, $headlessRun, $headlessState, '-HeadlessFixture') }
    finally { foreach ($key in $autoEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $autoEnv[$key]) } }
    $headlessRegistration = ($headless.Output -join "`n") | ConvertFrom-Json
    Assert-True ($headless.ExitCode -eq 0 -and $null -eq $headlessRegistration.director -and -not (Test-Path (Join-Path $headlessRun 'approvals.json'))) 'headless CLI registration ignores inherited session ids and records no director'
    $headlessStop = Invoke-DtJob @('await-danny', '-RunFolder', $headlessRun, '-Operation', 'review', '-Message', 'Review headless work.')
    Assert-True ($headlessStop.alert -eq 'sent') 'headless-only run keeps direct decision alerts'
    # A null legacy delegate recovers the registered director at await time.
    $autoApproval.delegate = $null
    Write-Utf8 (Join-Path $autoRun 'approvals.json') ($autoApproval | ConvertTo-Json -Depth 10)
    $legacy = Invoke-DtJob @('await-danny', '-RunFolder', $autoRun, '-Operation', 'merge', '-Message', 'Merge internal work.')
    Assert-True ($legacy.alert -eq 'delegated') 'legacy null delegate routes to live registered director'
    $leaseRun = New-RunFolder 'legacy-director-lease'
    $leaseState = Join-Path $leaseRun '_build-state.md'
    Write-Utf8 $leaseState "run_status: runnable`nlast_consumed_event_seq: 0`n"
    Invoke-DtJob @('register-run', '-RunFolder', $leaseRun, '-RunId', 'legacy-director-lease', '-BuildStatePath', $leaseState, '-PinnedHost', 'codex', '-LaunchedBy', 'watcher') | Out-Null
    $legacyLease = [ordered]@{ coordinator_id = 'legacy-operator'; launched_by = 'interactive'; host = 'codex'; session_id = 'legacy'; pid = $autoDirector.pid; pid_start_utc = $autoDirector.pid_start_utc; acquired_utc = [DateTime]::UtcNow.ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(10).ToString('o'); ttl_sec = 600; released_utc = $null }
    Write-Utf8 (Join-Path $leaseRun 'coordinator.lease') ($legacyLease | ConvertTo-Json)
    $leaseStop = Invoke-DtJob @('await-danny', '-RunFolder', $leaseRun, '-Operation', 'merge', '-Message', 'Legacy operator decision.')
    Assert-True ($leaseStop.alert -eq 'delegated') 'legacy interactive lease recovers its live operator without an explicit delegate'
    Remove-Item (Join-Path $leaseRun 'coordinator.lease') # End the synthetic coordinator identity before later operator fixtures.
    # Legacy pending DMs must not bypass a director that has since registered.
    $legacyPending = Join-Path $autoRun 'notifications.jsonl'
    Write-Utf8 $legacyPending '{"key":"dt-build:automatic-director:awaiting:merge:1","status":"pending","message":"To approve, run: obsolete command"}'
    $pendingProbe = Invoke-TestShell -Command (". '" + $dtJob.Replace("'", "''") + "'; @(Send-DtJobPendingAlerts -RunFolder '" + $autoRun.Replace("'", "''") + "').Count")
    Assert-True (($pendingProbe.Output -join '').Trim() -eq '0') 'legacy pending boundary DMs are rerouted rather than replayed'
    Assert-True ([IO.Path]::GetFullPath($env:DT_BUILD_STATE_DIR).StartsWith([IO.Path]::GetFullPath($tempRoot), [StringComparison]::OrdinalIgnoreCase)) 'delegate fixtures register in the suite temp registry, never the real one'
    $rf = New-RunFolder 'launch-delegate'
    $state = Join-Path $rf '_build-state.md'
    Write-Utf8 $state "run_status: runnable`nlast_consumed_event_seq: 0`n"
    $registerDelegate = @('register-run', '-RunFolder', $rf, '-RunId', 'launch-delegate', '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed')
    # Seed a distinct live registration, as a named delegate must already be registered.
    $registryPath = Join-Path $env:DT_BUILD_STATE_DIR 'active-runs.json'
    $registryData = Get-Content -Raw $registryPath | ConvertFrom-Json
    $registryData.runs += [pscustomobject]@{run_id='named-live';run_folder=(Join-Path $tempRoot 'named-live');director=[pscustomobject]@{name='launch-session';pid=$PID;pid_start_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}}
    Write-Utf8 $registryPath ($registryData | ConvertTo-Json -Depth 20)
    Invoke-DtJob ($registerDelegate + @('-Delegate', '  launch-session  ')) | Out-Null
    $delegated = Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json
    Assert-True ($delegated.delegate.name -ceq 'launch-session' -and $delegated.delegate.set_utc) 'register-run stores the trimmed delegate'
    Write-Utf8 (Join-Path $rf 'approvals.json') ($delegated | ConvertTo-Json -Depth 10)
    $savedDelegate = $delegated.delegate | ConvertTo-Json -Compress
    Invoke-DtJob $registerDelegate | Out-Null
    Assert-True (((Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).delegate | ConvertTo-Json -Compress) -ceq $savedDelegate) 'registration without Delegate preserves existing delegation'
    $routine = Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'attempt-budget', '-Message', 'Retry fixture attempt.')
    $pending = (Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).awaiting
    Assert-True ($routine.alert -eq 'delegated' -and $pending.delegated_to -ceq 'launch-session' -and -not (Test-Path (Join-Path $rf 'notifications.jsonl'))) 'live director receives stops without a Danny alert'
    # FS-120: watches see the recorded owner, decision and delivery for the current stop.
    $routineStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($routineStatus.run_status -eq 'awaiting_danny' -and $routineStatus.awaiting.awaiting_owner -ceq 'director' -and $routineStatus.awaiting.delegated_to -ceq 'launch-session') 'routine stop status names the director owner'
    Assert-True ($routineStatus.awaiting.operation -ceq $pending.operation -and $routineStatus.awaiting.since_utc -eq $pending.since_utc -and $routineStatus.awaiting.message -ceq $pending.message -and $routineStatus.awaiting.alerted_danny -eq $false) 'routine status retains stop details and reports no delivered Danny alert'
    $urgent = Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'irreversible-fixture', '-Message', 'Fixture only.')
    $pending = (Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).awaiting
    Assert-True ($urgent.alert -eq 'delegated' -and -not (Test-Path (Join-Path $rf 'notifications.jsonl'))) 'irreversible wording stays with live director'
    $urgentStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($urgentStatus.awaiting.awaiting_owner -ceq 'director' -and -not $urgentStatus.awaiting.alerted_danny) 'irreversible stop status names director'
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'production', '-Message', 'deploy to production; irreversible', '-AlwaysNotify') | Out-Null
    Assert-True ((Invoke-DtJob @('status', '-RunFolder', $rf)).awaiting.awaiting_owner -ceq 'director') 'AlwaysNotify and production wording route to live director'
    $dead = Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json
    $dead.delegate.pid_start_utc = [DateTime]::UtcNow.AddYears(-1).ToString('o')
    Write-Utf8 (Join-Path $rf 'approvals.json') ($dead | ConvertTo-Json -Depth 10)
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    $pending = $dead.awaiting
    $notifications = @(Get-Content (Join-Path $rf 'notifications.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($notifications | Where-Object status -eq 'delivered').Count -eq 1) 'director PID reuse escalates once on repeated status passes'
    $dm = Get-Content -Raw $env:DT_TEST_DM_LOG
    Assert-True ($dm -match 'director session has closed' -and $dm -match 'Command Center' -and $dm -notmatch 'To approve, run:') 'dead director alert explains where to answer without commands'
    # Delivery must match this boundary's sequence; another stop's DM or a pending row is insufficient.
    $notificationPath = Join-Path $rf 'notifications.jsonl'
    $deliveredLog = Get-Content -Raw $notificationPath
    $currentKey = "dt-build:launch-delegate:awaiting:production:$($pending.seq)"
    Write-Utf8 $notificationPath (([ordered]@{ key = $currentKey; status = 'pending' } | ConvertTo-Json -Compress) + "`n" + ([ordered]@{ key = "${currentKey}-old"; status = 'delivered' } | ConvertTo-Json -Compress))
    # Keep the director live while inspecting an undelivered record (status retries absent-director alerts).
    $dead.delegate.pid_start_utc = $delegated.delegate.pid_start_utc
    Write-Utf8 (Join-Path $rf 'approvals.json') ($dead | ConvertTo-Json -Depth 10)
    $pendingStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($pendingStatus.awaiting.awaiting_owner -ceq 'director' -and $pendingStatus.awaiting.alerted_danny -eq $false) 'pending delivery and another boundary delivery do not count as alerting Danny'
    Write-Utf8 $notificationPath $deliveredLog
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'manual-review', '-Message', 'Decide whether to retry.', '-AlwaysNotify') | Out-Null
    $forcedStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($forcedStatus.awaiting.awaiting_owner -ceq 'director' -and $forcedStatus.awaiting.alerted_danny -eq $false) 'AlwaysNotify routes to the director'
    foreach ($invalid in @('blank', 'coordinator', 'job')) {
        $name = if ($invalid -eq 'blank') { '   ' } else { 'forbidden-session' }
        if ($invalid -eq 'coordinator') { $env:DT_BUILD_COORDINATOR_ID = 'fixture' }
        if ($invalid -eq 'job') { $env:DT_JOB_ID = 'fixture' }
        try {
            $raw = Invoke-TestPwsh -Script $dtJob @registerDelegate -Delegate $name -AllowTempRunFolder -Json 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_(USAGE|OPERATOR_ONLY)') "register-run rejects $invalid delegate assignment"
        } finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue }
    }
    Assert-True (((Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).delegate | ConvertTo-Json -Compress) -ceq $savedDelegate) 'rejected delegate assignments leave the original record unchanged'

    # FS-57: external approval queues only an exact boundary, survives repeats,
    # and applies after the recorded coordinator identity exits (including PID reuse).
    $rf = New-RunFolder 'approval-queue'
    $state = Join-Path $rf '_build-state.md'
    Write-Utf8 $state "run_status: awaiting_danny`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n"
    Invoke-DtJob @('register-run', '-RunFolder', $rf, '-RunId', 'approval-queue', '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed') | Out-Null
    $pendingPath = Join-Path $rf 'approvals.json'
    $queuePath = Join-Path $rf 'approval-queued.json'
    Write-Utf8 $pendingPath '{"awaiting":{"operation":"fixture-review","seq":1},"approvals":[],"delegate":null}'
    $closingRelease = Join-Path $rf 'closing-release'
    $closingScript = Join-Path $rf 'closing.ps1'
    Write-Utf8 $closingScript (New-HeldJobCommand $closingRelease)
    $closing = Start-Process pwsh -ArgumentList @('-NoProfile','-File', $closingScript) @HiddenWindow -PassThru
    $lease = [ordered]@{ coordinator_id = 'closing-fixture'; launched_by = 'watcher'; pid = $closing.Id; pid_start_utc = $closing.StartTime.ToUniversalTime().ToString('o'); released_utc = $null }
    Write-Utf8 (Join-Path $rf 'coordinator.lease') ($lease | ConvertTo-Json)
    foreach ($refusal in @('wrong-operation','coordinator','job','wrong-state')) {
        $op = 'fixture-review'
        if ($refusal -eq 'wrong-operation') { $op = 'different' }
        if ($refusal -eq 'coordinator') { $env:DT_BUILD_COORDINATOR_ID = 'closing-fixture' }
        if ($refusal -eq 'job') { $env:DT_JOB_ID = 'fixture-job' }
        if ($refusal -eq 'wrong-state') { Write-Utf8 $state "run_status: runnable`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n" }
        try {
            $raw = Invoke-TestPwsh -Script $dtJob approve -RunFolder $rf -Operation $op -Json 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $queuePath)) "$refusal preserves refusal without queuing"
        } finally {
            Remove-Item Env:DT_BUILD_COORDINATOR_ID,Env:DT_JOB_ID -ErrorAction SilentlyContinue
            Write-Utf8 $state "run_status: awaiting_danny`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n"
        }
    }
    $queued = Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review')
    Assert-True ($queued.approval_queued -eq 'fixture-review' -and $queued.message -eq "approval queued; applies when coordinator $($closing.Id) exits") 'external operator queues while closing out'
    $firstReceipt = Get-Content -LiteralPath $queuePath -Raw
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $queuePath -Raw) -ceq $firstReceipt) 'repeated queued approve preserves original who what when identity'
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 0) 'live identity does not apply queued approval'
    Write-Utf8 $closingRelease 'release'
    $closing.WaitForExit()
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    $applied = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
    Assert-True ($applied.approvals.Count -eq 1 -and $applied.approvals[0].status -eq 'applied' -and $null -eq $applied.awaiting -and (Get-Content -LiteralPath $state -Raw) -match 'run_status: runnable') 'next invocation applies durable applied receipt when original process identity exits'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 1) 'applied approval repeats without duplication'

    # Immediate approvals have no queue file; repeat the latest exact approval.
    Remove-Item -LiteralPath $queuePath
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'immediate-review', '-Message', 'fixture only') | Out-Null
    # FS-94: a continuation_requested event after the stop must not hide it; status reads run_status.
    Invoke-DtJob @('request-continuation', '-RunFolder', $rf, '-Reason', 'fixture rotation') | Out-Null
    $stopped = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($stopped.run_status -eq 'awaiting_danny' -and $stopped.awaiting.operation -ceq 'immediate-review' -and [int64]$stopped.awaiting.seq -gt 0) 'run status reports awaiting_danny and the pending stop after a later continuation event'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review', '-Reason', '  Danny chose option A.  ') | Out-Null
    $reasonRecord = @((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals)[-1]
    Assert-True ($reasonRecord.operation -ceq 'immediate-review' -and $reasonRecord.reason -ceq 'Danny chose option A.') 'FS-124: approve stores the trimmed -Reason on the approval record'
    $resumed = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($resumed.run_status -eq 'runnable' -and $null -eq $resumed.awaiting) 'run status clears the pending stop after approval'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 2) 'immediate approve twice records only one new approval without a queue'
    # FS-95: a later approval write keeps earlier timestamp text byte-for-byte (no trailing-zero trim).
    $zeroStamp = '2026-10-15T16:14:05.5441830Z'
    $approvalText = [regex]::Replace((Get-Content -LiteralPath $pendingPath -Raw), '"approved_utc":\s*"[^"]+"', ('"approved_utc": "' + $zeroStamp + '"'), 1)
    Write-Utf8 $pendingPath $approvalText
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'timestamp-text', '-Message', 'fixture only') | Out-Null
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'timestamp-text') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw).Contains('"' + $zeroStamp + '"')) 'approval rewrites preserve stored timestamp text exactly'
    $wrongRepeat = Invoke-TestPwsh -Script $dtJob approve -RunFolder $rf -Operation fixture-review -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($wrongRepeat -join ' ') -match 'DT_JOB_NOT_AWAITING') 'older operation is not accepted as a repeated latest approval'

    # FS-58: exercise the real unwrapped runner with a PS pytest stand-in,
    # then inspect the opt-in runner argv without starting Python.
    $rf = New-RunFolder 'exclusive-reason'
    $direct = Invoke-DtJob @('start','-RunFolder',$rf,'-Kind','test','-Command', "function pytest { 'pytest direct fixture' }; pytest")
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $direct.job_id).status -eq 'succeeded') 'pytest job without exclusive_reason runs directly'
    Assert-True ((Get-Content -Raw (Join-Path $rf "jobs/$($direct.job_id)/stdout.log")) -match 'pytest direct fixture') 'unwrapped pytest stand-in actually executed'
    $held = Invoke-DtJob @('start','-RunFolder',$rf,'-Command',(New-HeldJobCommand (Join-Path $rf 'release')),'-Mutates','exclusive-fixture')
    $reason = "fixture suite: simultaneous shared-device writes (fixture evidence); separate paths failed"
    $wrapped = Invoke-DtJob @('start','-RunFolder',$rf,'-Kind','test','-Command','pytest fixture-selection','-ExclusiveReason',$reason,'-Mutates','exclusive-fixture')
    $record = Get-JobRecord -RunFolder $rf -JobId $wrapped.job_id
    $jobDir = Join-Path $rf "jobs/$($wrapped.job_id)"
    $spec = Get-Content -Raw (Join-Path $jobDir 'spec.json') | ConvertFrom-Json
    Assert-True ($wrapped.status -eq 'queued' -and $wrapped.exclusive_reason -ceq $reason -and $record.exclusive_reason -ceq $reason -and $spec.exclusive_reason -ceq $reason) 'opt-in reason retained exactly in spec, job record and start receipt'
    $status = Invoke-DtJob @('status','-RunFolder',$rf,'-JobId',$wrapped.job_id)
    Assert-True ($status.exclusive_reason -ceq $reason) 'job status receipt retains the reason'
    $runner = Get-Content -Raw (Join-Path $scriptDir 'dt-job-runner.ps1')
    $wrapping = [regex]::Match($runner, '(?s)    # Only a caller-documented suite.*?(?=    # Recheck under the lock)').Value
    Assert-True ([bool]$wrapping) 'runner opt-in argv block found'
    # Substitute only executable discovery; construction uses product code.
    $wrapping = $wrapping.Replace('(Get-Command python, python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source', "'fixture-python-never-launched'")
    $DtJobRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir))
    foreach ($value in @($null, '', '   ', $reason)) {
        $spec = [pscustomobject]@{ command = 'pytest fixture-selection'; exclusive_reason = $value }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        foreach ($arg in @('-NoProfile','-Command','pytest fixture-selection')) { $psi.ArgumentList.Add($arg) }
        & ([scriptblock]::Create($wrapping))
        if ($value -eq $reason) {
            Assert-True ($psi.FileName -eq 'fixture-python-never-launched' -and $psi.ArgumentList[0].EndsWith('pytest-lock.py') -and $psi.ArgumentList[1] -eq '--reason' -and $psi.ArgumentList[2] -ceq $reason -and $psi.ArgumentList[5] -eq '--' -and $psi.ArgumentList[6] -eq 'pwsh' -and $psi.ArgumentList[9] -eq 'pytest fixture-selection') 'documented pytest job is wrapped with exact original argv and reason'
        } else {
            Assert-True ($psi.FileName -eq 'pwsh' -and $psi.ArgumentList.Count -eq 3) 'null empty and whitespace reason do not wrap pytest'
        }
    }
    Invoke-DtJob @('cancel','-RunFolder',$rf,'-JobId',$wrapped.job_id) | Out-Null
    Invoke-DtJob @('cancel','-RunFolder',$rf,'-JobId',$held.job_id) | Out-Null

    }
    if ($script:failed -gt 0) { $exitCode = 1 } else { Write-Output 'PASS: dt-job suite' }
}
catch {
    $script:failed++
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    [Environment]::SetEnvironmentVariable('DT_MODEL_ROUTER_STATE', $savedRouterState)
    [Environment]::SetEnvironmentVariable('DT_MODEL_ROUTER_ALERT_TRANSPORT', $savedAlertTransport)
    [Environment]::SetEnvironmentVariable('DT_TEST_DM_LOG', $savedDmLog)
    foreach ($name in $pinEnvNames) { [Environment]::SetEnvironmentVariable($name, $pinSavedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed, $script:failed failed"
    # Unlink only: a recursive delete would follow the junction into the real skill folder.
    if ($junctionLink -and [IO.Directory]::Exists($junctionLink)) { [IO.Directory]::Delete($junctionLink) }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
