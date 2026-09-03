$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-Once([string]$Path,[string]$Old,[string]$New){
 $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
 $count=([regex]::Matches($text,[regex]::Escape($Old))).Count
 if($count-ne1){throw "Expected one marker in $Path, found $count"}
 Set-Content -LiteralPath $Path -Value $text.Replace($Old,$New) -Encoding UTF8 -NoNewline
}
$agent='system/Start-Agent.ps1';$version='system/VERSION.txt';$release='.github/workflows/release.yml'
foreach($p in @('system/Auto-Repair.ps1','system/Submit-RepairCandidate.ps1','system/auto-repair.json')){if(-not(Test-Path $p -PathType Leaf)){throw "Missing $p"}}

Replace-Once $agent '$failureReporter=Join-Path $systemRoot ''Failure-Reporter.ps1''' '$failureReporter=Join-Path $systemRoot ''Failure-Reporter.ps1''`r`n$autoRepair=Join-Path $systemRoot ''Auto-Repair.ps1''`r`n$repairSubmitter=Join-Path $systemRoot ''Submit-RepairCandidate.ps1''`r`n$autoRepairConfig=Join-Path $systemRoot ''auto-repair.json'''

$old=@'
            if([bool]$reportObject.Sent){Show-Status 'Диагностический пакет отправлен настроенному HTTPS relay.'}
        } else {Write-PreAgentLog -Stage 'failure-reporter' -Status 'WARN' -Detail 'reporter returned no structured result'}
'@
$new=@'
            if([bool]$reportObject.Sent){Show-Status 'Диагностический пакет отправлен настроенному HTTPS relay.'}

            $repairConfig=$null
            try {if(Test-Path -LiteralPath $autoRepairConfig -PathType Leaf){$repairConfig=Get-Content -LiteralPath $autoRepairConfig -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}} catch {}
            $repairEnabled=($null -ne $repairConfig -and $repairConfig.PSObject.Properties['enabled'] -and [bool]$repairConfig.enabled)
            if($repairEnabled -and (Test-Path -LiteralPath $autoRepair -PathType Leaf)){
                Show-Status 'Запускаю изолированного repair-agent для анализа ошибки и подготовки исправления...'
                try {
                    $repairOutput=@(& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $autoRepair -Session $session -Bundle ([string]$reportObject.Bundle) -ReportsRoot $reportsRoot -ProjectRoot $root -Codex $codex -CodexHome $codexHome)
                    $repair=@($repairOutput|Where-Object{$_ -and $_.PSObject.Properties['Candidate']})|Select-Object -Last 1
                    if($null -eq $repair){throw 'Auto-Repair.ps1 returned no repair candidate.'}
                    Write-PreAgentLog -Stage 'auto-repair' -Status 'CANDIDATE' -Detail ('candidate={0}; changedFiles={1}' -f $repair.Candidate,$repair.ChangedFiles)
                    Show-Status ('Repair-agent подготовил проверенный кандидат: {0}' -f $repair.Candidate)

                    $submitWhenToken=($repairConfig.PSObject.Properties['autoSubmitWhenTokenPresent'] -and [bool]$repairConfig.autoSubmitWhenTokenPresent)
                    $repairToken=[Environment]::GetEnvironmentVariable('DRSW_GITHUB_TOKEN','Process')
                    if($submitWhenToken -and -not[string]::IsNullOrWhiteSpace($repairToken) -and (Test-Path -LiteralPath $repairSubmitter -PathType Leaf)){
                        try {
                            $repo=if($repairConfig.PSObject.Properties['repository']){[string]$repairConfig.repository}else{'uah0/Dr.Swinux'}
                            $baseBranch=if($repairConfig.PSObject.Properties['baseBranch']){[string]$repairConfig.baseBranch}else{'main'}
                            $submitted=@(& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $repairSubmitter -CandidateDirectory ([string]$repair.CandidateDirectory) -Repository $repo -BaseBranch $baseBranch)|Where-Object{$_ -and $_.PSObject.Properties['PullRequest']}|Select-Object -Last 1
                            if($null -ne $submitted){Write-PreAgentLog -Stage 'auto-repair' -Status 'PR_SUBMITTED' -Detail ('pr={0}; branch={1}' -f $submitted.PullRequest,$submitted.Branch);Show-Status ('Кандидат автоматически отправлен в GitHub как draft PR: {0}' -f $submitted.PullRequest)}
                        } catch {Write-PreAgentLog -Stage 'auto-repair' -Status 'PR_SUBMIT_ERROR' -Detail $_.Exception.Message;Show-Status 'Кандидат сохранён локально; автоматическая отправка PR не удалась.'}
                    } else {
                        Write-PreAgentLog -Stage 'auto-repair' -Status 'LOCAL_ONLY' -Detail 'DRSW_GITHUB_TOKEN is not configured; validated candidate remains in repair outbox'
                    }
                } catch {
                    Write-PreAgentLog -Stage 'auto-repair' -Status 'ERROR' -Detail $_.Exception.Message
                    Show-Status 'Repair-agent не смог подготовить безопасный кандидат. Исходный failure bundle сохранён.'
                }
            }
        } else {Write-PreAgentLog -Stage 'failure-reporter' -Status 'WARN' -Detail 'reporter returned no structured result'}
