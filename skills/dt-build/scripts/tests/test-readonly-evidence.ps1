# Unit regressions for read-only worker evidence. Pure parsing: no processes,
# registries, runtime lease or model calls. Real-wrapper cases live in the
# build regression suite (shard 1).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptDir 'readonly-worker-evidence.ps1')
. (Join-Path $scriptDir 'worker-standing-rules.ps1')
. (Join-Path $scriptDir '../../../scripts/invoke-codex-process.ps1')
$script:passed = 0; $script:failed = 0
function Check([bool]$Ok, [string]$Message) { if ($Ok) { $script:passed++ } else { $script:failed++; [Console]::WriteLine("FAIL: $Message") } }

function Join-PosixArgv([string[]]$Argv, [switch]$Alternate) {
    # The CLI reports argv as one POSIX-quoted string; cover both common quoting styles.
    (@($Argv | ForEach-Object {
        if ($_ -match '^[A-Za-z0-9_@%+=:,./-]+$') { $_ }
        elseif ($Alternate) { "'" + $_.Replace("'", "'\''") + "'" }
        else { "'" + $_.Replace("'", "'""'""'") + "'" }
    })) -join ' '
}
function New-Frames([object[]]$Commands, [object[]]$Before = @(), [object[]]$After = @(), [switch]$NoTerminal) {
    $frames = [Collections.Generic.List[string]]::new()
    $frames.Add('{"type":"thread.started","thread_id":"01a21f9e-db52-7300-a7cc-eed18f081873"}')
    $frames.Add('{"type":"turn.started"}')
    foreach ($frame in $Before) { $frames.Add($frame) }
    $n = 0
    foreach ($c in $Commands) {
        $id = "item_$n"; $n++
        $frames.Add((@{type='item.started';item=@{id=$id;type='command_execution';command=$c.command;aggregated_output='';exit_code=$null;status='in_progress'}} | ConvertTo-Json -Depth 8 -Compress))
        $status = if ($c.Contains('status')) { $c.status } else { 'completed' }
        $exit = if ($c.Contains('exit')) { $c.exit } else { 0 }
        $output = if ($c.Contains('output')) { $c.output } else { '' }
        $frames.Add((@{type='item.completed';item=@{id=$id;type='command_execution';command=$c.command;aggregated_output=$output;exit_code=$exit;status=$status}} | ConvertTo-Json -Depth 8 -Compress))
    }
    foreach ($frame in $After) { $frames.Add($frame) }
    if (-not $NoTerminal) { $frames.Add('{"type":"turn.completed","usage":{"input_tokens":73170,"cached_input_tokens":43392,"output_tokens":260,"reasoning_output_tokens":0}}') }
    $frames -join "`n"
}
function Effect([string]$Command) { Get-ReadOnlyCommandEffect $Command }

# 1. Every command from the real rejected read-only rollout, in both quoting styles.
$fixture = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/readonly-incident-commands.json') | ConvertFrom-Json
Check ($fixture.commands.Count -eq 49) 'incident fixture keeps all 49 real commands'
$incident = foreach ($row in $fixture.commands) {
    foreach ($form in @((Join-PosixArgv $row.argv), (Join-PosixArgv $row.argv -Alternate))) {
        $p = Get-ReadOnlyCommandProfile $form
        # The venv probe runs `python -c` code with no write API: opaque, still accepted.
        $expected = if ($form -match 'build-test-venv/bin/python -c') { 'opaque' } else { 'read' }
        Check ($p.effect -eq $expected) "real incident command is $($expected): $form ($($p.effect))"
    }
    @{ command = (Join-PosixArgv $row.argv); exit = [int]$row.exit_code; status = $row.status; output = $row.aggregated_output }
}
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames $incident)
Check ($receipt.complete -and $receipt.writes.Count -eq 0 -and $receipt.opaque_commands.Count -eq 1) "the real incident stream is complete with no attributed writes ($($receipt.writes -join '; '))"
$validators = @($fixture.commands | Select-Object -Skip 40 -First 4 | ForEach-Object { Get-ReadOnlyCommandProfile (Join-PosixArgv $_.argv) })
Check (@($validators | Where-Object { $_.effect -eq 'read' -and -not $_.printer }).Count -eq 4) 'link-format test, gate -List, versioning -Json and plugin -ValidateOnly are bound read-only contracts'

