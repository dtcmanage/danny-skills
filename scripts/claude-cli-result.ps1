# Shared parser for `claude -p --output-format json`. Dot-source this file, then call
# ConvertFrom-ClaudeCliResult.
#
# Why this exists: dt-build and dt-review dispatch the Claude lane by family alias (opus,
# sonnet, haiku) so a new version in a family is picked up with no edit. The alias alone
# cannot tell an auditor which version ran, so every caller records the exact model the CLI
# reports in the JSON envelope's modelUsage, and fails closed when no model of the requested
# family ran.

function Get-ClaudeModelFamily {
    param([Parameter(Mandatory)][string]$Model)
    $m = $Model.ToLowerInvariant() -replace '\[.*\]$', ''
    $full = [regex]::Match($m, '^claude-([a-z]+)-')
    if ($full.Success) { return $full.Groups[1].Value }
    return $m
}

function New-ClaudeCliInvocation {
    # --settings merges this single plugin override with configured settings. Do not
    # supply hooks or restrict setting sources: inherited PreToolUse hooks must still run.
    $path = Join-Path ([IO.Path]::GetTempPath()) ('claude-output-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($path, '{"enabledPlugins":{"message-timestamps@zoharbabin-claude-tools":false}}', [Text.UTF8Encoding]::new($false))
        $invocation = [pscustomobject]@{ Arguments = @('--settings', $path); SettingsPath = $path }
        $invocation | Add-Member -MemberType ScriptMethod -Name ReadResult -Value {
            param([string]$Stdout, [string]$RequestedModel)
            ConvertFrom-ClaudeCliResult -Stdout $Stdout -RequestedModel $RequestedModel
        }
        $invocation | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            Remove-Item -LiteralPath $this.SettingsPath -Force -ErrorAction SilentlyContinue
        }
        return $invocation
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}

function ConvertFrom-ClaudeCliResult {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Stdout,
        # The alias or full id passed to --model; its family must match what ran.
        [Parameter(Mandatory)][string]$RequestedModel
    )
    # Keep ISO-looking result strings literal instead of coercing them to DateTime.
    try { $envelope = $Stdout.Trim() | ConvertFrom-Json -DateKind String }
    catch { throw "claude -p JSON envelope is unparseable: $($_.Exception.Message)" }
    if (-not $envelope -or -not $envelope.PSObject.Properties['result']) {
        throw 'claude -p JSON envelope has no result field.'
    }
    if ([string]$envelope.result -match '^\[\d\d:\d\d:\d\d\] ') {
        throw 'claude -p result has a timestamp prefix; byte-exact output contract failed.'
    }

    $modelsUsed = @()
    $usageProp = $envelope.PSObject.Properties['modelUsage']
    if ($usageProp -and $usageProp.Value) {
        $modelsUsed = @(
            foreach ($p in $usageProp.Value.PSObject.Properties) {
                $u = $p.Value
                [pscustomobject]@{
                    model         = [string]$p.Name
                    input_tokens  = if ($u.PSObject.Properties['inputTokens']) { [long]$u.inputTokens } else { $null }
                    output_tokens = if ($u.PSObject.Properties['outputTokens']) { [long]$u.outputTokens } else { $null }
                    cost_usd      = if ($u.PSObject.Properties['costUSD']) { [double]$u.costUSD } else { $null }
                }
            }
        )
    }
    if ($modelsUsed.Count -eq 0) {
        throw 'claude -p reported no modelUsage; cannot verify which model version ran.'
    }

    $family = Get-ClaudeModelFamily -Model $RequestedModel
    $matching = @($modelsUsed | Where-Object { (Get-ClaudeModelFamily -Model $_.model) -eq $family } | Sort-Object -Property output_tokens -Descending)
    if ($matching.Count -eq 0) {
        throw "Requested '$RequestedModel' ($family family) but claude ran: $(($modelsUsed | ForEach-Object { $_.model }) -join ', ')."
    }

    return [pscustomobject]@{
        result         = [string]$envelope.result
        is_error       = [bool]($envelope.PSObject.Properties['is_error'] -and $envelope.is_error)
        resolved_model = [string]$matching[0].model
        models_used    = $modelsUsed
        total_cost_usd = if ($envelope.PSObject.Properties['total_cost_usd']) { $envelope.total_cost_usd } else { $null }
    }
}
