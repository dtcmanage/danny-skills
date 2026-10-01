# Shared round default for both review lanes: use resolver effort in rounds 1-2,
# then step down one level for verification rounds, never below low.
function Get-DtReviewDefaultEffort {
    param(
        [Parameter(Mandatory)] [ValidateSet('low', 'medium', 'high', 'xhigh')] [string]$RouterEffort,
        [Parameter(Mandatory)] [ValidateRange(0, 99)] [int]$Round
    )
    if ($Round -le 2) { return $RouterEffort }
    return @{ xhigh = 'high'; high = 'medium'; medium = 'low'; low = 'low' }[$RouterEffort]
}