# 2. Every git read the read-only worker rule requires, plus other observed reads.
$rule = Get-WorkerEnvironmentRule -ReadOnly
foreach ($required in @('git symbolic-ref refs/remotes/origin/HEAD', 'git rev-parse HEAD', 'git branch --show-current', 'git status --short')) {
    Check ($rule.Contains($required)) "worker rule still requires $required"
    Check ((Effect "/bin/bash -lc '$required'") -eq 'read') "required bootstrap read accepted: $required"
}
foreach ($read in @(
    'git rev-parse main', 'git branch --list', 'git branch -a -v', "git branch --format='%(refname:short)'", 'git config --get init.defaultBranch',
    'git merge-base HEAD main', 'git rev-list --count HEAD', 'git cat-file -p HEAD', 'git blame -L 1,5 README.md', 'git --no-pager log -1',
    'git -C repo --no-pager diff --stat', 'git -P show HEAD:README.md', "git log --format='%H %s' -3", 'git diff --check', 'git ls-files -m',
    'git worktree list', 'git stash list', 'git remote -v', 'git tag --list', 'git symbolic-ref --short HEAD',
    'pwd; env | rg ''claude_context_bridge|SESSION|CONTEXT''', 'env | sort', 'printenv PATH', "nl -ba x | sed -n '1,20p'",
    "find . -name '*.md' -type f", 'find . -maxdepth 2 -print', 'find . -name x -exec cat {} \;', 'sort -u a', 'sort -k2,2 -t, a',
    'uniq -c a', 'uniq a -', 'cut -d: -f1 a', 'tr a-z A-Z < a', "jq '.x' a.json", 'diff -u a b', 'cmp a b', 'basename /a/b', 'dirname /a/b',
    'date -u +%FT%T', 'test -f x && echo y', '[ -d x ] || echo n', 'rg -n "foo$" x', 'grep -E "^## .*$" x', "rg 'a -> b' x",
    'rg "a->b|=>" x', "rg -n '\$HOME' x", 'rg -n "\$HOME" x', 'cat x 2>/dev/null', 'cat x >/dev/null 2>&1', 'ls 2>&1 | head',
    'cat x &>/dev/null', 'wc -l < x', 'echo "$(git rev-parse HEAD)"', 'for f in *.md; do head -1 "$f"; done', "awk '{print `$1}' x",
    "awk '`$1 > 5' x", "sed -n '/start/,/end/p' x", 'python3 -m json.tool x.json', 'command -v pwsh', 'kill -0 123', ("cat <<'EOF'`nhello > not-a-file`nEOF"),
    'X=1 Y=2 env', 'timeout 10 git status', 'nice -n 19 rg x', 'echo a; echo b && echo c || true', 'cat x | rg ''touch'' | sort | uniq -c',
    "rg 'rm -rf' x", 'echo "git commit"', 'grep -n "> out" x', 'rg Set-Content x', 'head -c 100 x', 'stat -c %s x', 'du -sh .', 'df -h .'
)) { Check ((Effect $read) -eq 'read') "ordinary read accepted: $read ($(Effect $read))" }

