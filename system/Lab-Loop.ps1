param([Parameter(Mandatory=$true)][string]$Task,[ValidateRange(1,5)][int]$MaxIterations=3)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$systemRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $systemRoot
$reports=Join-Path $root 'reports'
$lab=Join-Path $reports '_lab'
$pwsh=Join-Path $root 'tools\PowerShell\pwsh.exe'
$codex=Join-Path $root 'tools\Codex\codex.exe'
$env:CODEX_HOME=Join-Path $root 'tools\CodexHome'
$start=Join-Path $systemRoot 'Start-DoctorSwinux.ps1'
$audit=Join-Path $systemRoot 'Audit-LabCandidate.ps1'
New-Item -ItemType Directory -Path $lab -Force|Out-Null
foreach($n in @('CODEX_ACCESS_TOKEN','OPENAI_API_KEY')){Remove-Item -LiteralPath ('Env:'+$n) -ErrorAction SilentlyContinue}
if(-not(Test-Path $pwsh -PathType Leaf)-or-not(Test-Path $codex -PathType Leaf)){throw 'Run Dr.Swinux normally once before LAB MODE.'}

function Run-Codex([string]$Work,[string]$Prompt,[string]$Prefix){
    $p=Join-Path $Work ($Prefix+'-prompt.txt');$o=Join-Path $Work ($Prefix+'-console.log');$e=Join-Path $Work ($Prefix+'-error.log')
    Set-Content $p $Prompt -Encoding UTF8
    Get-Content $p -Raw -Encoding UTF8|& $codex exec --config 'approval_policy="never"' --config 'windows.sandbox="unelevated"' --sandbox workspace-write --cd $Work --skip-git-repo-check - 1>$o 2>$e
    return $LASTEXITCODE
}
function Latest-Session([datetime]$After){
    return @(Get-ChildItem $reports -Directory|Where-Object{$_.Name-notlike'_*'-and$_.LastWriteTime-ge$After}|Sort-Object LastWriteTime -Descending|Select-Object -First 1)[0]
}
function Attempt {
    $before=Get-Date;& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $start -Task $Task -SingleTask;$taskExit=$LASTEXITCODE
    $s=Latest-Session $before.AddSeconds(-2);if($null-eq$s){throw 'Task report session not found.'}
    $answerPath=Join-Path $s.FullName 'final-answer.txt';$errPath=Join-Path $s.FullName 'codex-error.log'
    $answer=if(Test-Path $answerPath){Get-Content $answerPath -Raw -Encoding UTF8}else{''};$err=if(Test-Path $errPath){Get-Content $errPath -Raw -Encoding UTF8}else{''}
    $prompt=@"
Classify this REAL Dr.Swinux attempt. Do not solve it. Write only case-result.json in this workspace.
TASK: $Task
PROCESS EXIT: $taskExit
FINAL ANSWER:
$answer
ERROR LOG:
$err
JSON fields: outcome=solved|partial|blocked|unknown; blocker_type=none|reasoning|capability|verification|tool|permission|user|external|protocol|unknown; blocker=short concrete reason; evidence=short classification evidence. Use solved only if the original goal was completed and meaningfully verified. Distinguish missing Dr.Swinux capability from permission/user/external blockers.
"@
    $rc=Run-Codex $s.FullName $prompt 'lab-classifier';$rp=Join-Path $s.FullName 'case-result.json'
    if($rc-ne0-or-not(Test-Path $rp)){return [pscustomobject]@{outcome='unknown';blocker_type='protocol';blocker='classifier failed';session=$s.FullName}}
    $r=Get-Content $rp -Raw -Encoding UTF8|ConvertFrom-Json
    return [pscustomobject]@{outcome=[string]$r.outcome;blocker_type=[string]$r.blocker_type;blocker=[string]$r.blocker;session=$s.FullName}
}
function Patch([object]$a,[int]$i){
    $ir=Join-Path $lab ('iteration-{0:00}-{1}'-f$i,(Get-Date -Format'yyyyMMdd-HHmmss'));New-Item $ir -ItemType Directory -Force|Out-Null
    $candidate=Join-Path $ir 'system';Copy-Item $systemRoot $candidate -Recurse -Force
    $prompt=@"
Develop Dr.Swinux only because this REAL task exposed a blocker.
ORIGINAL TASK: $Task
FAILED SESSION: $($a.session)
BLOCKER TYPE: $($a.blocker_type)
BLOCKER: $($a.blocker)
Work only in staged system/: $candidate
Inspect the staged source and failed reports. If no code change is genuinely justified, change nothing and write LAB-NO-PATCH.txt. Otherwise make the smallest GENERIC fix; never hardcode this task, machine answer, symptom, device, package, path or diagnosis. Write LAB-PATCH.txt with root cause, files changed, why generic, and how the SAME task should verify it.
BOUNDARY: never modify Privileged-Broker.ps1, Broker-Request.ps1, Audit-LabCandidate.ps1, Lab-Loop.ps1, Setup-PortableCodex.ps1, Update-DrSwintus.ps1 or VERSION.txt. Never weaken confirmations, deny rules, sandboxing, auth isolation, updater verification or audit. Never add arbitrary elevated command/script execution or unrestricted Codex sandbox access. Codex remains unelevated with approval_policy=never and workspace-write. A missing privileged capability must remain a blocker for human review.
"@
    if((Run-Codex $candidate $prompt 'lab-developer')-ne0){throw ('Developer Codex failed: '+$ir)}
    if(Test-Path (Join-Path $candidate 'LAB-NO-PATCH.txt')){return [pscustomobject]@{applied=$false;path=$ir;reason='no justified automatic patch'}}
    if(-not(Test-Path (Join-Path $candidate 'LAB-PATCH.txt'))){return [pscustomobject]@{applied=$false;path=$ir;reason='patch record missing'}}
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $audit -CandidateSystem $candidate -StableSystem $systemRoot;if($LASTEXITCODE-ne0){throw ('Candidate audit failed: '+$ir)}
    $backup=Join-Path $ir 'stable-before';Copy-Item $systemRoot $backup -Recurse -Force
    $protected=@('VERSION.txt','Privileged-Broker.ps1','Broker-Request.ps1','Audit-LabCandidate.ps1','Lab-Loop.ps1','Setup-PortableCodex.ps1','Update-DrSwintus.ps1')
    foreach($x in Get-ChildItem $systemRoot -Force){if($x.Name-notin$protected){Remove-Item $x.FullName -Recurse -Force}}
    foreach($x in Get-ChildItem $candidate -Force){if($x.Name-notin($protected+@('LAB-PATCH.txt','LAB-NO-PATCH.txt'))){Copy-Item $x.FullName (Join-Path $systemRoot $x.Name) -Recurse -Force}}
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $audit -CandidateSystem $systemRoot -StableSystem $backup
    if($LASTEXITCODE-ne0){foreach($x in Get-ChildItem $systemRoot -Force){Remove-Item $x.FullName -Recurse -Force};Copy-Item (Join-Path $backup '*') $systemRoot -Recurse -Force;throw 'Post-promotion audit failed; stable system restored.'}
    return [pscustomobject]@{applied=$true;path=$ir;reason='guarded candidate promoted locally'}
}

Write-Host 'Dr.Swinux LAB MODE';Write-Host ('Original task: '+$Task)
for($i=0;$i-le$MaxIterations;$i++){
    Write-Host ('=== ATTEMPT {0} ==='-f($i+1));$a=Attempt;Write-Host ('Outcome: '+$a.outcome);Write-Host ('Session: '+$a.session)
    if($a.outcome-eq'solved'){Write-Host 'LAB RESULT: solved and verified.';exit 0}
    if($i-ge$MaxIterations){Write-Host 'LAB RESULT: iteration limit reached.';exit 2}
    if($a.blocker_type-notin@('capability','reasoning','verification','tool','protocol')){Write-Host ('LAB RESULT: blocker requires external/human handling: '+$a.blocker_type);exit 3}
    Write-Host ('Blocker: '+$a.blocker);$p=Patch $a ($i+1);Write-Host ('Patch: '+$p.reason);Write-Host ('Lab files: '+$p.path);if(-not$p.applied){exit 4}
    Write-Host 'Repeating the EXACT SAME original task on the audited local candidate.'
}
