$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-Once {
    param([string]$Path,[string]$Old,[string]$New)
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $count=([regex]::Matches($text,[regex]::Escape($Old))).Count
    if($count -ne 1){throw ("Expected exactly one marker in {0}, found {1}" -f $Path,$count)}
    Set-Content -LiteralPath $Path -Value $text.Replace($Old,$New) -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
$agent='system/Start-Agent.ps1'
$reporter='system/Failure-Reporter.ps1'
$config='system/failure-reporting.json'
$version='system/VERSION.txt'

if(-not(Test-Path -LiteralPath $reporter -PathType Leaf)){throw 'Failure-Reporter.ps1 missing'}
if(-not(Test-Path -LiteralPath $config -PathType Leaf)){throw 'failure-reporting.json missing'}

# Fix StrictMode-safe access to optional uninstall registry properties.
$marker='function Get-TrustedHklmInstalledMatches {'
$helper=@'
function Get-RegistryStringProperty {
    param($Object,[string]$Name)
    if($null -eq $Object){return ''}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property -or $null -eq $property.Value){return ''}
    return [string]$property.Value
}

'@
$brokerText=Get-Content -LiteralPath $broker -Raw -Encoding UTF8
if($brokerText -notmatch 'function Get-RegistryStringProperty'){ 
    $count=([regex]::Matches($brokerText,[regex]::Escape($marker))).Count
    if($count -ne 1){throw 'Trusted uninstall helper insertion marker mismatch'}
    $brokerText=$brokerText.Replace($marker,$helper+$marker)
}
$brokerText=$brokerText.Replace('$display=[string]$item.DisplayName','$display=Get-RegistryStringProperty -Object $item -Name ''DisplayName''')
$brokerText=$brokerText.Replace('$publisher=[string]$item.Publisher','$publisher=Get-RegistryStringProperty -Object $item -Name ''Publisher''')
$brokerText=$brokerText.Replace('DisplayVersion=[string]$item.DisplayVersion','DisplayVersion=(Get-RegistryStringProperty -Object $item -Name ''DisplayVersion'')')
$brokerText=$brokerText.Replace('QuietUninstallString=[string]$item.QuietUninstallString','QuietUninstallString=(Get-RegistryStringProperty -Object $item -Name ''QuietUninstallString'')')
$brokerText=$brokerText.Replace('if([string]$fresh.DisplayName -ne $entry.DisplayName -or [string]$fresh.Publisher -ne $entry.Publisher -or [string]$fresh.QuietUninstallString -ne $entry.QuietUninstallString){throw ''Registered uninstall metadata changed after confirmation; refusing to execute.''}','if((Get-RegistryStringProperty -Object $fresh -Name ''DisplayName'') -ne $entry.DisplayName -or (Get-RegistryStringProperty -Object $fresh -Name ''Publisher'') -ne $entry.Publisher -or (Get-RegistryStringProperty -Object $fresh -Name ''QuietUninstallString'') -ne $entry.QuietUninstallString){throw ''Registered uninstall metadata changed after confirmation; refusing to execute.''}')
$brokerText=$brokerText.Replace('$freshCommand=Convert-TrustedQuietUninstallCommand -Command ([string]$fresh.QuietUninstallString)','$freshCommand=Convert-TrustedQuietUninstallCommand -Command (Get-RegistryStringProperty -Object $fresh -Name ''QuietUninstallString'')')
Set-Content -LiteralPath $broker -Value $brokerText -Encoding UTF8 -NoNewline

# Wire the non-elevated failure reporter into Start-Agent.
Replace-Once $agent "$brokerClient=Join-Path `$systemRoot 'Broker-Request.ps1'" "$brokerClient=Join-Path `$systemRoot 'Broker-Request.ps1'`r`n`$failureReporter=Join-Path `$systemRoot 'Failure-Reporter.ps1'"

$old=@'
Finish with the result, evidence/verification, any remaining uncertainty, and the next useful step only if needed.
Reply in the same language as the user's task.
'@
$new=@'
Finish with the result, evidence/verification, any remaining uncertainty, and the next useful step only if needed.
Reply in the same language as the user's task.