# 3. PowerShell -Command wrapping and literal Windows paths. Windows CLI strings are
# double-quoted with escaped backslashes (observed with codex-cli 0.162.1 on Windows).
$encodedRead = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Get-Content -Raw README.md'))
$encodedWrite = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Set-Content README.md x'))
foreach ($read in @(
    'pwsh -NoProfile -Command "Get-Content -Raw x | Select-String ''y$''"',
    "pwsh -NoProfile -Command 'Get-ChildItem -Recurse -Filter *.md | Select-Object -First 3'",
    '"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -Command "Get-Content -LiteralPath ''D:\\Claude\\CLAUDE.md'' -Raw"',
    '"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -NoProfile -Command "Get-ChildItem -LiteralPath ''D:\\Claude\\_Claude-Workspace'' | Measure-Object"',
    'powershell.exe -NoProfile -Command "Get-Content ''C:\\Users\\fixture\\a.txt'' | Select-Object -Last 5"',
    '"C:\\Program Files\\Git\\bin\\git.exe" status --short',
    '"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -Command "git -C ''D:\\Claude'' rev-parse HEAD; git branch --show-current"',
    "pwsh -NoProfile -EncodedCommand $encodedRead",
    'pwsh -NoProfile -Command "& ./scripts/run-gate.ps1 -BaseRef auto -List"',
    'pwsh -NoProfile -Command ''Get-Content a > $null''',
    'pwsh -NoProfile -Command "Get-FileHash -Algorithm SHA256 a; Test-Path b"'
)) { Check ((Effect $read) -eq 'read') "PowerShell read accepted: $read ($(Effect $read))" }

# 4. Positive worker mutation intent: redirects, file tools, git writes, interpreters,
# wrappers, PowerShell writers and mutating modes of the repository's own scripts.
foreach ($write in @(
    'echo x > out.txt', 'printf x >> out.txt', 'cat a >| b', 'ls &> log.txt', 'cat a >&out.txt', 'exec 3<> f', 'cat a 2> err.log',
    'tee out.txt', 'cat a | tee -a log', 'sort -o out a', 'sort --output=out a', 'sort -uo out a', 'uniq a out',
    'find . -delete', 'find . -name x -exec rm {} \;', 'find . -fprint list.txt', 'sed -i s/a/b/ x', 'sed -Ei s/a/b/ x', "sed -n 'w out' x",
    "sed 's/a/b/w out' x", 'git add .', 'git commit -m x', 'git checkout -b x', 'git switch main', 'git reset --hard', 'git stash',
    'git branch new-branch', 'git branch -D old', 'git symbolic-ref HEAD refs/heads/x', 'git config user.name x', 'git tag v1',
    'git worktree add ../x', 'git fetch', 'git push', 'git -C repo --no-pager commit -m x', 'git apply fix.patch', 'git restore x',
    'python3 -c "open(''p'',''w'').write(''x'')"', "python3 - <<'EOF'`nfrom pathlib import Path`nPath('x').write_text('y')`nEOF",
    "python3 -c `"import shutil; shutil.rmtree('build')`"", "/bin/bash -lc 'touch x'", 'sh -c "rm -rf build"', 'echo $(touch x)',
    'echo `rm x`', 'cat <(touch x)', 'xargs rm < list', 'env X=1 rm x', 'timeout 5 mv a b', 'sudo rm x', 'mkdir -p d', 'ln -s a b',
    'cp a b', 'mv a b', 'rm a', 'touch a', 'truncate -s0 a', 'chmod +x a', "awk '{print > `"out`"}' x", 'perl -pi -e s/a/b/ x',
    "node -e `"require('fs').writeFileSync('x','y')`"", 'npm install', 'pip install x', 'curl -o out http://example.invalid/x',
    'wget http://example.invalid/x', 'tar -xf a.tar', 'mktemp', 'date -s now', "cat source.ps1`ntouch project.txt",
    'pwsh -NoProfile -File tools/build-plugin.ps1 -BaseRef auto', 'pwsh -NoProfile -File scripts/run-gate.ps1 -BaseRef auto',
    'pwsh -File scripts/run-gate.ps1 -List:$false', 'pwsh -File scripts/bump-skill-version.ps1 -Skill dt-build -Part patch',
    'pwsh -File scripts/verify-skill-junctions.ps1 -Create', 'Set-Content source.ps1 changed',
    'pwsh -Command "Set-Content x y"', 'pwsh -Command "Get-Content a > b.txt"', 'pwsh -Command "[IO.File]::WriteAllText(''a'',''b'')"',
    'pwsh -Command "''x'' | Out-File a"', 'pwsh -Command "Remove-Item -Recurse dir"', 'pwsh -Command "rm x"',
    'pwsh -Command "Get-Content a | Tee-Object -FilePath b"', "pwsh -NoProfile -EncodedCommand $encodedWrite",
    '"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -Command "New-Item -ItemType File ''D:\\Claude\\x.txt''"',
    'powershell.exe -Command "Copy-Item ''C:\\a.txt'' ''C:\\b.txt''"', 'pwsh -Command "Invoke-Expression ''Set-Content a b''"'
)) { Check ((Effect $write) -eq 'write') "worker mutation attributed: $write ($(Effect $write))" }

