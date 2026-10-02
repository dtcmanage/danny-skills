Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../run-mac-observer.ps1')
. (Join-Path $PSScriptRoot '../register-mac-router-schedules.ps1')
. (Join-Path $PSScriptRoot '../router-state-inventory.ps1')
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $message = ''
    try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
    Assert-True ($message -like $Pattern) $Name
}
function New-CredentialText([string]$Token = 'fixture-private-a',[bool]$Expired = $false) {
    $expiry = if ($Expired) { [datetimeoffset]::UtcNow.AddMinutes(-1) } else { [datetimeoffset]::UtcNow.AddHours(1) }
    return (@{ claudeAiOauth=@{ accessToken=$Token; expiresAt=$expiry.ToUnixTimeMilliseconds() } } | ConvertTo-Json -Compress)
}
$keys = @('DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_SHARED','DT_MODEL_ROUTER_CLAUDE_CREDENTIALS',
    'DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE','CLAUDE_CONFIG_DIR','DT_MODEL_ROUTER_CODEX_SESSIONS','CODEX_HOME','TEMP')
$prior = @{}
$priorSecretFixture = $env:ROUTER_TEST_SECRET_TOKEN
foreach ($key in $keys) { $prior[$key]=[Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$null) }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mac-observer-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$script:fixturePlatform = 'MacOS'
function Get-RouterPlatform { $script:fixturePlatform }
$script:processCalls = 0
$script:nativeMode = 'valid'
$fakeSecurity = {
    param($File,$Arguments,$Timeout)
    $script:processCalls++
    Assert-True ($File -eq '/usr/bin/security' -and $Timeout -eq 5000 -and $Arguments.Count -eq 4 -and $Arguments[2] -eq 'fixture-exact-account') 'Keychain uses exact service and bounded argument list' | Out-Null
    switch ($script:nativeMode) {
        'valid' { [pscustomobject]@{ status='completed'; exit_code=0; output=(New-CredentialText) } }
        'other' { [pscustomobject]@{ status='completed'; exit_code=0; output=(New-CredentialText 'fixture-private-b') } }
        'expired' { [pscustomobject]@{ status='completed'; exit_code=0; output=(New-CredentialText -Expired $true) } }
        'invalid' { [pscustomobject]@{ status='completed'; exit_code=0; output='broken fixture-private-b' } }
        'throw' { throw 'fixture-private-b' }
        'timeout' { [pscustomobject]@{ status='timeout'; exit_code=$null; output='fixture-private-b' } }
        default { [pscustomobject]@{ status='completed'; exit_code=44; output='fixture-private-b' } }
    }
}
try {
    $env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'runtime'
    $env:DT_MODEL_ROUTER_SHARED = Join-Path $tempRoot 'shared'
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $tempRoot 'sessions'
    $env:CODEX_HOME = Join-Path $tempRoot 'codex'
    $env:TEMP = Join-Path $tempRoot 'tmp'
    $userHome = Join-Path $tempRoot 'user'
    $custom = Join-Path $tempRoot 'account & custom'
    [IO.Directory]::CreateDirectory($custom) | Out-Null
    $env:CLAUDE_CONFIG_DIR = $custom
    $credentialFile = Join-Path $custom '.credentials.json'
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.status -eq 'missing' -and $result.keychain_status -eq 'unsupported-custom-config' -and $script:processCalls -eq 0) 'custom config without exact service never selects default account'
    [IO.File]::WriteAllText($credentialFile,(New-CredentialText))
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.source -eq 'file' -and $result.token -eq 'fixture-private-a') 'custom account file selected'
    $env:CLAUDE_CONFIG_DIR = $null
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.keychain_status -eq 'UNVERIFIED-service' -and $script:processCalls -eq 0) 'default native label stays unverified without override'
    $env:CLAUDE_CONFIG_DIR = $custom
    $env:DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE = 'fixture-exact-account'
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.status -eq 'available' -and $result.source -eq 'file') 'agreeing valid sources accepted'
    $script:nativeMode = 'other'
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.status -eq 'source-disagreement' -and $null -eq $result.token -and ($result | ConvertTo-Json) -notmatch 'fixture-private') 'disagreement rejected without revealing either token'
    $script:nativeMode = 'valid'
    $explicit = Join-Path $tempRoot 'explicit & account.json'
    [IO.File]::WriteAllText($explicit,(New-CredentialText 'fixture-explicit'))
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $explicit
    $calls = $script:processCalls
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.token -eq 'fixture-explicit' -and $script:processCalls -eq $calls) 'explicit credentials outrank custom config and do not consult Keychain'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $null
    Remove-Item -LiteralPath $credentialFile
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.source -eq 'keychain' -and $result.status -eq 'available') 'exact service supplies missing file'
    $env:CLAUDE_CONFIG_DIR=$null
    $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
    Assert-True ($result.source -eq 'keychain' -and $result.status -eq 'available') 'default Mac config uses only operator verified service'
    $env:CLAUDE_CONFIG_DIR=$custom
    foreach ($mode in @('locked','missing','timeout','expired','invalid','throw')) {
        $script:nativeMode = $mode
        $result = Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity
        Assert-True ($result.status -ne 'available' -and $null -eq $result.token -and ($result | ConvertTo-Json) -notmatch 'fixture-private') "$mode source unavailable and secret safe"
    }
    [IO.File]::WriteAllText($credentialFile,(New-CredentialText -Expired $true))
    Assert-True ((Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity).status -eq 'expired') 'expired file rejected'
    $env:DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE = $null
    $inventory = Get-RouterStateInventory -UserHome $userHome -Process { param($File,$Arguments) [pscustomobject]@{ status='unavailable'; exit_code=$null; output='' } }
    Assert-True (-not (Test-Path -LiteralPath $env:DT_MODEL_ROUTER_STATE) -and ($inventory | ConvertTo-Json -Depth 6) -notmatch 'fixture-private') 'inventory is read-only and contains no credentials'
    $inventory = Get-RouterStateInventory -Platform Windows -UserHome $userHome
    Assert-True ($inventory.native_credential_status -eq 'UNVERIFIED' -and $inventory.claude_credentials.keychain_status -eq 'UNVERIFIED') 'Windows metadata does not claim native verification'
    $pwshExecutable = (Get-Process -Id $PID).Path
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = Invoke-RouterBoundedProcess -FilePath $pwshExecutable -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutMs 100
    Assert-True ($process.status -eq 'timeout' -and $process.output -eq '' -and $timer.Elapsed.TotalSeconds -lt 4) 'actual process timeout terminates bounded child'
    $process = Invoke-RouterBoundedProcess -FilePath (Join-Path $tempRoot 'missing-executable')
    Assert-True ($process.status -eq 'unavailable' -and $process.output -eq '') 'missing executable safely unavailable'
    $dnsSuccess = { param($Name) [Threading.Tasks.Task]::FromResult([Net.IPAddress[]]@([Net.IPAddress]::Loopback)) }
    $dnsPending = { param($Name) [Threading.Tasks.TaskCompletionSource[Net.IPAddress[]]]::new().Task }
    Assert-True (Test-RouterDns -ApiHost 'fixture.invalid' -Platform MacOS -Resolver $dnsSuccess) 'portable DNS asynchronous success'
    $timer.Restart()
    Assert-True (-not (Test-RouterDns -ApiHost 'fixture.invalid' -Platform MacOS -Resolver $dnsPending -TimeoutMs 10) -and $timer.Elapsed.TotalSeconds -lt 1) 'portable DNS bounded timeout'
    Assert-True (-not (Test-RouterDns -ApiHost 'fixture.invalid' -Platform MacOS -Resolver { throw 'fixture DNS' })) 'portable DNS exception returns false'
    $script:RouterDiagnosisDns = { param($ApiHost) Test-RouterDns -ApiHost $ApiHost -Platform MacOS -Resolver $dnsPending -TimeoutMs 10 }
    $script:RouterDiagnosisHttp = { param($Uri) throw 'fixture offline' }
    Assert-True ((Resolve-RouterDispatchFailure -Vendor codex -ErrorText 'network failure').verdict -eq 'offline') 'portable DNS feeds offline diagnosis with isolated HTTP'

    $repo = Join-Path $tempRoot 'main & repo'
    [IO.Directory]::CreateDirectory((Join-Path $repo '.git/worktrees/fixture')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $repo 'scripts/model-router')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'scripts/model-router/run-mac-observer.ps1'),'# fixture')
    $tree = Join-Path $tempRoot 'linked'
    [IO.Directory]::CreateDirectory($tree) | Out-Null
    [IO.File]::WriteAllText((Join-Path $tree '.git'),('gitdir: ' + (Join-Path $repo '.git/worktrees/fixture')))
    [IO.File]::WriteAllText((Join-Path $repo '.git/worktrees/fixture/commondir'),'../..')
    Assert-Throws { New-RouterLaunchAgent -RepoPath $tree -PwshPath $pwshExecutable -UserHome $userHome } 'ROUTER_LAUNCH_WORKTREE:*' 'linked worktree install rejected'
    Assert-Throws { New-RouterLaunchAgent -RepoPath 'relative-path' -PwshPath $pwshExecutable -UserHome $userHome } 'ROUTER_LAUNCH_PATH:*' 'relative installation path rejected'
    $headPath = Join-Path $repo '.git/HEAD'
    foreach ($head in @('ref: refs/heads/feature-fixture',('a' * 40),'')) {
        if ($head) { [IO.File]::WriteAllText($headPath,$head) } elseif (Test-Path -LiteralPath $headPath) { Remove-Item -LiteralPath $headPath }
        Assert-Throws { New-RouterLaunchAgent -RepoPath $repo -PwshPath $pwshExecutable -UserHome $userHome } 'ROUTER_LAUNCH_MAIN:*' 'feature detached or missing HEAD rejects agent creation'
    }
    [IO.File]::WriteAllText($headPath,'ref: refs/heads/main')
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $explicit
    $env:DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE = 'fixture-exact-account'
    $env:ROUTER_TEST_SECRET_TOKEN = 'fixture-private-secret'
    $agent = New-RouterLaunchAgent -RepoPath $repo -PwshPath $pwshExecutable -UserHome $userHome
    $xml = [xml]$agent.xml
    Assert-True ($xml.SelectSingleNode('/plist/dict').SelectSingleNode('key[text()="RunAtLoad"]/following-sibling::*[1]').Name -eq 'true' -and $xml.SelectSingleNode('/plist/dict').SelectSingleNode('key[text()="StartInterval"]/following-sibling::*[1]').InnerText -eq '14400') 'plist has login trigger and four-hour backstop'
    $argsXml = $xml.SelectSingleNode('/plist/dict').SelectSingleNode('key[text()="ProgramArguments"]/following-sibling::*[1]')
    Assert-True ($argsXml.string.Count -eq 5 -and $argsXml.string[0] -eq $pwshExecutable -and $argsXml.string[4] -eq $agent.script_path) 'XML argument paths preserve spaces and ampersands'
    $envXml = $xml.SelectSingleNode('/plist/dict').SelectSingleNode('key[text()="EnvironmentVariables"]/following-sibling::*[1]')
    foreach ($key in $keys) {
        Assert-True ($envXml.SelectSingleNode("key[text()='$key']/following-sibling::*[1]").InnerText -eq [Environment]::GetEnvironmentVariable($key)) "$key locator survives preview"
    }
    Assert-True ($agent.xml -notmatch 'fixture-private|ROUTER_TEST_SECRET_TOKEN' -and -not (Test-Path -LiteralPath $agent.plist_path)) 'preview neither captures secrets nor writes schedules'
    Assert-True ((Get-RouterClaudeCredential -UserHome $userHome -Process $fakeSecurity).token -eq 'fixture-explicit') 'preview locator still selects exact configured file account'
    $beforePreview = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + $_.LastWriteTimeUtc.Ticks + ':' + $_.Length }) -join '|'
    $previewOutput = & $pwshExecutable -NoProfile -File (Join-Path $PSScriptRoot '../register-mac-router-schedules.ps1') -RepoPath $repo -PwshPath $pwshExecutable
    Assert-True ($LASTEXITCODE -eq 0 -and $null -ne $previewOutput -and -not (Test-Path -LiteralPath $agent.plist_path)) 'CLI default is nonmutating preview'
    $afterPreview = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + $_.LastWriteTimeUtc.Ticks + ':' + $_.Length }) -join '|'
    Assert-True ($beforePreview -ceq $afterPreview) 'preview leaves all fixture files unchanged'
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $inventoryJson = & $pwshExecutable -NoProfile -File (Join-Path $PSScriptRoot '../router-state-inventory.ps1') -Json
        $packet = $inventoryJson | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $packet.runtime_path -eq $env:DT_MODEL_ROUTER_STATE -and ($inventoryJson | Out-String) -notmatch 'fixture-private') 'inventory Json packet preserves isolated paths without tokens'
        $guardOutput = & $pwshExecutable -NoProfile -File (Join-Path $PSScriptRoot '../register-mac-router-schedules.ps1') -Apply -RepoPath $repo -PwshPath $pwshExecutable 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($guardOutput | Out-String) -like '*ROUTER_LAUNCH_MAC_ONLY*') 'native Apply refuses Windows despite fixture platform'
    }
    $script:loaded = $false; $script:failReadback = $false
    $script:launchCalls = [Collections.Generic.List[string]]::new()
    $fakeLaunch = {
        param($File,$Arguments)
        $script:launchCalls.Add($File + ' ' + ($Arguments -join ' '))
        $code = 0
        if ($File -eq '/usr/bin/plutil') { $null = [xml][IO.File]::ReadAllText($Arguments[1]) }
        elseif ($File -eq '/bin/launchctl') {
            switch ($Arguments[0]) {
                'print' { if (-not $script:loaded -or $script:failReadback) { $code=113 } }
                'bootstrap' { $script:loaded=$true }
                'bootout' { $script:loaded=$false }
                default { throw 'Unexpected launchctl command' }
            }
        } else { throw 'Unexpected native executable' }
        [pscustomobject]@{ status='completed'; exit_code=$code; output='' }
    }
    [IO.File]::WriteAllText($headPath,'ref: refs/heads/feature-fixture')
    Assert-Throws { Invoke-RouterLaunchAgentOperation -Agent $agent -Domain 'gui/501' -Command $fakeLaunch } 'ROUTER_LAUNCH_MAIN:*' 'operation rechecks branch after preview before any install'
    Assert-True ($script:launchCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $agent.plist_path)) 'rejected branch change invokes no native command or plist write'
    [IO.File]::WriteAllText($headPath,'ref: refs/heads/main')
    Assert-True ((Invoke-RouterLaunchAgentOperation -Agent $agent -Domain 'gui/501' -Command $fakeLaunch).status -eq 'installed') 'fake install lints bootstraps and verifies'
    $firstXml = [IO.File]::ReadAllText($agent.plist_path)
    Assert-True ((Invoke-RouterLaunchAgentOperation -Agent $agent -Domain 'gui/501' -Command $fakeLaunch).status -eq 'installed' -and [IO.File]::ReadAllText($agent.plist_path) -ceq $firstXml) 'reinstall idempotently replaces same owned plist'
    $failedRemoval = Invoke-RouterLaunchAgentOperation -Agent $agent -Remove -Domain 'gui/501' -Command { param($File,$Arguments) [pscustomobject]@{ status='timeout'; exit_code=$null; output='' } }
    Assert-True ($failedRemoval.status -eq 'verification-failed' -and (Test-Path -LiteralPath $agent.plist_path)) 'bounded removal failure preserves plist'
    $script:failReadback=$true
    Assert-True ((Invoke-RouterLaunchAgentOperation -Agent $agent -Domain 'gui/501' -Command $fakeLaunch).status -eq 'verification-failed') 'failed native readback reported'
    $script:failReadback=$false
    $unrelated = Join-Path (Split-Path -Parent $agent.plist_path) 'unrelated.plist'
    [IO.File]::WriteAllText($unrelated,'preserve')
    Assert-True ((Invoke-RouterLaunchAgentOperation -Agent $agent -Remove -Domain 'gui/501' -Command $fakeLaunch).status -eq 'removed' -and -not (Test-Path -LiteralPath $agent.plist_path) -and (Test-Path -LiteralPath $unrelated)) 'remove bootouts only owned label and deletes only owned plist'
    Assert-True ((Invoke-RouterLaunchAgentOperation -Agent $agent -Remove -Domain 'gui/501' -Command $fakeLaunch).status -eq 'removed') 'repeated removal idempotent'
    Assert-True (@($script:launchCalls | Where-Object { $_ -like '*bootout*' -and $_ -notlike '*gui/501/com.danny.model-router.observer' }).Count -eq 0) 'all bootouts target exact owned label'
    [IO.File]::WriteAllText($agent.plist_path,($agent.xml -replace 'com.danny.model-router.observer','foreign.owner'))
    Assert-Throws { Invoke-RouterLaunchAgentOperation -Agent $agent -Remove -Domain 'gui/501' -Command $fakeLaunch } 'ROUTER_LAUNCH_OWNERSHIP:*' 'foreign plist refused without removal'

    $script:readerCalls = 0; $script:fetchCalls=0
    function Send-RouterAlert { throw 'Unexpected real alert' }
    function Publish-RouterRoster { throw 'Unexpected publication' }
    function Invoke-RouterResearch { throw 'Unexpected research' }
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{ status='available'; source='file'; file_status='available'; keychain_status='UNVERIFIED'; token='fixture-private-a' } }
    $script:RouterClaudeUsageFetcher = {
        param($Token)
        $script:fetchCalls++
        [pscustomobject]@{ seven_day=[pscustomobject]@{ utilization=67; resets_at=[datetimeoffset]::UtcNow.AddDays(1).ToString('o') } }
    }
    $receipt = Invoke-RouterMacObserver -CodexReader { $script:readerCalls++; Get-RouterCodexUsage }
    Assert-True ($script:readerCalls -eq 1 -and $script:fetchCalls -eq 1 -and $receipt.roster_source -eq 'default' -and $receipt.claude_usage_available -and -not $receipt.codex_usage_available) 'one finite observer pass uses only local readers and roster'
    $receiptPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'mac-observer-receipt.json'
    Assert-True ([IO.File]::ReadAllText($receiptPath) -notmatch 'fixture-private' -and [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json')) -notmatch 'fixture-private') 'receipt and usage cache never persist tokens'
    [IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_SHARED) | Out-Null
    $approved = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $approved.approved=$true; $approved.approved_at=[datetimeoffset]::UtcNow.ToString('o')
    Write-RouterJsonAtomic -Path (Join-Path $env:DT_MODEL_ROUTER_SHARED 'roster.json') -Value $approved
    $receipt = Invoke-RouterMacObserver -ClaudeReader { $null } -CodexReader { $null }
    Assert-True ($receipt.roster_available -and $receipt.roster_source -eq 'shared') 'observer receipt records approved synced roster availability'
    [IO.File]::WriteAllText((Join-Path $env:DT_MODEL_ROUTER_SHARED 'roster.json'),'{fixture-private-invalid')
    $receipt = Invoke-RouterMacObserver -ClaudeReader { $null } -CodexReader { $null }
    Assert-True (-not $receipt.roster_available -and -not $receipt.roster_valid -and [IO.File]::ReadAllText($receiptPath) -notmatch 'fixture-private') 'invalid shared roster receipt contains safe flags only'
    Assert-True (@(Get-ChildItem -LiteralPath $env:DT_MODEL_ROUTER_SHARED -File).Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_SHARED 'roster.json')) -eq '{fixture-private-invalid') 'observer writes runtime only and never publishes shared state'
    $cache = Read-RouterJsonObject -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json')
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{ status='unavailable'; token=$null } }
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 67 -and $script:fetchCalls -eq 1) 'fresh valid cache preserved with unavailable credential'
    $cache.observed_at_utc=[datetimeoffset]::UtcNow.AddMinutes(-6).ToString('o')
    Write-RouterJsonAtomic -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json') -Value $cache
    Assert-True ($null -eq (Get-RouterClaudeUsage) -and $script:fetchCalls -eq 1) 'stale cache does not mask credential failure'
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{ status='source-disagreement'; token=$null } }
    Assert-True ($null -eq (Get-RouterClaudeUsage) -and $script:fetchCalls -eq 1) 'disagreeing credentials do not fetch quota'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS=$null
    $env:CLAUDE_CONFIG_DIR=$custom
    $env:DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE='fixture-exact-account'
    $cache.credential_locator_identity=Get-RouterClaudeCredentialIdentity
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{ status='available'; token='fixture-private-new-account' } }
    $script:RouterClaudeUsageFetcher = { param($Token) throw 'fixture fetch failure' }
    foreach ($name in @('DT_MODEL_ROUTER_CLAUDE_CREDENTIALS','CLAUDE_CONFIG_DIR','DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE')) {
        $before=[Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name,$(if ($name -eq 'DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE') {'fixture-other-account'} else {Join-Path $tempRoot 'other-account'}))
        foreach ($age in @(0,-6)) {
            $cache.observed_at_utc=[datetimeoffset]::UtcNow.AddMinutes($age).ToString('o')
            Write-RouterJsonAtomic -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json') -Value $cache
            Assert-True ($null -eq (Get-RouterClaudeUsage)) "$name change rejects old fresh or stale account quota"
        }
        [Environment]::SetEnvironmentVariable($name,$before)
    }
    $cache.PSObject.Properties.Remove('credential_locator_identity')
    $cache.observed_at_utc=[datetimeoffset]::UtcNow.ToString('o')
    Write-RouterJsonAtomic -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json') -Value $cache
    Assert-True ($null -eq (Get-RouterClaudeUsage)) 'legacy unidentified cache cannot mask unavailable new reading'
    $script:fixturePlatform = 'Windows'
    Assert-Throws { Invoke-RouterMacObserver } 'ROUTER_OBSERVER_MAC_ONLY' 'observer refuses Windows runtime'
    Write-Output "SUMMARY: $script:passed passed; native Mac acceptance UNVERIFIED"
} finally {
    foreach ($key in $keys) { [Environment]::SetEnvironmentVariable($key,$prior[$key]) }
    $env:ROUTER_TEST_SECRET_TOKEN = $priorSecretFixture
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
