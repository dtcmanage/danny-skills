# Dot-source this file, then call Invoke-CodexProcess.
# Runs the current Codex CLI with redirected UTF-8 stdio and an enforced timeout.

Set-StrictMode -Version Latest

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
        return [pscustomobject]@{ file = $pwsh; prefix_args = @('-NoProfile', '-File', $resolved) }
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

        [pscustomobject]@{
            exit_code = if ($timedOut) { -1 } else { $process.ExitCode }
            timed_out = $timedOut
            duration_ms = $durationMs
            stdout = $stdout
            stderr = $stderr
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
