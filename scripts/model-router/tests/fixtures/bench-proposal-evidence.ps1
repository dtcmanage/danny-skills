function Initialize-TestBenchEvidence {
    $dir = Join-Path (Get-RouterStateDir) 'bench'
    [void][IO.Directory]::CreateDirectory($dir)
    $config = Get-Content (Join-Path $PSScriptRoot '../../bench/bench-config.json') -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName judge_effort -NotePropertyValue high -Force
    Write-RouterJsonAtomic (Join-Path $dir 'judge-config.json') $config
    $context = Get-RouterBenchEvidenceContext
    Write-RouterJsonAtomic (Join-Path $dir 'golden-approval.json') ([pscustomobject]@{approved=$true;task_bank_sha256=$context.task_bank_sha256})
}

function Add-TestBenchEvidence {
    param([object]$Bench)
    $context = Get-RouterBenchEvidenceContext
    $Bench | Add-Member -NotePropertyName task_bank_sha256 -NotePropertyValue $context.task_bank_sha256 -Force
    $Bench | Add-Member -NotePropertyName judge_pair -NotePropertyValue $context.judge_pair -Force
    $Bench | Add-Member -NotePropertyName judge_effort -NotePropertyValue $context.judge_effort -Force
    return $Bench
}