'@
Replace-Once $agent $old $new
Set-Content -LiteralPath $version -Value 'Dr.Swinux v1.5.52-final' -Encoding UTF8 -NoNewline

# Harden permanent release audit and ZIP manifest.
$releaseText=Get-Content $release -Raw -Encoding UTF8
$releaseText=$releaseText.Replace("'system/catalog/trusted-packages.json','system/tools/Build-TrustedPackageCatalog.ps1',","'system/catalog/trusted-packages.json','system/tools/Build-TrustedPackageCatalog.ps1','system/Failure-Reporter.ps1','system/failure-reporting.json','system/Auto-Repair.ps1','system/Submit-RepairCandidate.ps1','system/auto-repair.json',")
$releaseText=$releaseText.Replace("'system/catalog/trusted-packages.json','system/tools/Build-TrustedPackageCatalog.ps1','system/assets/branding/dr-swinux.png'","'system/catalog/trusted-packages.json','system/tools/Build-TrustedPackageCatalog.ps1','system/Failure-Reporter.ps1','system/failure-reporting.json','system/Auto-Repair.ps1','system/Submit-RepairCandidate.ps1','system/auto-repair.json','system/assets/branding/dr-swinux.png'")
$needle="          if(`$agent-notmatch'UninstallTrustedPackage correlates the packaged catalog with an HKLM uninstall entry'){throw 'Agent trusted uninstall boundary missing'}`r`n"
$extra=@"
          if(`$agent-notmatch'Auto-Repair\\.ps1'){throw 'Auto-repair wiring missing'}
          `$repair=Get-Content 'system/Auto-Repair.ps1' -Raw
          if(`$repair-notmatch'windows\\.sandbox=\\"unelevated\\"'){throw 'Repair-agent unelevated sandbox missing'}
          if(`$repair-notmatch'approval_policy=\\"never\\"'){throw 'Repair-agent approval policy missing'}
          if(`$repair-notmatch'workspace-write'){throw 'Repair-agent workspace-write missing'}
          if(`$repair-match'danger-full-access'){throw 'Unsafe repair-agent sandbox'}
          if(`$repair-notmatch'DRSW_GITHUB_TOKEN'){throw 'Repair-agent GitHub token isolation audit missing'}
          `$submit=Get-Content 'system/Submit-RepairCandidate.ps1' -Raw
          if(`$submit-notmatch"Repository-ne'uah0/Dr.Swinux'"){throw 'Repair submit repository allowlist missing'}
          if(`$submit-notmatch'DRSW_GITHUB_TOKEN'){throw 'Repair submit token boundary missing'}
"@
if($releaseText.Contains($needle)){$releaseText=$releaseText.Replace($needle,$needle+$extra)}else{throw 'Release audit insertion marker missing'}
Set-Content $release $releaseText -Encoding UTF8 -NoNewline

# Production parser and static invariants.
$parseErrors=@();Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e);if($e){$parseErrors+=$e}}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}
$agentText=Get-Content $agent -Raw
foreach($n in @('Auto-Repair.ps1','Submit-RepairCandidate.ps1','DRSW_GITHUB_TOKEN','Repair-agent подготовил проверенный кандидат')){if($agentText-notmatch[regex]::Escape($n)){throw "Agent auto-repair integration missing: $n"}}
$repairText=Get-Content 'system/Auto-Repair.ps1' -Raw
foreach($n in @('approval_policy="never"','windows.sandbox="unelevated"','workspace-write','DRSW_GITHUB_TOKEN','Repair candidate changes too many files')){if($repairText-notmatch[regex]::Escape($n)){throw "Auto-repair invariant missing: $n"}}
if($repairText-match'danger-full-access'){throw 'Auto-repair unsafe sandbox'}

# Synthetic validator test without running Codex: parse scripts and ensure configs are strict/default-safe.
$config=Get-Content 'system/auto-repair.json' -Raw|ConvertFrom-Json
if(-not[bool]$config.enabled){throw 'Auto-repair must be enabled'}
if([string]$config.repository-ne'uah0/Dr.Swinux'-or[string]$config.baseBranch-ne'main'){throw 'Auto-repair repository config invalid'}
$failure=Get-Content 'system/failure-reporting.json' -Raw|ConvertFrom-Json
if([string]$failure.transport-ne'outbox'){throw 'Failure reporter default transport must remain outbox'}

git config user.name 'github-actions[bot]';git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Start-Agent.ps1 system/VERSION.txt system/Auto-Repair.ps1 system/Submit-RepairCandidate.ps1 system/auto-repair.json .github/workflows/release.yml
git commit -m 'Add isolated Codex self-healing repair pipeline'
git push
