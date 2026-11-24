# Search tracked and nonignored untracked text from the repo root. The caller
# supplies the milestone's pre-build commit, never a merge base with main.
# History defaults exclude CHANGELOG*, history/, _history/, _archive/, design/,
# designs/, plans/, _planning/, design-*.md and plan-*.md. ExcludePaths adds
# repo-relative git pathspecs; active docs outside these paths remain consumers.
function Test-MovedPathConsumers {
    param([string]$WorkingTree, [string]$BaseRef, [string[]]$ExcludePaths = @())
    $inside = & git -C $WorkingTree rev-parse --is-inside-work-tree 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (($inside -join ' ') -match 'not a git repository') { return @() }
        throw "MOVED_PATH_REPO_FAILED: $inside"
    } # Non-git artifact callers remain supported; other errors fail closed.
    if (-not $BaseRef) { throw 'MOVED_PATH_BASE_REQUIRED: supply -BaseRef or builder provenance start_commit' }
    $repo = & git -C $WorkingTree rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0) { throw 'MOVED_PATH_ROOT_FAILED' }
    $base = & git -C $repo rev-parse --verify "${BaseRef}^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "MOVED_PATH_BASE_UNRESOLVED: $BaseRef" }
    $diff = & git -C $repo diff --find-renames --diff-filter=RD --name-status -z $base --
    if ($LASTEXITCODE -ne 0) { throw 'MOVED_PATH_DIFF_FAILED' }
    $fields = ($diff -join "`n") -split "`0"
    $moves = @()
    for ($i = 0; $i -lt $fields.Count -and $fields[$i];) {
        $status = $fields[$i++]
        $old = $fields[$i++]
        $destination = if ($status.StartsWith('R')) { $fields[$i++] } else { $null }
        $moves += [pscustomobject]@{ Old=$old; Destination=$destination }
    }
    if (-not $moves.Count) { return @() }
    $paths = @(':(top)**')
    foreach ($pattern in @('**/CHANGELOG*','**/history/**','**/_history/**','**/_archive/**','**/design/**','**/designs/**','**/plans/**','**/_planning/**','**/design-*.md','**/plan-*.md') + $ExcludePaths) {
        $paths += ":(top,exclude,glob)$pattern"
    }
    $patterns = @($moves | ForEach-Object { foreach ($variant in @($_.Old, $_.Old.Replace('/', '\'), $_.Old.Replace('/', '\\')) | Select-Object -Unique) { '-e'; $variant } })
    # Read the native stream intact: PowerShell's line enumeration would split
    # filenames containing newlines. git grep -z separates filename and line by NUL.
    $info = [Diagnostics.ProcessStartInfo]::new('git')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('-C', $repo, 'grep', '--untracked', '-z', '-n', '-I', '-F') + $patterns + @('--') + $paths) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $hits = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -gt 1) { throw "MOVED_PATH_GREP_FAILED: $($stderr.GetAwaiter().GetResult())" }
    } finally { $process.Dispose() }
    $records = [regex]::Matches($hits, '([^\x00]+)\x00(\d+)\x00([^\n]*)\n')
    foreach ($move in $moves) {
        $old = $move.Old
        $variants = @($old, $old.Replace('/', '\'), $old.Replace('/', '\\')) | Select-Object -Unique
        $token = '(?<![\p{L}\p{N}_./\\-])(?:\.[/\\])?(?:' + (($variants | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?:(?![\p{L}\p{N}_./\\-])|(?=\.(?:\s|$)))'
        foreach ($hit in $records) {
            $file = $hit.Groups[1].Value
            $line = $hit.Groups[2].Value
            $content = $hit.Groups[3].Value
            if ($file -cne $old -and $file -cne $move.Destination -and $content -cmatch $token) { "stale moved/deleted path '$old': ${file}:${line}:$content" }
        }
    }
}