TASK OUTCOME PROTOCOL:
- Your final answer MUST end with exactly one machine-readable line: DRSW_TASK_STATUS: SUCCESS, DRSW_TASK_STATUS: FAILURE, DRSW_TASK_STATUS: BLOCKED, or DRSW_TASK_STATUS: DECLINED.
- SUCCESS means the user's requested goal was actually completed and verified, not merely investigated.
- FAILURE means an attempted task/action failed and the user's requested goal remains incomplete.
- BLOCKED means a concrete external/system prerequisite prevents completion after the allowed recovery paths were exhausted.
- DECLINED means the user explicitly declined a broker-owned confirmation; do not classify that as a software failure.
- Do not mention or explain this protocol line elsewhere in the answer. Dr.Swinux removes it before displaying the answer to the user.
'@
Replace-Once $agent $old $new

$old=@'
try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}

if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    Show-ResultHeader
    Get-Content -LiteralPath $finalPath -Encoding UTF8
    Write-Host ''
    Write-Host '────────────────────────────────────────'
    Write-Host 'Отчёт сохранён.'
} else { Stop-WithMessage ("Задача завершилась без итогового ответа. Подробности: {0}" -f $codexStderr) }
if($codexExit -ne 0){ Stop-WithMessage ("Задача завершилась с ошибкой {0}. Подробности: {1}" -f $codexExit,$codexStderr) }
'@
$new=@'
try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}

$taskOutcome='UNKNOWN'
$finalText=''
if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    try {$finalText=Get-Content -LiteralPath $finalPath -Raw -Encoding UTF8} catch {$finalText=''}
    $statusMatches=[regex]::Matches($finalText,'(?im)^\s*DRSW_TASK_STATUS:\s*(SUCCESS|FAILURE|BLOCKED|DECLINED)\s*$')
    if($statusMatches.Count -eq 1){
        $taskOutcome=$statusMatches[0].Groups[1].Value.ToUpperInvariant()
        $finalText=[regex]::Replace($finalText,'(?im)^\s*DRSW_TASK_STATUS:\s*(?:SUCCESS|FAILURE|BLOCKED|DECLINED)\s*\r?\n?','').TrimEnd()
        Set-Content -LiteralPath $finalPath -Value $finalText -Encoding UTF8 -NoNewline
    }
}
if($codexExit -ne 0){$taskOutcome='FAILURE'}
Write-PreAgentLog -Stage 'task-outcome' -Status $taskOutcome -Detail ('codexExit={0}; finalExists={1}' -f $codexExit,(Test-Path -LiteralPath $finalPath -PathType Leaf))

if($taskOutcome -in @('FAILURE','BLOCKED','UNKNOWN')){
    try {
        if(-not(Test-Path -LiteralPath $failureReporter -PathType Leaf)){throw 'Failure-Reporter.ps1 not found.'}
        $report=@(& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $failureReporter -Session $session -Status $taskOutcome -CodexExit $codexExit -Task $Task -ReportsRoot $reportsRoot -ProjectRoot $root)
        $reportObject=@($report | Where-Object {$_ -and $_.PSObject.Properties['Bundle']}) | Select-Object -Last 1
        if($null -ne $reportObject){
            Write-PreAgentLog -Stage 'failure-reporter' -Status $(if([bool]$reportObject.Sent){'SENT'}else{'OUTBOX'}) -Detail ('bundle={0}; transport={1}; sendError={2}' -f $reportObject.Bundle,$reportObject.Transport,$reportObject.SendError)
            Show-Status ('Диагностический пакет ошибки подготовлен автоматически: {0}' -f $reportObject.Bundle)
            if([bool]$reportObject.Sent){Show-Status 'Диагностический пакет отправлен настроенному HTTPS relay.'}
        } else {Write-PreAgentLog -Stage 'failure-reporter' -Status 'WARN' -Detail 'reporter returned no structured result'}
    } catch {
        Write-PreAgentLog -Stage 'failure-reporter' -Status 'ERROR' -Detail $_.Exception.Message
    }
}

