# Orchestration hardening adoption

Run only on Danny's go-ahead, after the File Sorter build has finished. Commands target the canonical main checkout, not a milestone worktree. Replace `<accepted-build-branch>` with the accepted build branch and `<evidence-dir>` with an absolute evidence directory. Do not treat the synthetic suite as live host acceptance.

1. Confirm no active run and no live lease. Stop if the registry has any entry; resolve it through its owning run before continuing.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$registry = Join-Path $(if ($env:DT_BUILD_STATE_DIR) { $env:DT_BUILD_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'dt-build' }) 'active-runs.json'; $runs = if (Test-Path -LiteralPath $registry) { @((Get-Content -Raw -LiteralPath $registry | ConvertFrom-Json).runs) } else { @() }; $runs | ForEach-Object { $lease = Join-Path $_.run_folder 'coordinator.lease'; if (Test-Path -LiteralPath $lease) { Get-Content -Raw -LiteralPath $lease } }; if ($runs.Count) { throw 'Active dt-build registry: finish the owning runs, including File Sorter, first.' }
```

2. Merge through `/git-merge-feature`. Record the pre-merge commit and merged range for rollback. The merge machinery uses fast-forward merges; there is no separate merge commit. Push only on Danny's "ship it".

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$env:DT_ADOPTION_BEFORE = (git rev-parse main).Trim(); pwsh -NoProfile -File skills/git-merge-feature/scripts/merge-feature.ps1 -Branch '<accepted-build-branch>' -Json
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$env:DT_ADOPTION_AFTER = (git rev-parse main).Trim(); "$env:DT_ADOPTION_BEFORE..$env:DT_ADOPTION_AFTER" | Set-Content -LiteralPath (Join-Path $env:TEMP 'dt-build-adoption-range.txt'); git push origin main
```

3. Junctions pick up the repository change. Verify them and the CLI plugin inventory; open a fresh CLI and Cowork session and confirm dt-build 2.21.0 / plugin 0.20.0 loads before proceeding. Cowork confirmation is a manual UI check, not a claim made by the CLI inventory.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
pwsh -NoProfile -File scripts/verify-skill-junctions.ps1
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
claude plugin list
```

4. Register the watcher and install the shipped hooks into the live settings file, `D:\Claude\settings.json`, confirmed in [hooks/README.md](../hooks/README.md). Preserve existing hook entries and back up settings first. The watcher uses the existing hidden VBS shim. These commands perform the live changes; the milestone build never runs them.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
pwsh -NoProfile -File skills/dt-build/scripts/register-dt-build-watcher.ps1
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$target = 'D:\Claude\settings.json'; Copy-Item -LiteralPath $target -Destination "$target.before-dt-build-hooks"; $settings = Get-Content -Raw -LiteralPath $target | ConvertFrom-Json -AsHashtable; $dir = (Resolve-Path 'skills/dt-build/hooks').Path.Replace('\','/'); $snippet = (Get-Content -Raw 'skills/dt-build/hooks/settings-snippet.json').Replace('__DT_BUILD_HOOKS_DIR__',$dir) | ConvertFrom-Json -AsHashtable; if (-not $settings.ContainsKey('hooks')) { $settings.hooks = @{} }; foreach ($event in $snippet.hooks.Keys) { $entries = @($settings.hooks[$event] | Where-Object { $null -ne $_ }); if (-not ([string]($entries | ConvertTo-Json -Depth 20)).Contains($dir)) { $settings.hooks[$event] = $entries + @($snippet.hooks[$event]) } }; [IO.File]::WriteAllText($target,($settings | ConvertTo-Json -Depth 30))
```