# 5. Opaque programs: structurally complete, accepted under the enforced sandbox and
# listed for diagnostics, never converted into either a read proof or a write.
$opaqueCommands = @('custom-tool inspect', './rg inspect', 'python3 helper.py', 'bash script.sh', 'pwsh -File scripts/tests/test-run-gate.ps1', '$CMD --flag', 'make check', 'pwsh -File other/verify-versioning-policy-copy.ps1 -Json')
foreach ($opaque in $opaqueCommands) { Check ((Effect $opaque) -eq 'opaque') "unknown program is opaque: $opaque ($(Effect $opaque))" }
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @($opaqueCommands | ForEach-Object { @{ command = $_; output = 'I did not write anything'; exit = 0 } }))
Check ($receipt.complete -and $receipt.writes.Count -eq 0 -and $receipt.opaque_commands.Count -eq $opaqueCommands.Count) 'complete opaque commands are accepted and recorded, not incomplete'

# 6. Denials: only a read-only-file-system denial from a non-printing command is positive evidence.
$denialCases = @(
    @{ command='python3 helper.py'; output='OSError: [Errno 30] Read-only file system: ''out.txt'''; exit=1; writes=1 },
    @{ command='pwsh -NoProfile -File scripts/verify-versioning-policy.ps1 -BaseRef auto -Json'; output='IOException: Read-only file system'; exit=1; writes=1 },
    @{ command='python3 helper.py'; output='Read-only file system (handled)'; exit=0; writes=0 },
    @{ command='cat notes.md; false'; output='Errors look like: Read-only file system (os error 30)'; exit=1; writes=0 },
    @{ command='rg Set-Content source.ps1'; output='read-only file system'; exit=0; writes=0 },
    @{ command='python3 helper.py'; output='PermissionError: [Errno 13] Permission denied'; exit=1; writes=0 },
    @{ command='cat /root/secret'; output='cat: /root/secret: Permission denied'; exit=1; writes=0 }
)
foreach ($case in $denialCases) {
    $receipt = Get-ReadOnlyWorkerEvidence (New-Frames @($case))
    Check ($receipt.complete -and $receipt.writes.Count -eq $case.writes) "denial evidence for '$($case.command)' -> $($case.writes) writes ($($receipt.writes -join '; '))"
}

