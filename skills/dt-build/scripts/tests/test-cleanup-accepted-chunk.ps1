param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cleanup = Join-Path (Split-Path -Parent $PSScriptRoot) 'cleanup-accepted-chunk.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('accepted-chunk-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$passed = 0
$failures = @()

function Invoke-FixtureGit([string[]]$Arguments) {
    & git -C $repo @Arguments *> $null
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $Arguments" }
}
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Push-Location $tempRoot
try {
    foreach ($case in @('merged', 'no-worktree', 'unmerged', 'untracked', 'modified', 'staged', 'main', 'master', 'qualified-main', 'wrong-path', 'same-branch', 'leftover')) {
        try {
            $repo = Join-Path $tempRoot "$case-repo"
            $worktree = Join-Path $tempRoot "$case chunk space"
            New-Item -ItemType Directory -Path $repo | Out-Null
            Invoke-FixtureGit @('init', '-b', 'main')
            Invoke-FixtureGit @('config', 'user.email', 'fixture@example.invalid')
            Invoke-FixtureGit @('config', 'user.name', 'Cleanup Fixture')
            Invoke-FixtureGit @('config', 'commit.gpgsign', 'false')
            Set-Content -LiteralPath (Join-Path $repo 'base.txt') -Value 'base'
            Invoke-FixtureGit @('add', '.')
            Invoke-FixtureGit @('commit', '-m', 'base')
            Invoke-FixtureGit @('branch', 'build/test')
            Invoke-FixtureGit @('worktree', 'add', '-b', 'dt-build/test/chunk', $worktree)
            Set-Content -LiteralPath (Join-Path $worktree 'chunk.txt') -Value 'chunk'
            Invoke-FixtureGit @('-C', $worktree, 'add', '.')
            Invoke-FixtureGit @('-C', $worktree, 'commit', '-m', 'chunk')
            if ($case -ne 'unmerged') { Invoke-FixtureGit @('update-ref', 'refs/heads/build/test', 'dt-build/test/chunk') }
            # Main deliberately remains behind the chunk: branch -d would fail.
            $chunk = 'dt-build/test/chunk'
            $integration = 'build/test'
            $extra = @()
            $expected = $null
            switch ($case) {
                'no-worktree' { Invoke-FixtureGit @('worktree', 'remove', $worktree) }
                'unmerged' { $expected = 'CLEANUP_NOT_MERGED' }
                'untracked' {
                    Set-Content (Join-Path $worktree 'untracked.txt') 'keep'
                    $expected = 'CLEANUP_DIRTY_WORKTREE'
                }
                'modified' {
                    Add-Content (Join-Path $worktree 'chunk.txt') 'keep'
                    $expected = 'CLEANUP_DIRTY_WORKTREE'
                }
                'staged' {
                    Add-Content (Join-Path $worktree 'chunk.txt') 'keep'
                    Invoke-FixtureGit @('-C', $worktree, 'add', '.')
                    $expected = 'CLEANUP_DIRTY_WORKTREE'
                }
                'main' { $chunk = 'main'; $expected = 'CLEANUP_PROTECTED_BRANCH' }
                'master' { Invoke-FixtureGit @('branch', 'master'); $chunk = 'master'; $expected = 'CLEANUP_PROTECTED_BRANCH' }
                'qualified-main' { $chunk = 'refs/heads/main'; $expected = 'CLEANUP_PROTECTED_BRANCH' }
                'wrong-path' { $extra = @('-WorktreePath', $repo); $expected = 'CLEANUP_WORKTREE_MISMATCH' }
                'same-branch' { $integration = $chunk; $expected = 'CLEANUP_INVALID_BRANCH' }
                'merged' { $extra = @('-WorktreePath', $worktree) }
            }
            $entrypoint = $cleanup
            if ($case -eq 'leftover') {
                # Portable Windows-lock outcome: Git removes registration but a folder survives.
                $entrypoint = Join-Path $tempRoot 'leftover-wrapper.ps1'
                @'
param($RepoPath, $ChunkBranch, $IntegrationBranch, [switch]$Json)
function global:git {
    $output = & (Get-Command git -CommandType Application | Select-Object -First 1).Source @args 2>&1
    $code = $LASTEXITCODE
    if ($args[2] -eq 'worktree' -and $args[3] -eq 'remove' -and $code -eq 0) {
        New-Item -ItemType Directory -Path $args[-1] | Out-Null
    }
    $global:LASTEXITCODE = $code
    $output
}
& $env:DT_CLEANUP_TEST_SCRIPT -RepoPath $RepoPath -ChunkBranch $ChunkBranch -IntegrationBranch $IntegrationBranch -Json:$Json
'@ | Set-Content -LiteralPath $entrypoint
            }
            $savedScript = $env:DT_CLEANUP_TEST_SCRIPT
            try {
                $env:DT_CLEANUP_TEST_SCRIPT = $cleanup
                $raw = & pwsh -NoProfile -File $entrypoint -RepoPath $repo -ChunkBranch $chunk -IntegrationBranch $integration @extra -Json
                $code = $LASTEXITCODE
            } finally { $env:DT_CLEANUP_TEST_SCRIPT = $savedScript }
            $result = ($raw -join "`n") | ConvertFrom-Json
            Check ($result.chunk_branch -ceq $chunk -and $result.integration_branch -ceq $integration) 'JSON branch identity'
            if ($expected) {
                Check ($code -ne 0 -and -not $result.pass -and $result.error_code -eq $expected) "expected $expected, got $raw"
                Check (-not $result.deleted_branch -and -not $result.removed_worktree) 'refusal has no mutations'
                Check (Test-Path -LiteralPath (Join-Path $worktree 'chunk.txt')) 'refusal preserves worktree'
                Invoke-FixtureGit @('show-ref', '--verify', 'refs/heads/dt-build/test/chunk')
            } else {
                Check ($code -eq 0 -and $result.pass -and $result.deleted_branch -and $null -eq $result.error_code) "success JSON: $raw"
                Check ($result.removed_worktree -eq ($case -ne 'no-worktree')) 'worktree removal flag'
                & git -C $repo show-ref --verify --quiet refs/heads/dt-build/test/chunk
                Check ($LASTEXITCODE -eq 1) 'chunk ref deleted'
                $listing = (& git -C $repo worktree list --porcelain) -join "`n"
                Check (-not $listing.Contains('branch refs/heads/dt-build/test/chunk')) 'worktree deregistered'
                if ($case -eq 'leftover') {
                    Check ($result.leftovers.Count -eq 1 -and $result.leftovers[0].code -eq 'worktree_dir_leftover' -and (Test-Path -LiteralPath $worktree)) 'leftover reported without failure'
                } else {
                    Check ($result.leftovers.Count -eq 0 -and -not (Test-Path -LiteralPath $worktree)) 'no leftovers'
                }
            }
            $passed++
        } catch { $failures += "${case}: $_" }
    }
} finally {
    Pop-Location
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/', '\') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($tempBase) -or (Split-Path -Leaf $resolvedTemp) -notlike 'accepted-chunk-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
Write-Output "PASS: $passed accepted-chunk cleanup cases (all from non-repo cwd)"
if ($failures.Count) { $failures | Write-Output; exit 1 }