5. Run live validation once, including real scenario 1 (and 2), missed-notification scenario 3, and managed context scenario 8 on each host. The script always runs the ten isolated synthetic scenarios, then `-Live` adds the real wrapper and host tests; its evidence stays in the named directory. For live scenario 3, start an echo job in a temporary unmanaged run, close the coordinator, let the registered watcher observe completion, then reopen the coordinator, consume its event once, and verify another watcher tick stays quiet. Record that receipt alongside the live evidence. Normal use starts only after these receipts pass. Run equivalent old/new toy builds from `scripts/tests/fixtures/toy-build/` on each host, forcing one new-style rotation; compare their retained folders and collect-usage rows with the command below. Any host regression needs Danny's recorded acceptance.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
pwsh -NoProfile -File skills/dt-build/scripts/tests/test-orchestration-scenarios.ps1 -Live -EvidenceDir '<evidence-dir>'
```

For live scenario 3, create the temporary run and echo job below, then close this coordinator session before the five-second job ends. The registered watcher must observe its completion without an attached coordinator. In a fresh session run the second block to consume exactly once; after another scheduled tick, retain the notifications and event cursor as evidence, then finish with the third block.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$run = Join-Path '<evidence-dir>' 'live-s03'; New-Item -ItemType Directory -Path $run -Force | Out-Null; $state = Join-Path $run '_build-state.md'; $text = (Get-Content -Raw 'skills/dt-pipeline/templates/build-state-template.md').Replace('__RUN_STATUS__','runnable').Replace('__LAST_CONSUMED_EVENT_SEQ__','0').Replace('__UPDATED_UTC__',[DateTime]::UtcNow.ToString('o')); [IO.File]::WriteAllText($state,$text); pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 register-run -RunFolder $run -RunId live-s03 -BuildStatePath $state -PinnedHost claude -Json; pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 start -RunFolder $run -Command 'Start-Sleep -Seconds 5; Write-Output echo' -Json
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$run = Join-Path '<evidence-dir>' 'live-s03'; pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 reconcile -RunFolder $run -Json; $status = pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 status -RunFolder $run -Json | ConvertFrom-Json; if ($status.last_event_seq -le $status.last_consumed_event_seq) { throw 'Expected one unconsumed completion' }; pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 consume -RunFolder $run -CoordinatorId live-s03-next -Seq $status.last_event_seq -Json
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$run = Join-Path '<evidence-dir>' 'live-s03'; pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 status -RunFolder $run -Json | Set-Content -LiteralPath (Join-Path $run 'receipt.json'); pwsh -NoProfile -File skills/dt-build/scripts/dt-job.ps1 finish -RunFolder $run -Json
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
pwsh -NoProfile -File skills/dt-build/scripts/compare-orchestration.ps1 -OldRunFolder '<absolute-old-run>' -NewRunFolder '<absolute-new-run>' -UsageLedgerPath '<absolute-collect-usage-ledger>' -OutputDir '<evidence-dir>'
```

6. Rollback: first finish or cancel affected runs and confirm no active coordinator. Unregister the watcher, remove only this feature's two hook commands while preserving unrelated settings, and revert the recorded fast-forward range. Review the rollback before committing; push requires Danny's authorization. The settings backup is retained for recovery, not blindly restored over subsequent settings changes.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
pwsh -NoProfile -File skills/dt-build/scripts/register-dt-build-watcher.ps1 -Unregister
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$target = 'D:\Claude\settings.json'; $settings = Get-Content -Raw -LiteralPath $target | ConvertFrom-Json -AsHashtable; $dir = (Resolve-Path 'skills/dt-build/hooks').Path.Replace('\','/'); foreach ($event in @('PreToolUse','PostToolUse')) { if ($settings.hooks.ContainsKey($event)) { $entries = foreach ($entry in @($settings.hooks[$event])) { $entry.hooks = @($entry.hooks | Where-Object { $_.command -notlike "*$dir/coordinator-pretooluse.ps1*" -and $_.command -notlike "*$dir/coordinator-posttooluse.ps1*" }); if ($entry.hooks.Count) { $entry } }; $settings.hooks[$event] = @($entries) } }; [IO.File]::WriteAllText($target,($settings | ConvertTo-Json -Depth 30))
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
$range = (Get-Content -Raw -LiteralPath (Join-Path $env:TEMP 'dt-build-adoption-range.txt')).Trim(); git revert --no-commit $range
```