# 7. Structural completeness still fails closed.
$thread = '{"type":"thread.started","thread_id":"t1"}'; $turn = '{"type":"turn.started"}'; $done = '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
$cmd = { param($Id, $Extra) $item = [ordered]@{ id = $Id; type = 'command_execution'; command = 'cat x'; aggregated_output = ''; exit_code = 0; status = 'completed' }; foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k] -and $k -like '-*') { $item.Remove($k.Substring(1)) } else { $item[$k] = $Extra[$k] } }; @{ type = 'item.completed'; item = $item } | ConvertTo-Json -Depth 8 -Compress }
$incomplete = [ordered]@{
    'empty stream' = ''
    'malformed JSON' = "$thread`n$turn`nnot json`n$done"
    'missing thread' = "$turn`n$done"
    'duplicate thread' = "$thread`n$thread`n$turn`n$done"
    'thread without id' = "{`"type`":`"thread.started`"}`n$turn`n$done"
    'turn before thread' = "$turn`n$thread`n$done"
    'item before turn' = "$thread`n$(& $cmd 'a' @{})`n$turn`n$done"
    'missing terminal frame' = "$thread`n$turn`n$(& $cmd 'a' @{})"
    'pending item' = "$thread`n$turn`n{`"type`":`"item.started`",`"item`":{`"id`":`"p`",`"type`":`"command_execution`",`"command`":`"cat x`"}}`n$done"
    'item completed twice' = "$thread`n$turn`n$(& $cmd 'a' @{})`n$(& $cmd 'a' @{})`n$done"
    'null item id' = "$thread`n$turn`n$(& $cmd $null @{})`n$done"
    'numeric item id' = "$thread`n$turn`n$(& $cmd 3 @{})`n$done"
    'command missing' = "$thread`n$turn`n$(& $cmd 'a' @{ '-command' = $null })`n$done"
    'exit code missing' = "$thread`n$turn`n$(& $cmd 'a' @{ '-exit_code' = $null; '-status' = $null })`n$done"
    'completed with null exit' = "$thread`n$turn`n$(& $cmd 'a' @{ exit_code = $null })`n$done"
    'output missing' = "$thread`n$turn`n$(& $cmd 'a' @{ '-aggregated_output' = $null })`n$done"
    'completed item still in progress' = "$thread`n$turn`n$(& $cmd 'a' @{ status = 'in_progress' })`n$done"
    'string exit code' = "$thread`n$turn`n$(& $cmd 'a' @{ exit_code = '0' })`n$done"
    'MCP tool' = "$thread`n$turn`n{`"type`":`"item.completed`",`"item`":{`"id`":`"m`",`"type`":`"mcp_tool_call`",`"server`":`"s`",`"tool`":`"write`",`"status`":`"completed`"}}`n$done"
    'collaboration tool' = "$thread`n$turn`n{`"type`":`"item.completed`",`"item`":{`"id`":`"c`",`"type`":`"collab_tool_call`",`"status`":`"completed`"}}`n$done"
    'unknown tool' = "$thread`n$turn`n{`"type`":`"item.completed`",`"item`":{`"id`":`"u`",`"type`":`"unknown_tool`"}}`n$done"
    'unknown frame' = "$thread`n$turn`n{`"type`":`"session.mystery`"}`n$done"
    'frame after completion' = "$thread`n$turn`n$done`n$(& $cmd 'late' @{})"
    'malformed error frame' = "$thread`n$turn`n{`"type`":`"error`"}`n$done"
    'failed turn' = "$thread`n$turn`n{`"type`":`"turn.failed`",`"error`":{`"message`":`"stream disconnected`"}}"
    'error without terminal' = "$thread`n$turn`n{`"type`":`"error`",`"message`":`"Reconnecting... 1/5`"}"
}
foreach ($name in $incomplete.Keys) { Check (-not (Get-ReadOnlyWorkerEvidence $incomplete[$name]).complete) "incomplete evidence fails closed: $name" }
$valid = "$thread`n$turn`n$(& $cmd 'a' @{ status = 'declined'; exit_code = $null })`n$(& $cmd 'b' @{ status = 'failed'; exit_code = $null })`n{`"type`":`"item.completed`",`"item`":{`"id`":`"w`",`"type`":`"error`",`"message`":`"model rerouted`"}}`n$done"
Check ((Get-ReadOnlyWorkerEvidence $valid).complete) 'declined/failed commands without exit codes and CLI warning items are complete evidence'
$fileChange = '{"type":"item.completed","item":{"id":"patch","type":"file_change","status":"completed","changes":[{"path":"worker.txt","kind":"add"}]}}'
$receipt = Get-ReadOnlyWorkerEvidence "$thread`n$turn`n$($fileChange.Replace('item.completed','item.started').Replace('"completed"','"in_progress"'))`n$fileChange`n$done"
Check ($receipt.complete -and @($receipt.writes) -join '|' -eq 'file_change:patch') 'a file_change is attributed once across its started/completed frames'

