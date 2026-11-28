# Read-only worker evidence for `codex exec --json`.
#
# Trust boundary. The Codex read-only sandbox, which the wrapper always requests
# (`--sandbox read-only`, MXC on Windows) and never relaxes for read-only workers,
# is what prevents writes. This file does not try to prove, command by command,
# that a program cannot write; that is impossible for arbitrary programs and is
# the sandbox's job. It does two narrower things:
#   1. Completeness: the CLI's own structured stdout frames must form one well-formed
#      thread and one turn that completes, with every tool item finished and every
#      tool type supported. Malformed JSON, unknown frames or tools, missing terminal
#      frames and failed turns are missing evidence and fail closed.
#   2. Attribution: only positive evidence of a worker write attempt rejects a report:
#      a file_change item, a command whose parsed intent mutates files or repository
#      state (shell redirects, rm/mv/sed -i, mutating git verbs, PowerShell writers,
#      interpreter write APIs, known mutating repo scripts), or a non-printing command
#      that failed with a read-only-file-system denial.
# A complete command whose effect is merely unknown ("opaque") is recorded for
# diagnostics and accepted: the sandbox, not this parser, bounds it. Workspace deltas
# made by other processes are never attributed to the reader. Parse only CLI frames;
# model prose lives inside string fields of those frames and is never interpreted.

$script:RoPrinterTools = @(
    'cat','head','tail','nl','wc','less','more','tac','rev','column','fold','fmt','paste','join','expand','unexpand',
    'cut','tr','sort','uniq','comm','diff','cmp','sdiff','jq','rg','grep','egrep','fgrep','sed','awk','gawk','mawk','nawk',
    'find','fd','ls','tree','stat','file','readlink','realpath','basename','dirname','echo','printf','env','printenv',
    'xxd','od','hexdump','strings','md5sum','sha1sum','sha256sum','sha512sum','b2sum','cksum','base64','du','df','ps',
    'pgrep','lsof','ss','netstat','getent','date','pwd','which','whereis','type','id','whoami','groups','uname','nproc',
    'free','uptime','lscpu','lsblk','getconf','locale','seq','journalctl','systemctl','hostname'
)
$script:RoQuietReads = @(
    'cd','pushd','popd','true','false','test','[','[[',']]','sleep','export','local','declare','typeset','set','unset',
    'shopt','umask','alias','unalias','wait','exit','return',':','read','mapfile','readarray','let','hash','break','continue'
)
$script:RoWriteTools = @(
    'rm','rmdir','unlink','shred','mv','cp','ln','link','install','mkdir','mkfifo','mknod','touch','truncate','chmod','chown',
    'chgrp','chattr','setfacl','rsync','scp','apply_patch','split','csplit','kill','pkill','killall'
)
$script:RoPsAliases = @{
    gc='get-content'; type='get-content'; cat='get-content'; ls='get-childitem'; dir='get-childitem'; gci='get-childitem'
    sc='set-content'; ac='add-content'; rm='remove-item'; del='remove-item'; erase='remove-item'; ri='remove-item'
    rd='remove-item'; rmdir='remove-item'; mv='move-item'; move='move-item'; mi='move-item'; cp='copy-item'; copy='copy-item'
    cpi='copy-item'; ni='new-item'; md='new-item'; mkdir='new-item'; ren='rename-item'; rni='rename-item'; clc='clear-content'
    tee='tee-object'; sl='set-location'; cd='set-location'; chdir='set-location'; pwd='get-location'; gl='get-location'
    echo='write-output'; write='write-output'; iex='invoke-expression'; sls='select-string'; select='select-object'
    where='where-object'; '?'='where-object'; '%'='foreach-object'; foreach='foreach-object'; sort='sort-object'
    measure='measure-object'; ft='format-table'; fl='format-list'; fw='format-wide'; gi='get-item'; gp='get-itemproperty'
    gm='get-member'; gcm='get-command'; gal='get-alias'; gps='get-process'; ps='get-process'; rvpa='resolve-path'
    saps='start-process'; start='start-process'; icm='invoke-command'; sp='set-itemproperty'; si='set-item'
}
$script:RoPsWriters = @(
    'set-content','add-content','out-file','remove-item','new-item','move-item','copy-item','rename-item','clear-content',
    'clear-item','set-item','set-itemproperty','new-itemproperty','remove-itemproperty','rename-itemproperty',
    'copy-itemproperty','move-itemproperty','export-csv','export-clixml','export-alias','export-formatdata',
    'export-modulemember','export-pssession','compress-archive','expand-archive','start-transcript','set-acl',
    'new-temporaryfile'
)
$script:RoPsReaders = @(
    'get-content','get-childitem','get-item','get-itemproperty','get-location','get-filehash','get-command','get-member',
    'get-alias','get-process','get-date','get-host','get-variable','get-help','get-module','get-acl','select-string',
    'select-object','where-object','foreach-object','sort-object','measure-object','group-object','compare-object',
    'format-table','format-list','format-wide','format-hex','out-string','out-host','out-null','out-default',
    'write-output','write-host','write-verbose','write-warning','write-error','write-information','write-debug',
    'convertfrom-json','convertto-json','convertfrom-csv','convertto-csv','convertfrom-stringdata','test-path',
    'test-json','resolve-path','split-path','join-path','set-location','push-location','pop-location','set-variable',
    'new-variable','set-strictmode','import-csv','import-clixml','get-uptime','get-psdrive'
)
$script:RoHarmlessTargets = @('/dev/null','/dev/stdout','/dev/stderr','/dev/tty','/dev/fd/0','/dev/fd/1','/dev/fd/2','nul','$null')

function New-RoProfile([string]$Effect = 'read', [bool]$Printer = $false) { @{ effect = $Effect; printer = $Printer } }

function Merge-RoProfile($Into, $From) {
    if ($From.effect -eq 'write' -or $Into.effect -eq 'write') { $Into.effect = 'write' }
    elseif ($From.effect -eq 'opaque' -or $Into.effect -eq 'opaque') { $Into.effect = 'opaque' }
    if ($From.printer) { $Into.printer = $true }
}

function Get-RoProgramName([string]$Word) {
    $leaf = ($Word -split '[\\/]')[-1].ToLowerInvariant()
    if ($leaf -match '^(.+)\.(?:exe|com)$') { $leaf = $Matches[1] }
    return $leaf
}

