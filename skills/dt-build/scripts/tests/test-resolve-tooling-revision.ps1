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