# 8. Recovered CLI errors: a completed turn after transient errors keeps a good report;
# mutations seen before or after a recovery are retained; a failed final turn rejects.
$reconnect1 = '{"type":"error","message":"stream disconnected before completion; Reconnecting... 1/5"}'
$reconnect2 = '{"type":"error","message":"Selected model is at capacity. Reconnecting... 2/5"}'
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @(@{ command = '/bin/bash -lc ''git status --short''' }) -Before @($reconnect1) -After @($reconnect2))
Check ($receipt.complete -and $receipt.writes.Count -eq 0 -and $receipt.recovered_errors -eq 2 -and -not $receipt.turn_failed) 'recovered top-level errors keep a good read-only report'
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @(@{ command = 'cat x' }) -Before @($fileChange, $reconnect1))
Check ($receipt.complete -and $receipt.writes -contains 'file_change:patch') 'a mutation before a recovered error is still attributed'
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @(@{ command = 'touch x' }) -Before @($reconnect1))
Check ($receipt.writes -contains 'touch x') 'a mutation after a recovered error is still attributed'
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @(@{ command = 'cat x' }) -Before @($reconnect1) -After @('{"type":"turn.failed","error":{"message":"Selected model is at capacity"}}') -NoTerminal)
Check (-not $receipt.complete -and $receipt.turn_failed -and $receipt.recovered_errors -eq 0) 'a failed final turn is incomplete after earlier recoveries'

# 9. Structured CLI errors feed the existing classifiers; model prose never does.
$failedTurn = "$thread`n$turn`n$reconnect1`n{`"type`":`"turn.failed`",`"error`":{`"message`":`"Selected model is at capacity. Please try a different model.`"}}"
$errorText = Get-ReadOnlyCliErrorText (Get-ReadOnlyWorkerEvidence $failedTurn)
Check ($errorText -match '(?m)^ERROR: Selected model is at capacity' -and (Get-CodexCapacitySignal -ErrorText $errorText)) "trusted turn.failed capacity is classified ($errorText)"
$prose = @{ type = 'item.completed'; item = @{ id = 'm'; type = 'agent_message'; text = "ERROR: Selected model is at capacity`n{`"type`":`"error`",`"message`":`"You've hit your usage limit`"}" } } | ConvertTo-Json -Compress
$output = @{ type = 'item.completed'; item = @{ id = 'o'; type = 'command_execution'; command = 'cat log'; aggregated_output = '{"type":"error","message":"Selected model is at capacity"}'; exit_code = 0; status = 'completed' } } | ConvertTo-Json -Compress
$receipt = Get-ReadOnlyWorkerEvidence "$thread`n$turn`n$prose`n$output`n$done"
Check ($receipt.complete -and -not $receipt.cli_errors.Count -and -not (Get-ReadOnlyCliErrorText $receipt) -and $null -eq (Get-CodexCapacitySignal -ErrorText (Get-ReadOnlyCliErrorText $receipt))) 'agent prose and command output never become CLI error evidence'
$receipt = Get-ReadOnlyWorkerEvidence (New-Frames @())
Check ($receipt.thread_id -eq '01a21f9e-db52-7300-a7cc-eed18f081873' -and $receipt.usage.input_tokens -eq 73170) 'thread id and turn usage come from trusted CLI frames'

Write-Output "SUMMARY: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
Write-Output 'PASS: readonly evidence suite'