function Test-RoTrustedProgramPath([string]$Word) {
    # Bare names resolve through PATH; qualified names are trusted only in OS tool directories.
    if ($Word -notmatch '[\\/]') { return $true }
    $w = $Word.Replace('\','/')
    return $w -match '^/(?:usr/)?(?:local/)?s?bin/[^/]+$' -or $w -match '^/opt/homebrew/bin/[^/]+$' -or
        $w -match '(?i)^[a-z]:/windows/system32/(?:windowspowershell/v1\.0/)?[^/]+$' -or
        $w -match '(?i)^[a-z]:/program files/(?:powershell/\d+(?:-preview)?|git/(?:usr/)?bin|git/cmd)/[^/]+$'
}

function Test-RoSwitch([string[]]$Words, [string]$Name, [int]$MinPrefix) {
    foreach ($w in $Words) {
        if ($w -match '^-(?<p>[A-Za-z]+)(?::\$?true)?$') {
            $p = $Matches.p.ToLowerInvariant()
            if ($p.Length -ge $MinPrefix -and $Name.ToLowerInvariant().StartsWith($p)) { return $true }
        }
    }
    return $false
}

function Get-RoScriptContract([string]$Path, [string[]]$Arguments) {
    # Repository scripts whose contracts were read in source: -List/-ValidateOnly exit
    # before any write; the versioning verifier and link-format test only read; bumps,
    # packaging, full gates and junction creation write. A match is by repository path and
    # mode, never by a validator-like basename, and it cannot suppress denial evidence.
    $p = $Path.Replace('\','/')
    if ($p -match '(?i)(?:^|/)scripts/run-gate\.ps1$') { if (Test-RoSwitch $Arguments 'List' 2) { return 'read' } else { return 'write' } }
    if ($p -match '(?i)(?:^|/)scripts/verify-versioning-policy\.ps1$') { return 'read' }
    if ($p -match '(?i)(?:^|/)tools/build-plugin\.ps1$') { if (Test-RoSwitch $Arguments 'ValidateOnly' 1) { return 'read' } else { return 'write' } }
    if ($p -match '(?i)(?:^|/)scripts/verify-skill-junctions\.ps1$') { if (Test-RoSwitch $Arguments 'Create' 2) { return 'write' } else { return 'read' } }
    if ($p -match '(?i)(?:^|/)scripts/bump-(?:skill|plugin)-version\.ps1$') { return 'write' }
    if ($p -match '(?i)(?:^|/)scripts/test-file-link-format\.py$') { return 'read' }
    return $null
}

function Get-RoCodeWriteEffect([string]$Code, [string]$Language) {
    # Interpreter code is opaque unless it names a file-writing API.
    $patterns = switch ($Language) {
        'python' { @(
            '\bopen\s*\((?:[^()]|\([^()]*\))*?,\s*(?:mode\s*=\s*)?[rbtU]*[''"][rbtU]*[wax+]',
            '\.open\s*\(\s*(?:mode\s*=\s*)?[''"][rbtU]*[wax+]',
            '\.(?:write_text|write_bytes|touch|mkdir|unlink|rmdir|rename|replace|symlink_to|hardlink_to|chmod)\s*\(',
            '\bos\.(?:remove|unlink|rename|renames|replace|rmdir|removedirs|mkdir|makedirs|symlink|link|chmod|chown|truncate|utime|mkfifo|mknod)\s*\(',
            '\bshutil\.(?:copy\w*|move|rmtree|make_archive|unpack_archive|chown)\s*\(',
            '\btempfile\.(?:mkstemp|mkdtemp|NamedTemporaryFile|TemporaryFile|TemporaryDirectory|SpooledTemporaryFile)\s*\(') }
        'node' { @('\.(?:writeFile\w*|appendFile\w*|unlink\w*|rmSync|rmdir\w*|mkdir\w*|rename\w*|copyFile\w*|cpSync|symlink\w*|truncate\w*|chmod\w*|createWriteStream)\s*\(', '\b(?:fs|fsp|promises)\.(?:write\w*|rm|cp)\s*\(') }
        default { @() }
    }
    foreach ($pattern in $patterns) { if ($Code -match $pattern) { return 'write' } }
    return 'opaque'
}

function Read-RoBalanced([string]$Text, [int]$Start) {
    # $Start is just after '('. Returns the index of the matching ')' or -1.
    $depth = 1
    for ($j = $Start; $j -lt $Text.Length; $j++) {
        $ch = $Text[$j]
        if ($ch -eq '\') { $j++; continue }
        if ($ch -eq "'") { $k = $Text.IndexOf("'", $j + 1); if ($k -lt 0) { return -1 }; $j = $k; continue }
        if ($ch -eq '"') {
            $j++
            while ($j -lt $Text.Length -and $Text[$j] -ne '"') { if ($Text[$j] -eq '\') { $j++ }; $j++ }
            if ($j -ge $Text.Length) { return -1 }
            continue
        }
        if ($ch -eq '(') { $depth++ } elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { return $j } }
    }
    return -1
}

function Read-RoExpansion($State, [string]$Text, [int]$I) {
    # $Text[$I] is '$'. Returns the last consumed index; marks the word dynamic.
    $next = if ($I + 1 -lt $Text.Length) { $Text[$I + 1] } else { [char]0 }
    if ($next -eq '(') {
        if ($I + 2 -lt $Text.Length -and $Text[$I + 2] -eq '(') {
            $end = $Text.IndexOf('))', $I + 3)
            if ($end -lt 0) { $State.error = $true; return $Text.Length }
            $State.dynamic = $true; $State.active = $true; return $end + 1
        }
        $end = Read-RoBalanced $Text ($I + 2)
        if ($end -lt 0) { $State.error = $true; return $Text.Length }
        $State.subs.Add($Text.Substring($I + 2, $end - $I - 2)); $State.dynamic = $true; $State.active = $true
        return $end
    }
    if ($next -eq '{') {
        $end = $Text.IndexOf('}', $I + 2)
        if ($end -lt 0) { $State.error = $true; return $Text.Length }
        $State.dynamic = $true; $State.active = $true; return $end
    }
    if ("$next" -match '^[A-Za-z_]$') {
        $j = $I + 1
        while ($j + 1 -lt $Text.Length -and "$($Text[$j + 1])" -match '^[A-Za-z0-9_]$') { $j++ }
        $State.dynamic = $true; $State.active = $true; return $j
    }
    if ("$next" -match '^[0-9?#@*!$-]$') { $State.dynamic = $true; $State.active = $true; return $I + 1 }
    # A '$' before a quote, space or end is literal: regex anchors such as "x$".
    [void]$State.word.Append('$'); $State.active = $true; return $I
}

function Complete-RoWord($State) {
    if (-not $State.active) { return }
    $value = $State.word.ToString()
    if ($State.pendingOp) {
        if ($State.pendingOp -in @('<<','<<-')) {
            $State.heredocs.Add(@{ delimiter = $value; strip = ($State.pendingOp -eq '<<-'); segment = $State.segment })
        } else {
            $State.segment.redirects.Add(@{ op = $State.pendingOp; target = $value; dynamic = $State.dynamic })
        }
        $State.pendingOp = $null
    } else {
        $State.segment.words.Add($value); $State.segment.dynamic.Add([bool]$State.dynamic)
    }
    [void]$State.word.Clear(); $State.active = $false; $State.dynamic = $false
}

function New-RoSegment { @{ words = [Collections.Generic.List[string]]::new(); dynamic = [Collections.Generic.List[bool]]::new(); redirects = [Collections.Generic.List[object]]::new(); heredoc = $null } }

function Complete-RoSegment($State) {
    Complete-RoWord $State
    if ($State.pendingOp) { $State.error = $true; $State.pendingOp = $null }
    if ($State.segment.words.Count -or $State.segment.redirects.Count) { $State.segments.Add($State.segment) }
    $State.segment = New-RoSegment
}

function Split-RoShellScript([string]$Text) {
    # POSIX shell subset: quotes, escapes, expansions, substitutions, operators,
    # redirects, comments and here-documents. Anything it cannot delimit is an error.
    $s = @{ word = [Text.StringBuilder]::new(); active = $false; dynamic = $false; pendingOp = $null; error = $false
        segment = (New-RoSegment); segments = [Collections.Generic.List[object]]::new()
        subs = [Collections.Generic.List[string]]::new(); heredocs = [Collections.Generic.List[object]]::new() }
    $n = $Text.Length
    for ($i = 0; $i -lt $n; $i++) {
        $c = $Text[$i]
        if ($c -eq '\') {
            if ($i + 1 -lt $n) { $i++; if ($Text[$i] -ne "`n") { [void]$s.word.Append($Text[$i]); $s.active = $true } }
            continue
        }
        if ($c -eq "'") {
            $end = $Text.IndexOf("'", $i + 1)
            if ($end -lt 0) { $s.error = $true; break }
            [void]$s.word.Append($Text.Substring($i + 1, $end - $i - 1)); $s.active = $true; $i = $end; continue
        }
        if ($c -eq '"') {
            $s.active = $true; $i++
            while ($i -lt $n -and $Text[$i] -ne '"') {
                $d = $Text[$i]
                if ($d -eq '\' -and $i + 1 -lt $n -and $Text[$i + 1] -in @([char]'$', [char]'`', [char]'"', [char]'\', [char]"`n")) {
                    $i++; if ($Text[$i] -ne "`n") { [void]$s.word.Append($Text[$i]) }
                } elseif ($d -eq '$') { $i = Read-RoExpansion $s $Text $i }
                elseif ($d -eq '`') {
                    $end = $Text.IndexOf('`', $i + 1)
                    if ($end -lt 0) { $s.error = $true; $i = $n; break }
                    $s.subs.Add($Text.Substring($i + 1, $end - $i - 1)); $s.dynamic = $true; $i = $end
                } else { [void]$s.word.Append($d) }
                $i++
            }
            if ($i -ge $n) { $s.error = $true; break }
            continue
        }
        if ($c -eq '$') {
            if ($i + 1 -lt $n -and $Text[$i + 1] -eq "'") {
                $j = $i + 2
                while ($j -lt $n -and $Text[$j] -ne "'") { if ($Text[$j] -eq '\') { $j++ }; $j++ }
                if ($j -ge $n) { $s.error = $true; break }
                [void]$s.word.Append($Text.Substring($i + 2, $j - $i - 2)); $s.active = $true; $i = $j; continue
            }
            $i = Read-RoExpansion $s $Text $i; continue
        }
        if ($c -eq '`') {
            $end = $Text.IndexOf('`', $i + 1)
            if ($end -lt 0) { $s.error = $true; break }
            $s.subs.Add($Text.Substring($i + 1, $end - $i - 1)); $s.dynamic = $true; $s.active = $true; $i = $end; continue
        }
        if (($c -eq '<' -or $c -eq '>') -and -not $s.active -and $i + 1 -lt $n -and $Text[$i + 1] -eq '(') {
            $end = Read-RoBalanced $Text ($i + 2)
            if ($end -lt 0) { $s.error = $true; break }
            $s.subs.Add($Text.Substring($i + 2, $end - $i - 2)); $s.dynamic = $true; $s.active = $true; $i = $end; continue
        }
        if ($c -eq '#' -and -not $s.active) {
            $end = $Text.IndexOf("`n", $i); if ($end -lt 0) { $end = $n }; $i = $end - 1; continue
        }
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r") { Complete-RoWord $s; continue }
        if ($c -eq "`n") {
            Complete-RoSegment $s
            if ($s.heredocs.Count) {
                $pos = $i + 1
                foreach ($doc in $s.heredocs) {
                    $body = [Text.StringBuilder]::new(); $closed = $false
                    while ($pos -lt $n) {
                        $nl = $Text.IndexOf("`n", $pos); if ($nl -lt 0) { $nl = $n }
                        $line = $Text.Substring($pos, $nl - $pos); $pos = $nl + 1
                        $probe = if ($doc.strip) { $line.TrimStart("`t") } else { $line }
                        if ($probe.TrimEnd("`r") -ceq $doc.delimiter) { $closed = $true; break }
                        [void]$body.Append($line).Append("`n")
                    }
                    $doc.segment.heredoc = [string]$doc.segment.heredoc + $body.ToString()
                    if (-not $closed) { $pos = $n }
                }
                $s.heredocs.Clear(); $i = $pos - 1
            }
            continue
        }
        if ($c -eq ';' -or $c -eq '(' -or $c -eq ')') { Complete-RoSegment $s; continue }
        if ($c -eq '|') { Complete-RoSegment $s; if ($i + 1 -lt $n -and $Text[$i + 1] -in @([char]'|', [char]'&')) { $i++ }; continue }
        if ($c -eq '&') {
            if ($i + 1 -lt $n -and $Text[$i + 1] -eq '>') {
                Complete-RoWord $s; $i++; $op = '&>'
                if ($i + 1 -lt $n -and $Text[$i + 1] -eq '>') { $i++; $op = '&>>' }
                $s.pendingOp = $op; continue
            }
            Complete-RoSegment $s; if ($i + 1 -lt $n -and $Text[$i + 1] -eq '&') { $i++ }; continue
        }
        if ($c -eq '>' -or $c -eq '<') {
            # A bare number immediately before the operator is a file descriptor.
            if ($s.active -and -not $s.dynamic -and $s.word.ToString() -match '^\d+$') { [void]$s.word.Clear(); $s.active = $false }
            else { Complete-RoWord $s }
            if ($s.pendingOp) { $s.error = $true }
            $op = [string]$c
            if ($c -eq '>') {
                if ($i + 1 -lt $n -and $Text[$i + 1] -in @([char]'>', [char]'|')) { $i++; $op += $Text[$i] }
                elseif ($i + 1 -lt $n -and $Text[$i + 1] -eq '&') { $i++; $op = '>&' }
            } else {
                if ($i + 2 -lt $n -and $Text[$i + 1] -eq '<' -and $Text[$i + 2] -eq '<') { $i += 2; $op = '<<<' }
                elseif ($i + 1 -lt $n -and $Text[$i + 1] -eq '<') { $i++; $op = '<<'; if ($i + 1 -lt $n -and $Text[$i + 1] -eq '-') { $i++; $op = '<<-' } }
                elseif ($i + 1 -lt $n -and $Text[$i + 1] -in @([char]'&', [char]'>')) { $i++; $op += $Text[$i] }
            }
            $s.pendingOp = $op; continue
        }
        [void]$s.word.Append($c); $s.active = $true
    }
    Complete-RoSegment $s
    if ($s.heredocs.Count) { foreach ($doc in $s.heredocs) { if ($null -eq $doc.segment.heredoc) { $doc.segment.heredoc = '' } } }
    return $s
}

function Get-RoRedirectEffect($Redirect) {
    $target = $Redirect.target.ToLowerInvariant()
    switch -Regex ($Redirect.op) {
        '^(?:>|>>|>\||&>|&>>)$' { if (-not $Redirect.dynamic -and $target -in $script:RoHarmlessTargets) { return 'read' }; return 'write' }
        '^>&$' { if ($target -match '^(?:\d+|-)$' -or (-not $Redirect.dynamic -and $target -in $script:RoHarmlessTargets)) { return 'read' }; return 'write' }
        '^<>$' { return 'write' }
        default { return 'read' }
    }
}

function Get-RoGitEffect([string[]]$Words) {
    $i = 1; $risky = $false
    while ($i -lt $Words.Count) {
        $w = $Words[$i]
        if ($w -in @('-C','-c','--git-dir','--work-tree','--namespace','--super-prefix','--config-env')) {
            if ($w -eq '-c' -and $i + 1 -lt $Words.Count -and $Words[$i + 1] -match '(?i)^(?:core\.(?:pager|fsmonitor|hookspath|sshcommand|editor|askpass)|diff\.|alias\.|credential\.|pager\.|filter\.|gpg\.|sequence\.editor|uploadpack\.|protocol\.)') { $risky = $true }
            $i += 2; continue
        }
        if ($w -match '^--(?:git-dir|work-tree|namespace|config-env)=' -or $w -in @('--no-pager','-P','-p','--paginate','--no-optional-locks','--literal-pathspecs','--glob-pathspecs','--noglob-pathspecs','--icase-pathspecs','--bare','--no-replace-objects','--no-lazy-fetch')) { $i++; continue }
        break
    }
    if ($i -ge $Words.Count) { return 'read' }
    $sub = $Words[$i].ToLowerInvariant()
    $gitArgs = @(if ($i + 1 -lt $Words.Count) { $Words[($i + 1)..($Words.Count - 1)] })
    $has = { param([string]$Pattern) [bool](@($gitArgs | Where-Object { $_ -match $Pattern }).Count) }
    $positional = @($gitArgs | Where-Object { $_ -notmatch '^-' })
    if ($sub -match '^--(?:version|help|exec-path|html-path|man-path|info-path)$') { return 'read' }
    $effect = switch ($sub) {
        { $_ -in @('status','rev-parse','ls-files','ls-tree','ls-remote','merge-base','rev-list','blame','annotate','describe','name-rev','for-each-ref','show-ref','shortlog','whatchanged','count-objects','check-ignore','check-attr','check-ref-format','check-mailmap','var','version','help','diff-tree','diff-index','diff-files','range-diff','cherry','verify-commit','verify-tag','verify-pack','show-branch','get-tar-commit-id','column','fast-export') } {
            if (& $has '^--(?:ext-diff|textconv)$') { 'opaque' } else { 'read' }; break }
        { $_ -in @('diff','show','log') } {
            if (& $has '^--output(?:=|$)') { 'write' } elseif (& $has '^--(?:ext-diff|textconv)$') { 'opaque' } else { 'read' }; break }
        'grep' { if (& $has '^(?:-O|--open-files-in-pager)') { 'opaque' } else { 'read' }; break }
        'cat-file' { if (& $has '^--(?:textconv|filters)$') { 'opaque' } else { 'read' }; break }
        'symbolic-ref' {
            $refs = @($positional)
            if ((& $has '^(?:-d|--delete)$') -or $refs.Count -ge 2) { 'write' } else { 'read' }; break }
        'branch' {
            if ((& $has '^-[A-Za-z]*[dDmMcCu]' ) -or (& $has '^--(?:delete|move|copy|set-upstream-to|unset-upstream|edit-description|track|no-track|force|create-reflog|recurse-submodules)')) { 'write' }
            elseif ($positional.Count -and -not (& $has '^(?:-l|--list|--contains|--no-contains|--merged|--no-merged|--points-at|--format|--sort)')) { 'write' }
            else { 'read' }; break }
        'tag' {
            if (& $has '^(?:-d|--delete|-a|--annotate|-s|--sign|-f|--force|-m|-F|--file)') { 'write' }
            elseif ($positional.Count -and -not (& $has '^(?:-l|--list|-v|--verify|-n\d*|--contains|--no-contains|--merged|--no-merged|--points-at|--format|--sort)')) { 'write' }
            else { 'read' }; break }
        'config' {
            if (& $has '^(?:--unset|--unset-all|--add|--replace-all|--rename-section|--remove-section|-e|--edit)$') { 'write' }
            elseif ($positional.Count -and $positional[0] -in @('set','unset','rename-section','remove-section','edit')) { 'write' }
            elseif ((& $has '^(?:--get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list)$') -or ($positional.Count -and $positional[0] -in @('get','list'))) { 'read' }
            else {
                $valueOptions = @('-f','--file','--blob','--type','--default','--comment')
                $count = 0
                for ($k = 0; $k -lt $gitArgs.Count; $k++) { if ($gitArgs[$k] -in $valueOptions) { $k++; continue }; if ($gitArgs[$k] -notmatch '^-') { $count++ } }
                if ($count -ge 2) { 'write' } else { 'read' }
            }; break }
        'remote' { if (-not $positional.Count -or $positional[0] -in @('show','get-url')) { 'read' } else { 'write' }; break }
        'worktree' { if ($positional.Count -and $positional[0] -eq 'list') { 'read' } else { 'write' }; break }
        'stash' { if ($positional.Count -and $positional[0] -in @('list','show')) { 'read' } else { 'write' }; break }
        'notes' { if (-not $positional.Count -or $positional[0] -in @('list','show')) { 'read' } else { 'write' }; break }
        'reflog' { if (-not $positional.Count -or $positional[0] -in @('show','exists')) { 'read' } else { 'write' }; break }
        'sparse-checkout' { if ($positional.Count -and $positional[0] -eq 'list') { 'read' } else { 'write' }; break }
        'submodule' { if (-not $positional.Count -or $positional[0] -in @('status','summary')) { 'read' } elseif ($positional[0] -eq 'foreach') { 'opaque' } else { 'write' }; break }
        'bundle' { if ($positional.Count -and $positional[0] -in @('verify','list-heads')) { 'read' } else { 'write' }; break }
        'archive' { if (& $has '^(?:-o|--output)') { 'write' } else { 'read' }; break }
        'format-patch' { if (& $has '^--stdout$') { 'read' } else { 'write' }; break }
        'fsck' { if (& $has '^--lost-found$') { 'write' } else { 'read' }; break }
        'hash-object' { if (& $has '^-w$') { 'write' } else { 'read' }; break }
        'interpret-trailers' { if (& $has '^--in-place$') { 'write' } else { 'read' }; break }
        'merge-tree' { if (& $has '^--write-tree$') { 'write' } else { 'read' }; break }
        'apply' { if ((& $has '^--(?:check|stat|numstat|summary)$') -and -not (& $has '^--(?:apply|index|cached|3way)$')) { 'read' } else { 'write' }; break }
        { $_ -in @('add','rm','mv','clean') } { if (& $has '^(?:-n|--dry-run)$') { 'read' } else { 'write' }; break }
        'commit' { if (& $has '^--dry-run$') { 'read' } else { 'write' }; break }
        { $_ -in @('am','checkout','switch','restore','reset','merge','rebase','cherry-pick','revert','pull','push','fetch','clone','init','gc','prune','repack','update-ref','update-index','write-tree','commit-tree','read-tree','maintenance','replace','filter-branch','filter-repo','mktag','mktree','pack-refs','prune-packed','checkout-index','unpack-objects','index-pack','pack-objects','rerere','bisect','stage','bugreport','lfs') } { 'write'; break }
        default { 'opaque' }
    }
    if ($risky -and $effect -eq 'read') { return 'opaque' }
    return $effect
}

function Get-RoSedEffect([string[]]$SedArgs) {
    $scripts = [Collections.Generic.List[string]]::new(); $fromFile = $false; $explicit = $false
    for ($k = 0; $k -lt $SedArgs.Count; $k++) {
        $a = $SedArgs[$k]
        if ($a -match '^--in-place' -or $a -match '^-[A-Za-z]*i') { return 'write' }
        if ($a -in @('-e','--expression') -and $k + 1 -lt $SedArgs.Count) { $scripts.Add($SedArgs[$k + 1]); $explicit = $true; $k++; continue }
        if ($a -match '^--expression=(.*)$') { $scripts.Add($Matches[1]); $explicit = $true; continue }
        if ($a -in @('-f','--file') -or $a -match '^--file=') { $fromFile = $true; if ($a -in @('-f','--file')) { $k++ }; continue }
        if ($a -match '^-') { continue }
        if (-not $explicit -and -not $scripts.Count) { $scripts.Add($a) }
    }
    if ($fromFile) { return 'opaque' }
    foreach ($script in $scripts) {
        $addr = '(?:\d+|\$|/(?:[^/\\]|\\.)*/)'
        if ($script -match "(?:^|[;\n{}])\s*(?:$addr(?:\s*,\s*$addr)?)?\s*!?\s*[wW]\s*\S") { return 'write' }
        if ($script -match 's(.)(?:(?!\1)[^\\]|\\.)*\1(?:(?!\1)[^\\]|\\.)*\1[gpIiMm0-9]*w\s*\S') { return 'write' }
        if ($script -match "(?:^|[;\n{}])\s*(?:$addr(?:\s*,\s*$addr)?)?\s*!?\s*e(?:\s|;|$)" -or $script -match 's(.)(?:(?!\1)[^\\]|\\.)*\1(?:(?!\1)[^\\]|\\.)*\1[gpIiMmw0-9]*e') { return 'opaque' }
    }
    return 'read'
}

function Get-RoSegmentProfile([string[]]$InputWords, [bool[]]$Dynamic, [object[]]$Redirects, $Heredoc, [int]$Depth) {
    $result = New-RoProfile 'read' $false
    foreach ($redirect in $Redirects) { Merge-RoProfile $result (New-RoProfile (Get-RoRedirectEffect $redirect)) }
    $ws = [Collections.Generic.List[string]]::new(); $wd = [Collections.Generic.List[bool]]::new()
    for ($k = 0; $k -lt $InputWords.Count; $k++) { $ws.Add($InputWords[$k]); $wd.Add($(if ($k -lt $Dynamic.Count) { $Dynamic[$k] } else { $false })) }
    # Shell keywords and assignments carry no effect of their own.
    while ($ws.Count -and -not $wd[0] -and $ws[0] -in @('if','then','else','elif','fi','do','done','while','until','!','{','}','time','esac','in')) { $ws.RemoveAt(0); $wd.RemoveAt(0) }
    if ($ws.Count -and -not $wd[0] -and $ws[0] -in @('for','case','select','function')) { return $result }
    while ($ws.Count -and $ws[0] -match '^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=') { $ws.RemoveAt(0); $wd.RemoveAt(0) }
    if (-not $ws.Count) { return $result }
    if ($wd[0]) { Merge-RoProfile $result (New-RoProfile 'opaque'); return $result }
    $program = $ws[0]; $name = Get-RoProgramName $program
    $rest = @(if ($ws.Count -gt 1) { $ws.GetRange(1, $ws.Count - 1) })
    $restDyn = @(if ($wd.Count -gt 1) { $wd.GetRange(1, $wd.Count - 1) })
    $trusted = Test-RoTrustedProgramPath $program
    $effect = $null; $printer = $false
    $recurse = {
        param([int]$From)
        $inner = Get-RoSegmentProfile @($rest[$From..($rest.Count - 1)]) @($restDyn[$From..($restDyn.Count - 1)]) @() $Heredoc ($Depth + 1)
        Merge-RoProfile $result $inner
    }
    if ($Depth -gt 6) { Merge-RoProfile $result (New-RoProfile 'opaque'); return $result }

    if ($name -in @('kill','pkill','killall') -and @($rest | Where-Object { $_ -in @('-0','-l','-L','--list') }).Count) { $effect = 'read' }
    elseif ($name -in $script:RoWriteTools -or $name -in $script:RoPsWriters) { $effect = 'write' }
    elseif ($name -in @('env','timeout','nice','nohup','stdbuf','command','builtin','exec','sudo','doas','xargs','ionice','setsid','time')) {
        $k = 0
        switch ($name) {
            'env' {
                while ($k -lt $rest.Count -and ($rest[$k] -match '^-' -or $rest[$k] -match '^[A-Za-z_][A-Za-z0-9_]*=')) {
                    if ($rest[$k] -in @('-u','--unset','-C','--chdir','-S','--split-string')) { if ($rest[$k] -in @('-S','--split-string')) { $effect = 'opaque' }; $k++ }
                    $k++
                }
            }
            'timeout' {
                while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-s','--signal','-k','--kill-after')) { $k++ }; $k++ }
                $k++
            }
            'nice' { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-n','--adjustment')) { $k++ }; $k++ } }
            'ionice' { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-c','-n','-p','-P','-u')) { $k++ }; $k++ } }
            'stdbuf' { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-i','-o','-e')) { $k++ }; $k++ } }
            'command' { if ($rest.Count -and $rest[0] -in @('-v','-V')) { $effect = 'read'; $printer = $true }; while ($k -lt $rest.Count -and $rest[$k] -match '^-') { $k++ } }
            { $_ -in @('sudo','doas') } { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-u','-g','-C','-D','-h','-p','-r','-t','-U')) { $k++ }; $k++ } }
            'xargs' { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { if ($rest[$k] -in @('-n','-I','-P','-d','-L','-E','-s','-a','--max-args','--max-procs','--delimiter','--arg-file','--replace')) { $k++ }; $k++ } }
            default { while ($k -lt $rest.Count -and $rest[$k] -match '^-') { $k++ } }
        }
        if (-not $effect) {
            if ($k -ge $rest.Count) { $effect = 'read'; $printer = ($name -eq 'env') }
            else { & $recurse $k; return $result }
        }
    }
    elseif ($name -in @('bash','sh','zsh','dash','ksh')) {
        $k = 0; $script = $null
        while ($k -lt $rest.Count -and $rest[$k] -match '^[-+]') {
            if ($rest[$k] -match '^-[A-Za-z]*c[A-Za-z]*$') { if ($k + 1 -lt $rest.Count) { $script = $k + 1 }; break }
            if ($rest[$k] -in @('-o','+o','-O','+O','--rcfile','--init-file')) { $k++ }
            $k++
        }
        if ($null -ne $script) {
            if ($restDyn[$script]) { $effect = 'opaque' } else { Merge-RoProfile $result (Get-RoShellProfile $rest[$script] ($Depth + 1)); return $result }
        } elseif ($k -ge $rest.Count -and $null -ne $Heredoc) { Merge-RoProfile $result (Get-RoShellProfile $Heredoc ($Depth + 1)); return $result }
        elseif (@($rest | Where-Object { $_ -match '^-[A-Za-z]*n' }).Count) { $effect = 'read' }
        else { $effect = 'opaque' }
    }
    elseif ($name -in @('pwsh','powershell','pwsh-preview')) {
        $k = 0; $effect = 'opaque'
        while ($k -lt $rest.Count) {
            $a = $rest[$k]; $lower = $a.ToLowerInvariant()
            if ($lower -match '^[-/](?:c|co|com|comm|comma|comman|command)$') {
                $code = if ($k + 1 -lt $rest.Count) { @($rest[($k + 1)..($rest.Count - 1)]) -join ' ' } else { '' }
                if ($code -eq '-') { $code = [string]$Heredoc }
                if (@($restDyn | Select-Object -Skip ($k + 1) | Where-Object { $_ }).Count) { $effect = 'opaque' }
                else { Merge-RoProfile $result (Get-RoPowerShellProfile $code ($Depth + 1)); return $result }
                break
            }
            if ($lower -match '^[-/](?:e|ec|en|enc|enco|encod|encode|encoded|encodedc\w*)$') {
                try { $code = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($rest[$k + 1])) } catch { $effect = 'opaque'; break }
                Merge-RoProfile $result (Get-RoPowerShellProfile $code ($Depth + 1)); return $result
            }
            if ($lower -match '^[-/](?:f|fi|fil|file)$') {
                if ($k + 1 -lt $rest.Count) {
                    $contract = Get-RoScriptContract $rest[$k + 1] @($rest | Select-Object -Skip ($k + 2))
                    if ($contract) { $effect = $contract }
                }
                break
            }
            if ($lower -match '^[-/](?:noprofile|nop|nologo|nol|noninteractive|noni|mta|sta|noprofileloadtime|interactive|i|login|l)$') { $k++; continue }
            if ($lower -match '^[-/](?:executionpolicy|ex|ep|workingdirectory|wd|w|windowstyle|win|outputformat|o|of|inputformat|if|configurationname|settingsfile|version|v)$') { $k += 2; continue }
            if ($lower -match '^[-/]') { $k++; continue }
            # pwsh treats its first positional argument as a script file.
            if ($name -ne 'powershell') { $contract = Get-RoScriptContract $a @($rest | Select-Object -Skip ($k + 1)); if ($contract) { $effect = $contract } }
            else {
                if (@($restDyn | Select-Object -Skip $k | Where-Object { $_ }).Count) { $effect = 'opaque' }
                else { Merge-RoProfile $result (Get-RoPowerShellProfile (@($rest | Select-Object -Skip $k) -join ' ') ($Depth + 1)); return $result }
            }
            break
        }
    }
    elseif ($name -match '^(?:python(?:\d+(?:\.\d+)?)?|py)$') {
        $k = 0; $effect = 'opaque'
        while ($k -lt $rest.Count) {
            $a = $rest[$k]
            if ($a -eq '-c') { if ($k + 1 -lt $rest.Count) { $effect = Get-RoCodeWriteEffect $rest[$k + 1] 'python' }; break }
            if ($a -eq '-m') {
                $module = if ($k + 1 -lt $rest.Count) { $rest[$k + 1] } else { '' }
                $moduleArgs = @($rest | Select-Object -Skip ($k + 2))
                if ($module -in @('json.tool','tokenize','pydoc','platform','sysconfig','site','this')) { $effect = if ($moduleArgs.Count -ge 2 -and $module -eq 'json.tool') { 'write' } else { 'read' } }
                elseif ($module -in @('pip','venv','virtualenv','ensurepip','py_compile','compileall','zipfile','tarfile','http.server')) { $effect = if ($module -eq 'pip' -and $moduleArgs.Count -and $moduleArgs[0] -in @('list','show','freeze','check','--version','help')) { 'read' } else { 'write' } }
                break
            }
            if ($a -eq '-') { if ($null -ne $Heredoc) { $effect = Get-RoCodeWriteEffect $Heredoc 'python' }; break }
            if ($a -in @('-W','-X','-Q')) { $k += 2; continue }
            if ($a -match '^-') { $k++; continue }
            $contract = Get-RoScriptContract $a @($rest | Select-Object -Skip ($k + 1))
            if ($contract) { $effect = $contract }
            break
        }
        if ($k -ge $rest.Count -and $null -ne $Heredoc) { $effect = Get-RoCodeWriteEffect $Heredoc 'python' }
    }
    elseif ($name -in @('node','nodejs','deno','bun')) {
        $index = [Array]::IndexOf([string[]]$rest, '-e'); if ($index -lt 0) { $index = [Array]::IndexOf([string[]]$rest, '--eval') }
        $effect = if ($index -ge 0 -and $index + 1 -lt $rest.Count) { Get-RoCodeWriteEffect $rest[$index + 1] 'node' } else { 'opaque' }
    }
    elseif ($name -in @('perl','ruby')) { $effect = if (@($rest | Where-Object { $_ -match '^-[A-Za-z]*i' }).Count) { 'write' } else { 'opaque' } }
    elseif ($name -eq 'git' -and $trusted) { $effect = Get-RoGitEffect @($ws); $printer = $effect -eq 'read' }
    elseif ($name -eq 'git') { $effect = Get-RoGitEffect @($ws); if ($effect -eq 'read') { $effect = 'opaque' } }
    elseif (-not $trusted) {
        # A project executable named like an OS tool is not that tool; only bound
        # repository contracts and mutation names classify it.
        $effect = Get-RoScriptContract $program $rest
        if (-not $effect) { $effect = 'opaque' }
    }
    elseif ($name -in @('npm','pnpm','yarn','pip','pip3','uv','cargo','go','gem','apt','apt-get','brew','winget','choco','toolbox','dotnet','make','cmake')) {
        $sub = @($rest | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1)
        $effect = if ($sub.Count -and $sub[0] -in @('install','i','ci','add','uninstall','remove','rm','update','upgrade','link','unlink','publish','init','new','build','sync','restore','pack','apt')) { 'write' } else { 'opaque' }
    }
    elseif ($name -eq 'sed') { $effect = Get-RoSedEffect $rest; $printer = $true }
    elseif ($name -in @('awk','gawk','mawk','nawk')) {
        $k = 0; $awkProgram = $null; $fromFile = $false
        while ($k -lt $rest.Count -and $rest[$k] -match '^-') {
            if ($rest[$k] -in @('-i','--include') -and $k + 1 -lt $rest.Count -and $rest[$k + 1] -match 'inplace') { $effect = 'write' }
            if ($rest[$k] -in @('-f','--file')) { $fromFile = $true }
            if ($rest[$k] -in @('-F','-v','-f','-i','--include','--file','--assign','--field-separator')) { $k++ }
            $k++
        }
        if (-not $effect) {
            if ($fromFile) { $effect = 'opaque' }
            elseif ($k -lt $rest.Count) {
                $awkProgram = $rest[$k]
                if ($awkProgram -match '\bprintf?\b[^;{}]*?(?<![<>=!])>{1,2}\s*[^=\s]') { $effect = 'write' }
                elseif ($awkProgram -match '\bsystem\s*\(|\|\s*"|\|&') { $effect = 'opaque' }
                else { $effect = 'read'; $printer = $true }
            } else { $effect = 'opaque' }
        }
    }
    elseif ($name -eq 'sort') {
        $effect = 'read'; $printer = $true
        foreach ($a in $rest) {
            if ($a -match '^--output(?:=|$)') { $effect = 'write'; break }
            if ($a -match '^-[A-Za-z]+$' -and $a -notmatch '^--') {
                foreach ($ch in $a.Substring(1).ToCharArray()) { if ($ch -eq 'o') { $effect = 'write'; break }; if ($ch -in @([char]'k',[char]'t',[char]'S',[char]'T')) { break } }
            }
        }
    }
    elseif ($name -eq 'uniq') {
        $positional = [Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $rest.Count; $k++) {
            if ($rest[$k] -in @('-f','-s','-w','--skip-fields','--skip-chars','--check-chars')) { $k++; continue }
            if ($rest[$k] -match '^-.') { continue }
            $positional.Add($rest[$k])
        }
        $effect = if ($positional.Count -ge 2 -and $positional[1] -notin @('-','/dev/stdout','/dev/null')) { 'write' } else { 'read' }; $printer = $true
    }
    elseif ($name -eq 'tee') {
        $targets = @($rest | Where-Object { $_ -notmatch '^-' -and $_.ToLowerInvariant() -notin $script:RoHarmlessTargets })
        $effect = if ($targets.Count) { 'write' } else { 'read' }; $printer = $true
    }
    elseif ($name -eq 'find') {
        $effect = 'read'; $printer = $true
        for ($k = 0; $k -lt $rest.Count; $k++) {
            if ($rest[$k] -in @('-delete','-fprint','-fprint0','-fprintf','-fls')) { $effect = 'write'; break }
            if ($rest[$k] -in @('-exec','-execdir','-ok','-okdir')) {
                $end = $k + 1; while ($end -lt $rest.Count -and $rest[$end] -notin @(';','+')) { $end++ }
                if ($end -gt $k + 1) {
                    $inner = Get-RoSegmentProfile @($rest[($k + 1)..($end - 1)]) @($restDyn[($k + 1)..($end - 1)]) @() $null ($Depth + 1)
                    if ($inner.effect -eq 'write') { $effect = 'write'; break }
                    if ($inner.effect -eq 'opaque') { $effect = 'opaque' }
                } else { $effect = 'opaque' }
                $k = $end
            }
        }
    }
    elseif ($name -eq 'fd') { $effect = if (@($rest | Where-Object { $_ -match '^(?:-x|-X|--exec|--exec-batch)' }).Count) { 'opaque' } else { 'read' }; $printer = $true }
    elseif ($name -in @('rg','grep','egrep','fgrep')) { $effect = if (@($rest | Where-Object { $_ -match '^--(?:pre|hostname-bin)(?:=|$)' }).Count) { 'opaque' } else { 'read' }; $printer = $true }
    elseif ($name -eq 'date') { $effect = if (@($rest | Where-Object { $_ -match '^(?:-s|--set)' }).Count) { 'write' } else { 'read' }; $printer = $true }
    elseif ($name -eq 'hostname') { $effect = if (@($rest | Where-Object { $_ -notmatch '^-' }).Count) { 'write' } else { 'read' }; $printer = $true }
    elseif ($name -eq 'tree') { $effect = if (@($rest | Where-Object { $_ -eq '-o' }).Count) { 'write' } else { 'read' }; $printer = $true }
    elseif ($name -eq 'xxd') { $effect = if (@($rest | Where-Object { $_ -notmatch '^-' }).Count -ge 2) { 'write' } else { 'read' }; $printer = $true }
    elseif ($name -eq 'systemctl') {
        $verb = @($rest | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1)
        $effect = if (-not $verb.Count -or $verb[0] -match '^(?:status|show|cat|help|list-.*|is-.*)$') { 'read' } else { 'write' }; $printer = $true
    }
    elseif ($name -eq 'journalctl') { $effect = if (@($rest | Where-Object { $_ -match '^--(?:vacuum|rotate|flush|sync|relinquish|setup-keys|update-catalog)' }).Count) { 'write' } else { 'read' }; $printer = $true }
    elseif ($name -in @('tar','bsdtar')) {
        $mode = @($rest | Select-Object -First 1)
        $effect = if (@($rest | Where-Object { $_ -match '^--(?:create|extract|get|append|update|delete)$' }).Count -or ($mode.Count -and $mode[0] -match '^-?[A-Za-z]*[cxru]')) { 'write' } elseif ($mode.Count -and $mode[0] -match '^-?[A-Za-z]*t') { 'read' } else { 'opaque' }
    }
    elseif ($name -in @('unzip')) { $effect = if (@($rest | Where-Object { $_ -match '^-[A-Za-z]*[lptvZ]' }).Count) { 'read' } else { 'write' } }
    elseif ($name -in @('zip','gzip','gunzip','bzip2','bunzip2','xz','unxz','zstd','unzstd')) { $effect = if (@($rest | Where-Object { $_ -match '^-[A-Za-z]*[ctl]' -or $_ -in @('--stdout','--to-stdout','--test','--list') }).Count) { 'read' } else { 'write' } }
    elseif ($name -eq 'mktemp') { $effect = if (@($rest | Where-Object { $_ -match '^(?:-u|--dry-run)$' }).Count) { 'read' } else { 'write' } }
    elseif ($name -eq 'patch') { $effect = if (@($rest | Where-Object { $_ -eq '--dry-run' }).Count) { 'read' } else { 'write' } }
    elseif ($name -eq 'dd') { $effect = if (@($rest | Where-Object { $_ -match '^of=' -and $_ -notmatch '^of=/dev/(?:null|stdout|stderr)$' }).Count) { 'write' } else { 'opaque' } }
    elseif ($name -eq 'curl') { $effect = if (@($rest | Where-Object { $_ -match '^(?:-[A-Za-z]*[oODc]|--output|--remote-name|--dump-header|--cookie-jar|--create-dirs)' }).Count) { 'write' } else { 'opaque' } }
    elseif ($name -eq 'wget') { $effect = if (@($rest | Where-Object { $_ -match '^(?:-O-|-qO-|--spider|--output-document=-)$' }).Count -or (([Array]::IndexOf([string[]]$rest, '-O')) -ge 0 -and $rest[[Array]::IndexOf([string[]]$rest, '-O') + 1] -eq '-')) { 'opaque' } else { 'write' } }
    elseif ($name -in @('eval')) { $effect = if (@($restDyn | Where-Object { $_ }).Count) { 'opaque' } else { $inner = Get-RoShellProfile ($rest -join ' ') ($Depth + 1); Merge-RoProfile $result $inner; return $result } }
    elseif ($name -in @('source','.')) { $effect = 'opaque' }
    elseif ($name -in $script:RoPrinterTools) { $effect = 'read'; $printer = $true }
    elseif ($name -in $script:RoQuietReads) { $effect = 'read' }
    elseif ($name -in $script:RoPsReaders) { $effect = 'read'; $printer = $true }
    else { $effect = 'opaque' }

    Merge-RoProfile $result (New-RoProfile $effect $printer)
    return $result
}

function Get-RoShellProfile([string]$Text, [int]$Depth = 0) {
    if ($Depth -gt 6) { return (New-RoProfile 'opaque') }
    $parsed = Split-RoShellScript $Text
    $result = New-RoProfile 'read' $false
    foreach ($sub in $parsed.subs) { Merge-RoProfile $result (Get-RoShellProfile $sub ($Depth + 1)) }
    foreach ($segment in $parsed.segments) {
        Merge-RoProfile $result (Get-RoSegmentProfile @($segment.words) @($segment.dynamic) @($segment.redirects) $segment.heredoc $Depth)
    }
    if ($parsed.error -and $result.effect -ne 'write') { $result.effect = 'opaque' }
    if (-not $parsed.segments.Count -and -not $parsed.subs.Count -and $result.effect -eq 'read') { $result.effect = 'opaque' }
    return $result
}

function Get-RoPowerShellProfile([string]$Script, [int]$Depth = 0) {
    # PowerShell's own parser supplies commands, redirections and member calls.
    $result = New-RoProfile 'read' $false
    if ($Depth -gt 6) { return (New-RoProfile 'opaque') }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return (New-RoProfile 'opaque') }
    foreach ($redirect in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
        $location = $redirect.Location
        $harmless = ($location -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $location.Value.ToLowerInvariant() -in $script:RoHarmlessTargets) -or
            ($location -is [System.Management.Automation.Language.VariableExpressionAst] -and $location.VariablePath.UserPath -eq 'null')
        Merge-RoProfile $result (New-RoProfile $(if ($harmless) { 'read' } else { 'write' }))
    }
    foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $member = if ($call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $call.Member.Value } else { '' }
        $type = if ($call.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $call.Expression.TypeName.FullName } else { '' }
        if ($call.Static -and $type -match '(?i)^(?:System\.)?IO\.(?:File|Directory)$') {
            if ($member -match '(?i)^(?:Write|Append|Create|Delete|Move|Copy|Replace|Set|Encrypt|Decrypt|OpenWrite)') { Merge-RoProfile $result (New-RoProfile 'write') }
            elseif ($member -match '(?i)^Open$') { Merge-RoProfile $result (New-RoProfile 'opaque') }
        } elseif (-not $call.Static -and $member -match '(?i)^(?:WriteAllText|WriteAllBytes|WriteAllLines|AppendAllText|Delete|MoveTo|Create|CreateText|AppendText|OpenWrite|Save)$') {
            Merge-RoProfile $result (New-RoProfile 'write')
        }
    }
    foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $first = $command.CommandElements[0]
        if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue } # contents are visited
        $name = $command.GetCommandName()
        if (-not $name) { Merge-RoProfile $result (New-RoProfile 'opaque'); continue }
        $words = [Collections.Generic.List[string]]::new(); $dyn = [Collections.Generic.List[bool]]::new()
        $words.Add($name); $dyn.Add($false)
        for ($k = 1; $k -lt $command.CommandElements.Count; $k++) {
            $element = $command.CommandElements[$k]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $words.Add('-' + $element.ParameterName); $dyn.Add($false)
                if ($element.Argument) { $words.Add('?'); $dyn.Add($true) }
            } elseif ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $words.Add($element.Value); $dyn.Add($false) }
            elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $words.Add($element.Value); $dyn.Add($true) }
            elseif ($element -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $words.Add('{}'); $dyn.Add($false) }
            else { $words.Add($element.Extent.Text); $dyn.Add($true) }
        }
        $lower = $name.ToLowerInvariant()
        $canonical = if ($script:RoPsAliases.ContainsKey($lower)) { $script:RoPsAliases[$lower] } else { $lower }
        # On Linux/macOS, Unix names such as rm, sort or tee run the native tool; on
        # Windows they are cmdlet aliases. Either reading's write intent counts.
        $native = if ($lower -notmatch '^[a-z]+-[a-z]+$') { Get-RoSegmentProfile @($words) @($dyn) @() $null ($Depth + 1) } else { $null }
        if ($native -and $native.effect -eq 'write') { Merge-RoProfile $result $native; continue }
        if ($canonical -eq 'tee-object') {
            $toFile = @($words | Where-Object { $_ -match '(?i)^-(?:f|fi|fil|file|filep|filepa|filepat|filepath|path|literalpath|lp|pspath|append)$' }).Count -or
                @($words | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' }).Count
            Merge-RoProfile $result (New-RoProfile $(if ($toFile) { 'write' } else { 'read' }) $true); continue
        }
        if ($canonical -in $script:RoPsWriters) { Merge-RoProfile $result (New-RoProfile 'write'); continue }
        if ($canonical -eq 'invoke-expression') {
            $arg = @($command.CommandElements | Select-Object -Skip 1)
            if ($arg.Count -eq 1 -and $arg[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { Merge-RoProfile $result (Get-RoPowerShellProfile $arg[0].Value ($Depth + 1)) }
            else { Merge-RoProfile $result (New-RoProfile 'opaque') }
            continue
        }
        if ($canonical -in @('start-process','new-object','add-type','invoke-webrequest','invoke-restmethod','import-module','set-alias','new-alias','invoke-command','start-job','start-threadjob')) {
            $writer = $canonical -eq 'new-object' -and @($words | Where-Object { $_ -match '(?i)StreamWriter|FileStream|BinaryWriter' }).Count
            $download = $canonical -in @('invoke-webrequest','invoke-restmethod') -and @($words | Where-Object { $_ -match '(?i)^-(?:outfile|of)$' }).Count
            Merge-RoProfile $result (New-RoProfile $(if ($writer -or $download) { 'write' } else { 'opaque' })); continue
        }
        if ($canonical -in $script:RoPsReaders) {
            Merge-RoProfile $result (New-RoProfile 'read' ($canonical -notin @('set-location','push-location','pop-location','set-variable','new-variable','set-strictmode','out-null'))); continue
        }
        $contract = Get-RoScriptContract $name @($words | Select-Object -Skip 1)
        if ($contract) { Merge-RoProfile $result (New-RoProfile $contract); continue }
        if ($lower -match '^[a-z]+-[a-z]+$' -or $lower -match '\.ps1$') { Merge-RoProfile $result (New-RoProfile 'opaque'); continue } # unknown cmdlet or script
        Merge-RoProfile $result $native
    }
    return $result
}

function Get-ReadOnlyCommandProfile([string]$Command) {
    # Codex reports the argv as one POSIX-quoted string (the same form on Windows,
    # where pwsh paths are double-quoted with escaped backslashes).
    try { return (Get-RoShellProfile $Command 0) } catch { return (New-RoProfile 'opaque') }
}

function Get-ReadOnlyCommandEffect([string]$Command) { (Get-ReadOnlyCommandProfile $Command).effect }

function Get-ReadOnlyWorkerEvidence {
    # Parse only the CLI's structured stdout frames, never the final message or stderr.
    param([string]$Stream)
    $started = $false; $turnStarted = $false; $completed = $false; $failed = $false; $terminal = $false; $valid = $true
    $threadId = $null; $usage = $null
    $pending = @{}; $finished = @{}; $profiles = @{}
    $writes = [Collections.Generic.List[string]]::new(); $seenWrites = [Collections.Generic.HashSet[string]]::new()
    $opaque = [Collections.Generic.List[string]]::new(); $errors = [Collections.Generic.List[string]]::new()
    $addWrite = { param([string]$Value) if ($seenWrites.Add($Value)) { $writes.Add($Value) } }
    foreach ($line in ($Stream -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $valid = $false; continue }
        if ($event -isnot [Collections.IDictionary] -or -not $event.Contains('type') -or $event['type'] -isnot [string]) { $valid = $false; continue }
        if ($terminal) { $valid = $false }
        switch ($event.type) {
            'thread.started' {
                if ($started -or $event['thread_id'] -isnot [string] -or [string]::IsNullOrWhiteSpace($event['thread_id'])) { $valid = $false } else { $threadId = $event['thread_id'] }
                $started = $true
            }
            'turn.started' { if (-not $started -or $turnStarted) { $valid = $false }; $turnStarted = $true }
            'turn.completed' {
                if (-not $turnStarted -or $pending.Count) { $valid = $false }
                $completed = $true; $terminal = $true
                if ($event.Contains('usage') -and $event['usage'] -is [Collections.IDictionary]) { $usage = $event['usage'] }
            }
            'turn.failed' {
                # The turn's own terminal failure is not recoverable evidence.
                $failed = $true; $terminal = $true
                $message = if ($event['error'] -is [Collections.IDictionary]) { $event['error']['message'] } else { $null }
                if ($message -is [string] -and $message) { $errors.Add($message) }
            }
            'error' {
                # A top-level error is a CLI notification (reconnects report one too).
                # Only the terminal frame decides the turn; writes seen before or after remain.
                if ($event['message'] -isnot [string]) { $valid = $false } else { $errors.Add($event['message']) }
            }
            { $_ -in @('item.started','item.updated','item.completed') } {
                $item = $event['item']
                if (-not $turnStarted) { $valid = $false }
                if ($item -isnot [Collections.IDictionary] -or $item['id'] -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($item['id']) -or $item['type'] -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($item['type'])) { $valid = $false; continue }
                if ($finished.ContainsKey($item.id)) { $valid = $false }
                if ($event.type -eq 'item.completed') { $pending.Remove($item.id); $finished[$item.id] = $true } else { $pending[$item.id] = $true }
                if ($item.type -eq 'file_change') { & $addWrite "file_change:$($item.id)" }
                elseif ($item.type -eq 'command_execution') {
                    if ($item['command'] -isnot [string]) { $valid = $false; continue }
                    $command = [string]$item.command
                    if (-not $profiles.ContainsKey($item.id)) {
                        $profiles[$item.id] = Get-ReadOnlyCommandProfile $command
                        if ($profiles[$item.id].effect -eq 'opaque' -and -not $opaque.Contains($command)) { $opaque.Add($command) }
                    }
                    $commandProfile = $profiles[$item.id]
                    if ($commandProfile.effect -eq 'write') { & $addWrite $command }
                    if ($event.type -eq 'item.completed') {
                        $status = if ($item.Contains('status')) { $item['status'] } else { $null }
                        if ($null -ne $status -and $status -notin @('completed','failed','declined')) { $valid = $false; continue }
                        if (-not $item.Contains('aggregated_output') -or -not $item.Contains('exit_code')) { $valid = $false; continue }
                        $exit = $item['exit_code']
                        if ($null -eq $exit -and $status -notin @('failed','declined')) { $valid = $false; continue }
                        if ($null -ne $exit -and $exit -isnot [int] -and $exit -isnot [long]) { $valid = $false; continue }
                        $output = [string]$item['aggregated_output']
                        # A read-only-file-system denial is positive write evidence, but only
                        # from a command that does not print file or data content.
                        if ($commandProfile.effect -ne 'write' -and -not $commandProfile.printer -and
                            ($status -eq 'failed' -or ($null -ne $exit -and $exit -ne 0)) -and
                            $output -match '(?i)read-only file system|\bEROFS\b|os error 30\b') { & $addWrite "denied-write:$command" }
                    }
                }
                elseif ($item.type -notin @('agent_message','reasoning','todo_list','web_search','error')) {
                    # 'error' items are CLI warnings. Unknown tools (MCP, collaboration,
                    # future types) may have effects this adapter cannot attribute.
                    $valid = $false
                }
            }
            default { $valid = $false }
        }
    }
    [pscustomobject]@{
        complete = ($valid -and $started -and $turnStarted -and $completed -and -not $failed -and $pending.Count -eq 0)
        writes = @($writes.ToArray())
        opaque_commands = @($opaque.ToArray())
        recovered_errors = $(if ($completed -and -not $failed) { $errors.Count } else { 0 })
        turn_failed = $failed
        thread_id = $threadId
        usage = $usage
        cli_errors = @($errors.ToArray())
    }
}

function Get-ReadOnlyCliErrorText([object]$Evidence) {
    # Trusted CLI error frames, rendered in the stderr "ERROR: ..." form the existing
    # limit, input-size and capacity classifiers read. Never model text.
    if (-not $Evidence) { return '' }
    (@($Evidence.cli_errors) | ForEach-Object { 'ERROR: ' + (([string]$_) -replace '\s*\r?\n\s*', ' ') }) -join "`n"
}
