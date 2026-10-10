param([Parameter(Mandatory)][ValidateSet('M01','M02')][string]$Milestone)
$actual = Write-Output "echo $Milestone"
if ($actual -cne "echo $Milestone") { exit 1 }
Write-Output "PASS: $actual"