if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    Show-ResultHeader
    Get-Content -LiteralPath $finalPath -Encoding UTF8
    Write-Host ''
    Write-Host '────────────────────────────────────────'
    Write-Host 'Отчёт сохранён.'
} else { Stop-WithMessage ("Задача завершилась без итогового ответа. Подробности: {0}" -f $codexStderr) }
if($codexExit -ne 0){ Stop-WithMessage ("Задача завершилась с ошибкой {0}. Подробности: {1}" -f $codexExit,$codexStderr) }
'@
Replace-Once $agent $old $new

Set-Content -LiteralPath $version -Value 'Dr.Swinux v1.5.51-final' -Encoding UTF8 -NoNewline

# Parse all production PowerShell.
$parseErrors=@()
Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){$parseErrors+=$errors}
}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}

$brokerFinal=Get-Content -LiteralPath $broker -Raw -Encoding UTF8
$agentFinal=Get-Content -LiteralPath $agent -Raw -Encoding UTF8
if($brokerFinal -notmatch 'function Get-RegistryStringProperty'){throw 'StrictMode-safe registry helper missing'}
$uninstallBlock=[regex]::Match($brokerFinal,'(?s)function Get-TrustedHklmInstalledMatches \{.*?function Convert-TrustedQuietUninstallCommand \{').Value
if($uninstallBlock -match '\$item\.(?:DisplayName|Publisher|DisplayVersion|QuietUninstallString)'){throw 'Unsafe optional registry property access remains in trusted uninstall scan'}
if($agentFinal -notmatch 'DRSW_TASK_STATUS: SUCCESS'){throw 'Task outcome protocol missing'}
if($agentFinal -notmatch "@\('FAILURE','BLOCKED','UNKNOWN'\)"){throw 'Failure reporter outcome gate missing'}
if($agentFinal -notmatch 'Failure-Reporter\.ps1'){throw 'Failure reporter wiring missing'}

# Reporter privacy + functional smoke test using a synthetic session.
$testRoot=Join-Path $env:RUNNER_TEMP 'drs-failure-test'
$testReports=Join-Path $testRoot 'reports'
$testSession=Join-Path $testReports 'TEST_codex'
New-Item -ItemType Directory -Path (Join-Path $testSession 'broker') -Force|Out-Null
Set-Content -LiteralPath (Join-Path $testSession 'preflight.log') -Value "root=$testRoot token=sk_FAKEFAKEFAKEFAKEFAKE" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $testSession 'codex-error.log') -Value 'synthetic failure' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $testSession 'final-answer.txt') -Value 'synthetic result' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $testSession 'broker\broker.log') -Value 'ERROR synthetic' -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $testRoot 'system') -Force|Out-Null
Copy-Item $config (Join-Path $testRoot 'system\failure-reporting.json')
Set-Content -LiteralPath (Join-Path $testRoot 'system\VERSION.txt') -Value 'Dr.Swinux test' -Encoding UTF8
$result=& $reporter -Session $testSession -Status FAILURE -CodexExit 0 -Task 'synthetic task' -ReportsRoot $testReports -ProjectRoot $testRoot
if(-not(Test-Path -LiteralPath $result.Bundle -PathType Leaf)){throw 'Failure reporter smoke test did not create ZIP'}
$expanded=Join-Path $env:RUNNER_TEMP 'drs-failure-expanded'
Expand-Archive -LiteralPath $result.Bundle -DestinationPath $expanded -Force
$all=(Get-ChildItem $expanded -Recurse -File|ForEach-Object{Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue}) -join "`n"
if($all -match 'sk_FAKEFAKEFAKEFAKEFAKE'){throw 'Failure reporter token redaction failed'}
if($all -match [regex]::Escape($testRoot)){throw 'Failure reporter path redaction failed'}
if($all -notmatch 'synthetic failure'){throw 'Failure reporter omitted diagnostic content'}

# A SUCCESS outcome is gated in Start-Agent and therefore must not invoke reporter; assert the gate text itself is exact.
if(([regex]::Matches($agentFinal,[regex]::Escape("if(`$taskOutcome -in @('FAILURE','BLOCKED','UNKNOWN'))"))).Count -ne 1){throw 'Failure-only reporter gate changed'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Start-Agent.ps1 system/VERSION.txt system/Failure-Reporter.ps1 system/failure-reporting.json
git commit -m 'Add automatic failure diagnostic reporter and fix uninstall registry scan'
git push
