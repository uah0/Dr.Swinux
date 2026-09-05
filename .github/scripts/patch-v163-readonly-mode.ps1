$ErrorActionPreference='Stop'
$repo=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$agentPath=Join-Path $repo 'system\Start-Agent.ps1'
$brokerPath=Join-Path $repo 'system\Broker-Request.ps1'
$versionPath=Join-Path $repo 'system\VERSION.txt'

$agent=Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8

$old=@'
function Test-NoTask {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){ return $false }
    $normalized=($Text.Trim().ToLowerInvariant() -replace '\s+',' ')
    return $normalized -in @('нет','нет проблем','проблем нет','ничего','отмена','выход')
}
'@
$new=@'
function Test-NoTask {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){ return $false }
    $normalized=($Text.Trim().ToLowerInvariant() -replace '\s+',' ')
    return $normalized -in @('нет','нет проблем','проблем нет','ничего','отмена','выход')
}

function Test-TaskRequiresSystemChange {
    param([Parameter(Mandatory=$true)][string]$Text)
    $normalized=($Text.Trim().ToLowerInvariant() -replace '\s+',' ')
    $mutationPattern='(?i)(установ(и|ить|ка)|удал(и|ить|ение)|обнов(и|ить)|исправ(ь|ить)|почин(и|ить)|включ(и|ить)|отключ(и|ить)|измени(ть)?|поменя(й|ть)|созда(й|ть)|очист(и|ить)|сброс(ь|ить)|настрой|переустанов|форматир|размет|запусти\s+служб|останови\s+служб|install\b|uninstall\b|remove\b|delete\b|update\b|upgrade\b|fix\b|repair\b|enable\b|disable\b|change\b|modify\b|create\b|reset\b|configure\b|format\b)'
    return [regex]::IsMatch($normalized,$mutationPattern)
}
'@
if(-not $agent.Contains($old)){ throw 'Start-Agent Test-NoTask anchor not found' }
$agent=$agent.Replace($old,$new)

