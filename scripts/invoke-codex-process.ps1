# Dot-source this file, then call Invoke-CodexProcess.
# Runs the current Codex CLI with redirected UTF-8 stdio and an enforced timeout.

Set-StrictMode -Version Latest

function Get-CodexCapacitySignal {
    param([AllowEmptyString()][string]$ErrorText)
    # Non-JSON exec sends errors to stderr (stdout is model text). Inspect the
    # diagnostic lines so a quoted prompt or progress message cannot trigger retries.
    $lines = @($ErrorText -split '\r?\n' | Where-Object { $_.Trim() })
    if (-not $lines.Count) { return $null }
    $pattern = '(?i)\b(?:selected\s+)?model\s+(?:is\s+)?(?:currently\s+|temporarily\s+)?(?:at\s+capacity|overloaded)\b|\b(?:server|service|system|provider)\s+(?:is\s+)?(?:currently\s+|temporarily\s+)?(?:overloaded|at\s+capacity)\b|\b(?:overloaded_error|model_overloaded|server_overloaded|over_capacity)\b|\b(?:overload(?:ed)?|at[\s-]+capacity|over[\s-]+capacity)\b'
    foreach ($line in $lines) {
        # Usage/quota refusals retain their existing path, even with overload wording.
        if ($line -match '(?i)quota|usage[ _-]*limit|rate[ _-]*limit|insufficient_quota') { continue }
        if ($line -notmatch '(?i)^\s*(?:error\s*:|(?:(?:selected|the)\s+)?(?:model|server|service|system|provider)\b|\{.*"(?:type|error)"\s*:)') { continue }
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) { return $match.Value }
    }
    return $null
}

function Get-CodexReadOnlySandboxArguments {
    param([bool]$OnWindows = ($env:OS -eq 'Windows_NT'))
    # --ignore-user-config also removes the Windows implementation selection.
    # Select MXC explicitly (verified with CLI 0.162.1); unsupported hosts fail closed. Do not
    # fall back to full access, workspace-write, or the weaker unelevated sandbox.
    $result = @('--sandbox', 'read-only', '-c', 'web_search="disabled"')
    if ($OnWindows) { $result += @('-c', 'windows.sandbox="mxc"') }
    return $result
}

function Get-CodexBlockedReportDetail {
    param([AllowEmptyString()][string]$Text)
    # Inspect the final report only, never echoed prompts or successful tool
    # probes in the stream. A denied write in a successful review is expected.
    $hasVerdict = $Text -match '(?m)^VERDICT:'
    $blocked = if ($hasVerdict) {
        $Text -match '(?m)^VERDICT:[^\S\r\n]*(?:\r?\n[^\S\r\n]*)?BLOCKED\b'
    } else { $Text -match '(?im)^\s*BLOCKED\b' }
    $legacyBlocker = [regex]::Match($Text, '(?ims)^UNRESOLVED_BLOCKERS:[^\S\r\n]*\r?\n(.*?)(?=^[A-Z_]+:|\z)')
    $evidence = if ($blocked) { $Text } elseif (-not $hasVerdict -and $legacyBlocker.Success) { $legacyBlocker.Groups[1].Value } else { '' }
    # Report headers, the verdict word and CHANGED_FILES paths are not denial evidence: a chunk id
    # like '...-environment-recovery' above 'VERDICT: BLOCKED' once mislabeled a content blocker (2026-10-14).
    $evidence = [regex]::Replace($evidence, '(?im)^(?:DT_BUILD_REPORT_VERSION|RUN_ID|chunk_id|attempt):[^\r\n]*$', '')
    $evidence = [regex]::Replace($evidence, '(?im)^VERDICT:[^\S\r\n]*(?:\r?\n[^\S\r\n]*)?BLOCKED\b[^\r\n]*$', '')
    $evidence = [regex]::Replace($evidence, '(?ims)^CHANGED_FILES:[^\r\n]*\r?\n.*?(?=^[A-Z_]+:|\z)', '')
    # Whole words on one line only; path and identifier fragments (environment-recovery, BLOCKED.json) never count.
    $w = '(?<![-\w\\/.])'; $e = '(?![-\w\\/.])'
    if ($evidence -match "(?im)(?:CreateProcess[^\r\n]{0,500}(?:blocked by policy|rejected|denied)|$w(?:command|process|shell|file.read|Get-Content|Get-FileHash)$e[^\r\n]{0,200}(?:blocked by policy|before process launch))") {
        return 'sandbox_process_blocked'
    }
    if ($evidence -match "(?im)$w(?:sandbox|tool|permission|environment)$e[^\r\n]{0,200}$w(?:denied|blocked|unavailable|not supported)$e|$w(?:denied|blocked)$e[^\r\n]{0,200}$w(?:sandbox|tool|permission|environment)$e") {
        return 'sandbox_tool_denied'
    }
    return $null
}

