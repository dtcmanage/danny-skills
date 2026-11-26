Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# A frontier name means the newest release the router has seen (Danny, 2026-11-26),
# unless the ladder pins it with track_latest false.
. (Join-Path $PSScriptRoot '../router-ladder.ps1')
$script:passed = 0
function Check([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; "PASS: $Name" }
$temp = Join-Path ([IO.Path]::GetTempPath()) ("router-ladder-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $known = Join-Path $temp 'known-models.json'
    function Set-Known([object[]]$Rows) { ConvertTo-Json -InputObject @($Rows) -Depth 5 | Set-Content -LiteralPath $known }
    function Frontier([object]$Map, [string]$Lane) { @($Map.lanes.$Lane.ladder | Where-Object frontier)[0] }
    $shipped = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/ladders.json') -Raw | ConvertFrom-Json

    Set-Known @(
        @{id='claude-fable-5-3';lane='claude';status='known'},
        @{id='claude-fable-6';lane='claude';status='missing'},
        @{id='claude-fable-5-10';lane='claude';status='researched'},
        @{id='gpt-7-astra';lane='codex';status='researched'},
        @{id='gpt-7-sol';lane='codex';status='known'})
    $map = Get-RouterLadderMap -KnownModelsPath $known
    Check ((Frontier $map claude).model -ceq 'claude-fable-5-10') 'newest seen Fable wins, minor versions compare as numbers'
    Check ((Frontier $map codex).model -ceq 'gpt-7-astra') 'newest seen Astra wins'
    Check ((Frontier $map claude).ladder_model -ceq (Frontier $shipped claude).model) 'ladder file version kept as ladder_model'
    Check (@($map.lanes.codex.ladder | Where-Object { -not $_.frontier } | ForEach-Object model) -notcontains 'gpt-7-sol') 'non-frontier rungs never change'

    Set-Known @(@{id='claude-fable-5-1';lane='claude';status='known'}, @{id='gpt-6-astra';lane='codex';status='known'})
    $map = Get-RouterLadderMap -KnownModelsPath $known
    Check ((Frontier $map claude).model -ceq (Frontier $shipped claude).model -and (Frontier $map codex).model -ceq (Frontier $shipped codex).model) 'older releases never replace the ladder version'

    Set-Known @(@{id='claude-fable-6';lane='claude';status='missing'})
    $map = Get-RouterLadderMap -KnownModelsPath $known
    Check ((Frontier $map claude).model -ceq (Frontier $shipped claude).model) 'a model marked missing is never picked'
    $map = Get-RouterLadderMap -KnownModelsPath (Join-Path $temp 'absent.json')
    Check ((Frontier $map claude).model -ceq (Frontier $shipped claude).model) 'no known-models list falls back to the ladder file'
    Set-Content -LiteralPath $known -Value '{not json'
    $map = Get-RouterLadderMap -KnownModelsPath $known
    Check ((Frontier $map claude).model -ceq (Frontier $shipped claude).model) 'an unreadable known-models list falls back to the ladder file'

    $catalog = [pscustomobject]@{ models = @([pscustomobject]@{slug='gpt-8-astra';visibility='list'}, [pscustomobject]@{slug='gpt-9-astra';visibility='hide'}) }
    Set-Known @()
    $map = Get-RouterLadderMap -KnownModelsPath $known -Catalog $catalog
    Check ((Frontier $map codex).model -ceq 'gpt-8-astra') 'a held Codex catalog adds listed slugs only'

    $pinned = Join-Path $temp 'ladders.json'
    $copy = $shipped | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    (Frontier $copy claude).track_latest = $false
    $copy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pinned
    Set-Known @(@{id='claude-fable-5-9';lane='claude';status='known'}, @{id='gpt-7-astra';lane='codex';status='known'})
    $map = Get-RouterLadderMap -KnownModelsPath $known -LadderPath $pinned
    Check ((Frontier $map claude).model -ceq (Frontier $shipped claude).model -and (Frontier $map codex).model -ceq 'gpt-7-astra') 'track_latest false pins one rung only'

    # The by-name path uses the same resolution.
    $env:DT_MODEL_ROUTER_STATE = $temp
    Set-Known @(@{id='claude-fable-5-9';lane='claude';status='known'})
    . (Join-Path $PSScriptRoot '../dispatch-evidence.ps1')
    $named = Get-RouterNamedModel 'fable'
    Check ($named.model -ceq 'claude-fable-5-9' -and $named.frontier) '"fable" by name resolves to the newest Fable'
    Check ((Get-RouterNamedModel 'claude-fable-5-9').frontier) 'the newest Fable by exact id is frontier'
    Check ((Get-RouterByNameQuote -Model 'fable' -SelectionReason 'Danny asked: "use fable here"') -ceq 'use fable here') 'by-name quote still required and returned'
    "router-ladder: $script:passed passed"
} finally {
    Remove-Item Env:DT_MODEL_ROUTER_STATE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
