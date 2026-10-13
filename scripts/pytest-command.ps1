function Test-DannyPytestCommand {
    param([string]$Command, [string]$Executable, [string[]]$ArgumentList = @())
    if ($Executable) {
        $leaf = ($Executable -split '[\\/]')[-1]
        if ($leaf -match '(?i)^pytest(?:\.exe)?$') { return $true }
        if ($leaf -match '(?i)^(?:python(?:w|3(?:\.\d+)?)?|py)(?:\.exe)?$') {
            for ($i = 0; $i -lt $ArgumentList.Count - 1; $i++) {
                if ($ArgumentList[$i] -eq '-m' -and $ArgumentList[$i+1] -eq 'pytest') { return $true }
                if ($ArgumentList[$i] -eq '-c' -and $ArgumentList[$i+1] -match '\bpytest\s*\.\s*main\s*\(') { return $true }
            }
        }
    }
    if ($Command) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { return $false }
        foreach ($node in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $name = $node.GetCommandName()
            $argsList = @($node.CommandElements | Select-Object -Skip 1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
                else { $_.Extent.Text }
            })
            if (Test-DannyPytestCommand -Executable $name -ArgumentList $argsList) { return $true }
            # Literal shell command bodies; filenames/comments/output that only
            # mention pytest do not turn an unrelated job into a pytest caller.
            if ($name -and ($name -split '[\\/]')[-1] -match '(?i)^(?:pwsh|powershell|cmd|bash|sh)(?:\.exe)?$') {
                for ($i = 0; $i -lt $argsList.Count - 1; $i++) {
                    if ($argsList[$i] -in @('-Command','-c','/c') -and (Test-DannyPytestCommand -Command $argsList[$i+1])) { return $true }
                }
            }
        }
    }
    return $false
}