function Get-Utf8PowerShellArguments {
    param([Parameter(Mandatory)][string]$ScriptPath)
    # The child PS1 shim must share the parent's UTF-8 pipe contract. Keep paths
    # and CLI arguments as argv entries; never interpolate them into shell code.
    # Preserve a failed native command's exit code even when a shim omits exit.
    $bootstrap = '$__dtUtf8Encoding=[Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$__dtUtf8Encoding;[Console]::OutputEncoding=$__dtUtf8Encoding;$OutputEncoding=$__dtUtf8Encoding;$__dtUtf8Path=$args[0];$__dtUtf8Args=@($args | Select-Object -Skip 1);$LASTEXITCODE=0;try { & $__dtUtf8Path @__dtUtf8Args } catch { throw };exit $LASTEXITCODE'
    return @('-NoProfile','-CommandWithArgs',$bootstrap,$ScriptPath)
}

function Get-CodexProcessSpec {
    param(
        [Parameter(Mandatory)]
        [string]$CodexPath
    )

    $resolved = (Resolve-Path -LiteralPath $CodexPath).Path
    $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()

    if ($extension -eq '.cmd') {
        $shimDir = Split-Path -Parent $resolved
        $node = Join-Path $shimDir 'node.exe'
        if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
            $nodeCommand = Get-Command node.exe, node -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $nodeCommand) { throw "Node.js is required by Codex shim: $resolved" }
            $node = $nodeCommand.Source
        }
        $entry = Join-Path $shimDir 'node_modules\@openai\codex\bin\codex.js'
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
            throw "Codex npm entrypoint not found beside shim: $entry"
        }
        return [pscustomobject]@{ file = $node; prefix_args = @($entry) }
    }

    if ($extension -eq '.ps1') {
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        return [pscustomobject]@{ file = $pwsh; prefix_args = @(Get-Utf8PowerShellArguments -ScriptPath $resolved) }
    }

    return [pscustomobject]@{ file = $resolved; prefix_args = @() }
}

function Stop-CodexProcessBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [AllowEmptyCollection()]
        [System.Threading.Tasks.Task[]]$OutputTasks = @(),

        [ValidateRange(1, 5000)]
        [int]$GraceMs = 1000
    )

    $cleanupWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $Process.HasExited) {
            try { $Process.Kill($true) } catch { }
            [void]$Process.WaitForExit($GraceMs)
        }
    }
    catch { }

    $remainingMs = [Math]::Max(0, $GraceMs - [int]$cleanupWatch.ElapsedMilliseconds)
    $pending = @($OutputTasks | Where-Object { $null -ne $_ -and -not $_.IsCompleted })
    if ($remainingMs -gt 0 -and $pending.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll($pending, $remainingMs) }
        catch [System.AggregateException] { }
    }
    try { $Process.StandardInput.Close() } catch { }
}

