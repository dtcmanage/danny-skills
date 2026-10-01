# redact-secrets.ps1
# Canonical secret-pattern redaction module (Control 4).
# Dot-source this file to define Invoke-SecretRedaction. No output, no side effects.
#
# Pattern-specific matching only. We deliberately do NOT do generic high-entropy,
# base64, or hex matching because that produces false positives on safe strings
# (file hashes, UUIDs, plain base64 text). Each pattern targets a specific
# credential shape.

Set-StrictMode -Version Latest

function Invoke-SecretRedaction {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $token = '[REDACTED-SECRET]'

    # Ordered list of credential-shaped patterns. Each is anchored to a
    # distinctive prefix or query-parameter context so safe strings are untouched.
    $patterns = @(
        # Anthropic API keys: distinctive sk-ant- prefix and key alphabet.
        # The lookbehind keeps hyphenated words such as "task-runner-..." or "risk-assessment-..." intact.
        '(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{8,}',
        # OpenAI project keys and legacy keys (20+ key characters).
        '(?<![A-Za-z0-9_-])sk-proj-[A-Za-z0-9_-]{8,}',
        '(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}',
        # GitHub PAT: ghp_ followed by 20+ base62 chars.
        'ghp_[A-Za-z0-9]{20,}',
        # Generic pat token: pat_ followed by 10+ word chars.
        'pat_[A-Za-z0-9_]{10,}',
        # Slack bot token: xoxb- followed by 10+ chars from the token alphabet.
        'xoxb-[A-Za-z0-9-]{10,}',
        # JWT-shaped: eyJ header segment, then two more dot-delimited base64url segments.
        'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
        # Azure SAS sig: a sig= query parameter (preceded by ? or &), 8+ value chars.
        # Only matched as a query parameter so a stray "sig=" in prose is left alone.
        '(?<=[?&])sig=[A-Za-z0-9%+/=]{8,}'
    )

    $result = $Text
    foreach ($pattern in $patterns) {
        $result = [regex]::Replace($result, $pattern, $token)
    }
    # Authorization scheme is retained; only the credential is replaced.
    $result = [regex]::Replace($result, '(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{12,}', '${1}' + $token)

    return $result
}
