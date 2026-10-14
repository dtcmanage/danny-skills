param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}
function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = @(& git -C $fixture @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $($output -join ' ')" }
    return ($output -join "`n").Trim()
}
function Resolve-Fixture {
    param([string]$File = $tool, [string[]]$Extra = @(), [int]$ExpectedExit = 0)
    $output = @(& pwsh -NoProfile -File $resolver -Path $File -RepoRoot $fixture -Json @Extra 2> $errorLog)
    Assert-True ($LASTEXITCODE -eq $ExpectedExit) "resolver exit should be $ExpectedExit; stderr: $(Get-Content $errorLog -Raw)"
    if ($ExpectedExit -eq 2) { return }
    return ($output -join "`n") | ConvertFrom-Json
}

$scriptDir = Split-Path -Parent $PSScriptRoot
$resolver = Join-Path $scriptDir 'resolve-tooling-revision.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tooling-revision-tests-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $tempRoot 'repo'
$errorLog = Join-Path $tempRoot 'stderr.log'
$relative = 'skills/dt-build/scripts/tool.ps1'
$tool = Join-Path $fixture $relative
New-Item -ItemType Directory -Path (Split-Path -Parent $tool) -Force | Out-Null
try {
    $null = Invoke-FixtureGit @('init', '-b', 'main')
    $null = Invoke-FixtureGit @('config', 'user.name', 'Fixture')
    $null = Invoke-FixtureGit @('config', 'user.email', 'fixture@example.invalid')
    $null = Invoke-FixtureGit @('config', 'core.autocrlf', 'false')
    Write-Utf8 (Join-Path $fixture '.gitattributes') '*.ps1 text eol=lf'
    Write-Utf8 $tool "first`n"
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('commit', '-m', 'first revision')
    $first = Invoke-FixtureGit @('rev-parse', 'HEAD')
    Write-Utf8 $tool "second`n"
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('commit', '-m', 'second revision')
    $second = Invoke-FixtureGit @('rev-parse', 'HEAD')
    # A later unrelated commit proves is_ref_head describes bytes, not commit equality.
    Write-Utf8 (Join-Path $fixture 'other.txt') 'unrelated'
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('commit', '-m', 'unrelated head')
    $head = Invoke-FixtureGit @('rev-parse', 'HEAD')
    $null = Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $head)
    $result = Resolve-Fixture
    Assert-True ($result.status -eq 'ON_MAIN' -and $result.commit -eq $second -and $result.is_ref_head) 'second revision resolves at ref head'
    Assert-True ($result.ref_head -eq $head -and $result.commit -ne $head) 'head bytes can match an earlier commit'
    Assert-True ($result.bytes -eq 7 -and $result.sha256 -eq (Get-FileHash $tool -Algorithm SHA256).Hash.ToLowerInvariant()) 'size and SHA256 match exact bytes'
    Assert-True ($result.blob_id -eq (Invoke-FixtureGit @('hash-object', '--no-filters', $tool))) 'blob matches no-filters hash'
    $date = [DateTimeOffset]::Parse((Invoke-FixtureGit @('show', '-s', '--format=%cI', $second)))
    $expectedDate = [TimeZoneInfo]::ConvertTime($date, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Assert-True ($result.commit_date -eq $expectedDate) 'commit date is Eastern with an explicit offset'
    Write-Utf8 $tool "first`n"
    $result = Resolve-Fixture
    Assert-True ($result.status -eq 'ON_MAIN' -and $result.commit -eq $first -and -not $result.is_ref_head) 'historical first revision resolves'
    Write-Utf8 $tool "local edit`n"
    $result = Resolve-Fixture -ExpectedExit 3
    Assert-True ($result.status -eq 'NOT_ON_MAIN' -and $null -eq $result.commit -and $null -eq $result.commit_date -and -not $result.is_ref_head) 'local edits have no provenance'
    & git -C $fixture cat-file -e $result.blob_id 2> $null
    Assert-True ($LASTEXITCODE -ne 0) 'hash-object does not write the local edit into the object database'
    Write-Utf8 $tool "second`r`n"
    $result = Resolve-Fixture -ExpectedExit 3
    Assert-True ($result.status -eq 'NOT_ON_MAIN' -and $result.bytes -eq 8) 'CRLF does not match committed LF despite attributes'
    Resolve-Fixture -File (Join-Path $fixture 'missing.ps1') -ExpectedExit 2
    Assert-True ((Get-Content $errorLog -Raw) -match 'resolve-tooling-revision:.*missing.ps1') 'missing file has a clear diagnostic'
    $external = Join-Path $tempRoot 'renamed-tool.txt'
    Write-Utf8 $external "second`n"
    Resolve-Fixture -File $external -ExpectedExit 2
    $result = Resolve-Fixture -File $external -Extra @('-RepoRelativePath', $relative)
    Assert-True ($result.commit -eq $second) 'explicit path supports arbitrary tooling files'
    $installed = Join-Path $tempRoot 'installed/dt-build/scripts/tool.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $installed) -Force | Out-Null
    Write-Utf8 $installed "second`n"
    $result = Resolve-Fixture -File $installed
    Assert-True ($result.repo_relative_path -eq $relative -and $result.commit -eq $second) 'installed skill copy infers path'
    $result = Resolve-Fixture -Extra @('-Ref', 'missing-ref') -ExpectedExit 2
    # Repeated bytes resolve to the newest matching commit.
    Write-Utf8 $tool "first`n"
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('commit', '-m', 'revert to first bytes')
    $revert = Invoke-FixtureGit @('rev-parse', 'HEAD')
    $null = Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $revert)
    $result = Resolve-Fixture
    Assert-True ($result.commit -eq $revert -and $result.is_ref_head) 'newest matching revision wins'
    $before = Invoke-FixtureGit @('status', '--porcelain')
    $result = Resolve-Fixture
    Assert-True ((Invoke-FixtureGit @('status', '--porcelain')) -eq $before) 'resolver does not change the fixture'

    # Arbitrary workspace guide in the non-default fixture repo infers its relative path.
    $guide = Join-Path $fixture 'Resources/ops-conventions.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $guide) -Force | Out-Null
    Write-Utf8 $guide "workspace guide`n"
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('commit', '-m', 'workspace guide')
    $guideHead = Invoke-FixtureGit @('rev-parse', 'HEAD')
    $null = Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $guideHead)
    $result = Resolve-Fixture -File $guide
    Assert-True ($result.status -eq 'ON_MAIN' -and $result.repo_relative_path -eq 'Resources/ops-conventions.md') 'workspace RepoRoot infers guide path'
    Assert-True ($result.repo_root -eq $fixture -and $result.ref -eq 'origin/main' -and $result.ref_head -eq $guideHead -and $result.ref_commit_date) 'workspace ref snapshot includes repo, head and commit time'

    $pin = Join-Path $tempRoot 'pinned.txt'
    $runtime = Join-Path $tempRoot 'known_hosts'
    $protected = '192.168.71.29 ssh-ed25519 ABCDEFGHIJKLMNOP-secret-key-material'
    $other = 'other-host ssh-ed25519 another-secret-key-material'
    $base = "$protected`n"
    $cases = @(
        @{ name = 'unchanged'; pin = $base; current = $base; status = 'UNCHANGED'; count = 0 },
        @{ name = 'pure append'; pin = $base; current = "$base$other`n"; status = 'APPEND_ONLY'; count = 1 },
        @{ name = 'protected duplicate append'; pin = $base; current = "$base$protected`n"; status = 'CHANGED'; count = 1; added = 1 },
        @{ name = 'protected new key append'; pin = $base; current = "$base$($protected.Replace('ABCDEFGHIJKLMNOP', 'different-key'))`n"; status = 'CHANGED'; count = 1; added = 1 },
        @{ name = 'protected edit'; pin = $base; current = "$($protected.Replace('ABCDEFGHIJKLMNOP', 'different-key'))`n"; status = 'CHANGED'; count = 0; removed = 1; added = 1 },
        @{ name = 'protected removal'; pin = $base; current = ''; status = 'CHANGED'; count = 0; removed = 1 },
        @{ name = 'LF to CRLF'; pin = $base; current = "$protected`r`n"; status = 'CHANGED'; count = 0 },
        @{ name = 'CRLF to LF'; pin = "$protected`r`n"; current = $base; status = 'CHANGED'; count = 0 },
        @{ name = 'CRLF append'; pin = "$protected`r`n"; current = "$protected`r`n$other`r`n"; status = 'APPEND_ONLY'; count = 1 },
        @{ name = 'missing newline then LF append'; pin = $protected; current = "$base$other`n"; status = 'APPEND_ONLY'; count = 1 },
        @{ name = 'missing newline then CRLF append'; pin = $protected; current = "$protected`r`n$other`r`n"; status = 'APPEND_ONLY'; count = 1 },
        @{ name = 'newline only'; pin = $protected; current = $base; status = 'APPEND_ONLY'; count = 0 },
        @{ name = 'partial row extension'; pin = $protected; current = "$protected-extension`n"; status = 'CHANGED'; count = 0 },
        @{ name = 'case-sensitive protected edit'; pin = $base; current = "$($protected.ToUpperInvariant())`n"; status = 'CHANGED'; count = 0 },
        @{ name = 'empty baseline'; pin = ''; current = "$other`n"; status = 'APPEND_ONLY'; count = 1 },
        @{ name = 'literal trailing CR remains protected'; pin = "$protected`r"; current = "$protected`r`n$other`n"; status = 'CHANGED'; count = 1; removed = 1; added = 1 },
        @{ name = 'unprotected edit'; pin = "$base$other`n"; current = "$base$($other.Replace('another', 'changed'))`n"; status = 'CHANGED'; count = 0 }
    )
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($case in $cases) {
        try {
            Write-Utf8 $pin $case.pin
            Write-Utf8 $runtime $case.current
            $hash = (Get-FileHash $pin -Algorithm SHA256).Hash
            $exitCode = if ($case.status -eq 'CHANGED') { 3 } else { 0 }
            $result = Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedCopyPath', $pin, '-ProtectedPattern', '^192\.168\.71\.29 ') -ExpectedExit $exitCode
            Assert-True ($result.status -eq $case.status -and $result.appended_line_count -eq $case.count) $case.name
            if ($case.ContainsKey('removed')) { Assert-True ($result.protected_removed.Count -eq $case.removed) "$($case.name) removed rows" }
            if ($case.ContainsKey('added')) { Assert-True ($result.protected_added.Count -eq $case.added) "$($case.name) added rows" }
            if ($case.name -eq 'pure append') { Assert-True ($result.appended_hosts[0] -eq 'other-host') 'audit records appended first token' }
            $serialized = $result | ConvertTo-Json -Depth 8
            Assert-True ($serialized -notmatch 'secret-key-material|ABCDEFGHIJKLMNOP') "$($case.name) audit excludes key material"
        } catch { $failures.Add("$($case.name): $($_.Exception.Message)") }
    }
    # A full saved line file can prove the prefix; selected rows cannot.
    Write-Utf8 $pin $base
    Write-Utf8 $runtime "$base$other`n"
    $hash = (Get-FileHash $pin -Algorithm SHA256).Hash
    $result = Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedLines', $pin, '-ProtectedPattern', '^192\.168\.71\.29 ')
    Assert-True ($result.status -eq 'APPEND_ONLY') 'complete pinned lines prove the byte prefix'
    Write-Utf8 $pin "$base$other`n"
    $hash = (Get-FileHash $pin -Algorithm SHA256).Hash
    Write-Utf8 $pin $base
    Write-Utf8 $runtime "$base$other`nnew-host key secret`n"
    $result = Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedLines', $pin, '-ProtectedPattern', '^192\.168\.71\.29 ') -ExpectedExit 3
    Assert-True ($result.reason -eq 'pinned_lines_do_not_prove_full_byte_prefix') 'selected rows fail closed for missing full-prefix proof'
    Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedCopyPath', $pin, '-ProtectedPattern', '^192') -ExpectedExit 2
    Assert-True ((Get-Content $errorLog -Raw) -match 'does not match') 'corrupt saved copy rejected'
    $hash = (Get-FileHash $pin -Algorithm SHA256).Hash
    Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedCopyPath', $pin, '-ProtectedPattern', '[') -ExpectedExit 2
    Resolve-Fixture -File $runtime -Extra @('-PinnedSha256', $hash, '-PinnedCopyPath', $pin) -ExpectedExit 2
    $arrayHarness = Join-Path $tempRoot 'multiple-patterns.ps1'
    Write-Utf8 $pin "$base$other`n"
    $hash = (Get-FileHash $pin -Algorithm SHA256).Hash
    Write-Utf8 $runtime "$base$other`n$other`n"
    Write-Utf8 $arrayHarness @'
param($Resolver, $Runtime, $Pin, $Hash)
& $Resolver -Path $Runtime -PinnedSha256 $Hash -PinnedCopyPath $Pin -ProtectedPattern @('^192\.168\.71\.29 ', '^other-host ') -Json
exit $LASTEXITCODE
'@
    $raw = @(& pwsh -NoProfile -File $arrayHarness $resolver $runtime $pin $hash)
    Assert-True ($LASTEXITCODE -eq 3) 'multiple patterns reject added rows for the second host'
    $result = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($result.protected_added.Count -eq 1 -and $result.protected_added[0].host -eq 'other-host') 'second pattern identifies protected addition'
    if ($failures.Count) { throw ($failures -join "`n") }

    $liveRaw = @(& pwsh -NoProfile -File $resolver -Path (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -Json)
    Assert-True ($LASTEXITCODE -eq 0) 'live wrapper exits zero with default repo and ref'
    $live = ($liveRaw -join "`n") | ConvertFrom-Json
    Assert-True ($live.status -eq 'ON_MAIN' -and $live.repo_relative_path -eq 'skills/dt-build/scripts/invoke-codex-chunk.ps1') 'live wrapper resolves ON_MAIN'
    $junction = Join-Path $tempRoot 'junction/dt-build'
    New-Item -ItemType Directory -Path (Split-Path -Parent $junction) -Force | Out-Null
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $junction -Target (Split-Path -Parent $scriptDir) | Out-Null
    try {
        $junctionRaw = @(& pwsh -NoProfile -File (Join-Path $junction 'scripts/resolve-tooling-revision.ps1') -Path (Join-Path $junction 'scripts/invoke-codex-chunk.ps1') -Json)
        Assert-True ($LASTEXITCODE -eq 0) 'helper resolves default repo through a skill junction'
        $junctionResult = ($junctionRaw -join "`n") | ConvertFrom-Json
        Assert-True ($junctionResult.commit -eq $live.commit) 'junction and source resolve the same live commit'
    } finally {
        # Unlink only; never recursively remove a junction target.
        (Get-Item -LiteralPath $junction).Delete()
    }
    Write-Output "LIVE: $($live | ConvertTo-Json -Compress)"
    Write-Output 'PASS: tooling revision resolver'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