function Invoke-CodexProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CodexPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [ValidateRange(1000, 3600000)]
        [int]$TimeoutMs
    )

    $spec = Get-CodexProcessSpec -CodexPath $CodexPath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $spec.file
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8

    foreach ($arg in @($spec.prefix_args) + @($Arguments)) {
        [void]$psi.ArgumentList.Add([string]$arg)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $started = [DateTimeOffset]::UtcNow
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $stdoutTask = $null
    $stderrTask = $null
    $stdinTask = $null
    $stdinFlushTask = $null
    $timedOut = $false
    $startedProcess = $false

    function Get-DeadlineRemainder {
        return [Math]::Max(0, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
    }

    function Wait-TaskBounded([System.Threading.Tasks.Task]$Task, [int]$Milliseconds) {
        if ($Milliseconds -le 0) { return $false }
        try {
            return $Task.Wait($Milliseconds)
        }
        catch [System.AggregateException] {
            # A completed faulted task still completed within the deadline. Its
            # exception is surfaced by the caller after inspecting IsFaulted.
            return $true
        }
    }

    function Get-CompletedStringTask([object]$Task) {
        if ($null -ne $Task -and $Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            return [string]$Task.GetAwaiter().GetResult()
        }
        return ''
    }

    try {
        if (-not $process.Start()) {
            throw "Failed to start Codex process: $($psi.FileName)"
        }
        $startedProcess = $true

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdinTask = $process.StandardInput.WriteAsync($Prompt)
        $stdinCompleted = Wait-TaskBounded -Task $stdinTask -Milliseconds (Get-DeadlineRemainder)
        if ($stdinCompleted) {
            if ($stdinTask.IsFaulted) {
                throw "Writing the Codex prompt to stdin failed: $($stdinTask.Exception.GetBaseException().Message)"
            }
            $stdinFlushTask = $process.StandardInput.FlushAsync()
            $stdinCompleted = Wait-TaskBounded -Task $stdinFlushTask -Milliseconds (Get-DeadlineRemainder)
            if ($stdinCompleted -and $stdinFlushTask.IsFaulted) {
                throw "Flushing the Codex prompt to stdin failed: $($stdinFlushTask.Exception.GetBaseException().Message)"
            }
            if ($stdinCompleted) {
                $process.StandardInput.Close()
            }
        }

        $remainingMs = Get-DeadlineRemainder
        $timedOut = (-not $stdinCompleted) -or $remainingMs -le 0 -or (-not $process.WaitForExit($remainingMs))
        if (-not $timedOut) {
            $outputTasks = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask))
            $outputCompleted = Wait-TaskBounded -Task $outputTasks -Milliseconds (Get-DeadlineRemainder)
            $timedOut = -not $outputCompleted
            if ($outputCompleted -and $outputTasks.IsFaulted) {
                throw "Reading Codex process output failed: $($outputTasks.Exception.GetBaseException().Message)"
            }
        }

        if ($timedOut) {
            # Cleanup has its own small, fixed ceiling. Never convert a failed
            # process-tree kill into an unbounded WaitForExit/output drain.
            Stop-CodexProcessBounded -Process $process -OutputTasks @($stdoutTask, $stderrTask) -GraceMs 1000
        }

        $stdout = Get-CompletedStringTask -Task $stdoutTask
        $stderr = Get-CompletedStringTask -Task $stderrTask
        $durationMs = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
        $capacitySignal = if (-not $timedOut -and $process.ExitCode -ne 0) { Get-CodexCapacitySignal -ErrorText $stderr } else { $null }

        [pscustomobject]@{
            exit_code = if ($timedOut) { -1 } else { $process.ExitCode }
            timed_out = $timedOut
            duration_ms = $durationMs
            stdout = $stdout
            stderr = $stderr
            failure_category = if ($capacitySignal) { 'capacity' } else { $null }
            failure_detail = $capacitySignal
        }
    }
    finally {
        # Faulted stdin/output tasks can throw before the normal timeout branch.
        # Never leave a started Codex process running on an exceptional exit.
        if ($startedProcess -and -not $process.HasExited) {
            Stop-CodexProcessBounded -Process $process -OutputTasks @($stdoutTask, $stderrTask) -GraceMs 1000
        }
        $process.Dispose()
    }
}

function Remove-CodexTempDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedLeafPrefix
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\', '/')
    $tempPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolved
    if (-not $resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith($ExpectedLeafPrefix, [System.StringComparison]::Ordinal)) {
        throw "Refusing unsafe Codex temp cleanup target: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
