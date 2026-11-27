# Shared prompt identity boundary for both chunk wrappers. Return new text; never write the source.
function Get-WorkerAttemptPrompt {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateRange(1, 2147483647)][int]$Attempt = 1
    )

    # Preserve line endings and every byte of unrelated text. Accept case, indentation, bullets,
    # bold labels and inline backticks, but never infer a number from prose or a malformed value.
    $candidate = '(?im)^[\t ]*(?:[-*][\t ]+)?(?:\*\*|`)*attempt(?:\*\*|`)*[\t ]*:[^\r\n]*'
    $headers = @([regex]::Matches($Text, $candidate))
    $primaryCount = 0
    $echoCount = 0
    foreach ($header in $headers) {
        $plain = $header.Value.Trim() -replace '^[-*][\t ]+', ''
        $plain = $plain.Replace('**', '').Replace('`', '')
        $value = [regex]::Match($plain, '(?i)^attempt[\t ]*:[\t ]*([0-9]+)[\t ]*$')
        $number = 0
        if (-not $value.Success -or -not [int]::TryParse($value.Groups[1].Value, [ref]$number) -or $number -ne $Attempt) {
            throw "prompt attempt header must equal -Attempt $Attempt; malformed or mismatched header: $($header.Value.Trim())"
        }
        # The assembler intentionally repeats identity in its output template. Only that explicit
        # report preamble is an echo; a second loose header (even agreeing) is ambiguous.
        $prefix = $Text.Substring(0, $header.Index)
        if ($prefix -match '(?m)^DT_BUILD_REPORT_VERSION:[\t ]*[23][\t ]*\r?\nRUN_ID:[^\r\n]+\r?\nchunk_id:[^\r\n]+\r?\n\z') { $echoCount++ }
        else { $primaryCount++ }
    }
    if ($primaryCount -gt 1 -or $echoCount -gt 1) {
        throw "prompt attempt header must equal -Attempt $Attempt; ambiguous duplicate headers."
    }
    $canonical = "attempt: $Attempt"
    $result = [regex]::Replace($Text, $candidate, [Text.RegularExpressions.MatchEvaluator]{ param($match) $canonical })
    if ($primaryCount -eq 0) { $result = $canonical + "`n" + $result }
    if ($echoCount -eq 0) {
        $result += "`nWorker output identity: return the structured dt-build report and echo exactly ``attempt: $Attempt`` in its attempt field.`n"
    }
    return $result
}
