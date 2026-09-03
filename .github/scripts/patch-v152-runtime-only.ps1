$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Replace-Once([string]$Path,[string]$Old,[string]$New){$t=Get-Content $Path -Raw -Encoding UTF8;$c=([regex]::Matches($t,[regex]::Escape($Old))).Count;if($c-ne1){throw "Expected one marker in $Path, found $c"};Set-Content $Path $t.Replace($Old,$New) -Encoding UTF8 -NoNewline}
$agent='system/Start-Agent.ps1'
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
                    } else {Write-PreAgentLog -Stage 'auto-repair' -Status 'LOCAL_ONLY' -Detail 'DRSW_GITHUB_TOKEN is not configured; validated candidate remains in repair outbox'}
                } catch {Write-PreAgentLog -Stage 'auto-repair' -Status 'ERROR' -Detail $_.Exception.Message;Show-Status 'Repair-agent не смог подготовить безопасный кандидат. Исходный failure bundle сохранён.'}
            }
        } else {Write-PreAgentLog -Stage 'failure-reporter' -Status 'WARN' -Detail 'reporter returned no structured result'}
'@
Replace-Once $agent $old $new
Set-Content 'system/VERSION.txt' 'Dr.Swinux v1.5.52-final' -Encoding UTF8 -NoNewline
$parseErrors=@();Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e);if($e){$parseErrors+=$e}};if($parseErrors){throw 'PowerShell parser audit failed'}
$all=(Get-ChildItem system -Recurse -File -Include '*.ps1','*.cmd'|ForEach-Object{Get-Content $_.FullName -Raw})-join"`n";foreach($n in @('approval_policy="never"','windows.sandbox="unelevated"','workspace-write')){if($all-notmatch[regex]::Escape($n)){throw "Security invariant missing: $n"}};if($all-match'danger-full-access'){throw 'Unsafe sandbox literal in production source'}
$a=Get-Content $agent -Raw;foreach($n in @('Auto-Repair.ps1','Submit-RepairCandidate.ps1','DRSW_GITHUB_TOKEN','PR_SUBMITTED')){if($a-notmatch[regex]::Escape($n)){throw "Runtime integration missing: $n"}}
git config user.name 'github-actions[bot]';git config user.email '41898282+github-actions[bot]@users.noreply.github.com';git add system/Start-Agent.ps1 system/VERSION.txt;git commit -m 'Wire isolated Codex auto-repair into failed tasks';git push