$old="Write-PreAgentLog -Stage 'task-input' -Status 'ACCEPTED' -Detail ('characters={0}' -f `$Task.Length)"
$new=@"
Write-PreAgentLog -Stage 'task-input' -Status 'ACCEPTED' -Detail ('characters={0}' -f `$Task.Length)
`$taskRequiresSystemChange=Test-TaskRequiresSystemChange -Text `$Task
`$taskMode=if(`$taskRequiresSystemChange){'SYSTEM_CHANGE'}else{'READ_ONLY'}
`$codexSandboxMode=if(`$taskRequiresSystemChange){'workspace-write'}else{'read-only'}
Write-PreAgentLog -Stage 'task-mode' -Status `$taskMode -Detail ('sandbox={0}' -f `$codexSandboxMode)
"@
if(-not $agent.Contains($old)){ throw 'Start-Agent task accepted anchor not found' }
$agent=$agent.Replace($old,$new.TrimEnd())

$old="Write-PreAgentLog -Stage 'session' -Status 'CREATED' -Detail ('session={0}' -f `$session)"
$new=@"
Write-PreAgentLog -Stage 'session' -Status 'CREATED' -Detail ('session={0}' -f `$session)
[ordered]@{schemaVersion=1;mode=`$taskMode;systemChange=[bool]`$taskRequiresSystemChange} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path `$session 'task-mode.json') -Encoding UTF8
"@
if(-not $agent.Contains($old)){ throw 'Start-Agent session anchor not found' }
$agent=$agent.Replace($old,$new.TrimEnd())

$old="Show-Status 'Для системных действий Windows может запросить права администратора.'"
$new="if(`$taskRequiresSystemChange){ Show-Status 'Для системных изменений Windows может запросить права администратора.' } else { Show-Status 'Диагностический режим: изменения системы запрещены; дополнительные подтверждения действий не требуются.' }"
if(-not $agent.Contains($old)){ throw 'Start-Agent broker status anchor not found' }
$agent=$agent.Replace($old,$new)

$old='PRIVILEGED BROKER:'
$new=@"
TASK MODE:
- This session is `$taskMode.
- READ_ONLY means the user's task is observation/diagnosis only. Do not modify files, registry, services, packages, configuration, security settings, accounts, scheduled tasks, boot state, or any other system state. Use ordinary read-only commands and elevated broker read actions as needed. No broker-owned confirmation is required for read-only actions.
- SYSTEM_CHANGE means the user's request explicitly asks to change system state. Use the existing typed broker boundaries and confirmations for mutation actions.
- The launcher and Broker-Request.ps1 enforce the mode independently of your reasoning. If a READ_ONLY task turns out to require a change, explain that a separate system-change task is required instead of attempting the change.

PRIVILEGED BROKER:
"@
if(-not $agent.Contains($old)){ throw 'Start-Agent prompt broker anchor not found' }
$agent=$agent.Replace($old,$new.TrimEnd())

$old="'--sandbox','workspace-write','--cd'"
$new="'--sandbox',`$codexSandboxMode,'--cd'"
if(-not $agent.Contains($old)){ throw 'Start-Agent Codex sandbox anchor not found' }
$agent=$agent.Replace($old,$new)

Set-Content -LiteralPath $agentPath -Value $agent -Encoding UTF8

$broker=Get-Content -LiteralPath $brokerPath -Raw -Encoding UTF8
$anchor="if(`$Action -eq 'EnsureWinget'){"
$insert=@'
$taskModePath=Join-Path $Session 'task-mode.json'
$taskMode='SYSTEM_CHANGE'
if(Test-Path -LiteralPath $taskModePath -PathType Leaf){
    try {
        $modeDoc=Get-Content -LiteralPath $taskModePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if([string]$modeDoc.mode -in @('READ_ONLY','SYSTEM_CHANGE')){ $taskMode=[string]$modeDoc.mode }
        else { throw 'invalid task mode' }
    } catch {
        throw ('Invalid Dr.Swinux task mode metadata: '+$_.Exception.Message)
    }
}
if($taskMode -eq 'READ_ONLY'){
    $mutationActions=@('EnsureWinget','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue')
    if($Action -in $mutationActions){
        throw ("Action '{0}' is blocked because this Dr.Swinux session is READ_ONLY." -f $Action)
    }
}

if($Action -eq 'EnsureWinget'){
'@
if(-not $broker.Contains($anchor)){ throw 'Broker EnsureWinget anchor not found' }
$broker=$broker.Replace($anchor,$insert.TrimEnd())
Set-Content -LiteralPath $brokerPath -Value $broker -Encoding UTF8

Set-Content -LiteralPath $versionPath -Value "Dr.Swinux v1.5.63-final`n" -Encoding UTF8

$errors=@()
foreach($path in @($agentPath,$brokerPath)){
    $tokens=$null; $parseErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count -gt 0){ $errors += $parseErrors | ForEach-Object { "${path}: $($_.Message)" } }
}
if($errors.Count -gt 0){ throw ($errors -join "`n") }

$agentCheck=Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8
$brokerCheck=Get-Content -LiteralPath $brokerPath -Raw -Encoding UTF8
if(-not $agentCheck.Contains('$codexSandboxMode=if($taskRequiresSystemChange){''workspace-write''}else{''read-only''}')){ throw 'task sandbox mode invariant missing' }
if($agentCheck -notmatch 'windows\.sandbox=.*unelevated'){ throw 'unelevated sandbox invariant missing' }
if($agentCheck -match 'danger-full-access'){ throw 'danger-full-access is forbidden' }
if($brokerCheck -notmatch "taskMode -eq 'READ_ONLY'"){ throw 'broker read-only enforcement missing' }
if($brokerCheck -notmatch 'SetRegistryValue'){ throw 'broker mutation denylist incomplete' }
Write-Host 'v1.5.63 read-only mode migration validated.'
