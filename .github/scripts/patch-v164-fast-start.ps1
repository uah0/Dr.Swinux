$ErrorActionPreference='Stop'
$repo=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$agentPath=Join-Path $repo 'system\Start-Agent.ps1'
$versionPath=Join-Path $repo 'system\VERSION.txt'
$agent=Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8

# 1) Start the visible task timer immediately after the task is accepted/no-task is resolved.
$anchor=@'
if(Test-NoTask -Text $Task){
    Write-PreAgentLog -Stage 'task-input' -Status 'NO_TASK' -Detail 'normalized no-task phrase; stopping before environment/auth/broker/Codex'
    Show-Status 'Диагностика не требуется. Работа завершена.'
    exit 0
}

$computer=
'@
$replacement=@'
if(Test-NoTask -Text $Task){
    Write-PreAgentLog -Stage 'task-input' -Status 'NO_TASK' -Detail 'normalized no-task phrase; stopping before environment/auth/broker/Codex'
    Show-Status 'Диагностика не требуется. Работа завершена.'
    exit 0
}

$script:taskTimer=Start-LargeTaskTimer
Write-PreAgentLog -Stage 'task-timer' -Status 'START' -Detail 'visible timer started before runtime/auth/broker preflight'

$computer=
'@
if(-not $agent.Contains($anchor)){throw 'task timer insertion anchor not found'}
$agent=$agent.Replace($anchor,$replacement)

# 2) Reuse the version result already obtained during runtime validation. Only re-probe after setup actually ran.
$old=@'
foreach($requiredPath in @($codex,$codeModeHost,$commandRunner,$sandboxSetup)){
    if(-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)){ Stop-WithMessage ("После подготовки не найден компонент Codex: {0}" -f $requiredPath) }
}
try {
    $finalCodexVersion=(& $codex --version 2>&1 | Out-String).Trim()
    $finalCodexExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($finalCodexExit -eq 0){'READY'}else{'WARN'}) -Detail ('exit={0}; version={1}; CODEX_HOME={2}' -f $finalCodexExit,$finalCodexVersion,$codexHome)
} catch { Write-PreAgentLog -Stage 'codex-runtime' -Status 'WARN' -Detail ('final version probe failed: {0}' -f $_.Exception.Message) }

$authLog=
'@
$new=@'
foreach($requiredPath in @($codex,$codeModeHost,$commandRunner,$sandboxSetup)){
    if(-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)){ Stop-WithMessage ("После подготовки не найден компонент Codex: {0}" -f $requiredPath) }
}
if($mainCliValid -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent){
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_CACHED' -Detail ('version={0}; CODEX_HOME={1}; duplicate --version probe skipped' -f $versionText,$codexHome)
} else {
    try {
        $finalCodexVersion=(& $codex --version 2>&1 | Out-String).Trim()
        $finalCodexExit=$LASTEXITCODE
        if($finalCodexExit -ne 0){ Stop-WithMessage ("Codex после подготовки не прошёл проверку версии. Код: {0}" -f $finalCodexExit) }
        Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_AFTER_SETUP' -Detail ('exit={0}; version={1}; CODEX_HOME={2}' -f $finalCodexExit,$finalCodexVersion,$codexHome)
    } catch { Stop-WithMessage ("Не удалось проверить Codex после подготовки: {0}" -f $_.Exception.Message) }
}

$authLog=
'@
if(-not $agent.Contains($old)){throw 'duplicate codex version probe anchor not found'}
$agent=$agent.Replace($old,$new)

# 3) Fast auth path: validate local auth.json syntax only. Server auth is validated by the real Codex request; existing retry path handles rejection.
$old=@'
Write-PreAgentLog -Stage 'codex-auth' -Status 'BEGIN' -Detail 'checking portable Codex authorization'
Ensure-CodexAuthentication -Reason 'startup-check'
Initialize-TaskCodexHome
Write-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY' -Detail 'portable PowerShell and Codex runtime are ready; startup auth was confirmed or deferred to the real request after bounded status timeout'
'@
$new=@'
$portableAuthReady=$false
if(Test-Path -LiteralPath $portableAuth -PathType Leaf){
    try {
        $authRaw=Get-Content -LiteralPath $portableAuth -Raw -Encoding UTF8
        if(-not [string]::IsNullOrWhiteSpace($authRaw)){ $null=$authRaw | ConvertFrom-Json -ErrorAction Stop; $portableAuthReady=$true }
    } catch { $portableAuthReady=$false }
}
if($portableAuthReady){
    Write-PreAgentLog -Stage 'codex-auth' -Status 'FAST_PATH' -Detail 'valid local auth.json present; startup login status probe skipped; real Codex request validates server auth'
} else {
    Write-PreAgentLog -Stage 'codex-auth' -Status 'LOGIN_CHECK_REQUIRED' -Detail 'portable auth state missing or invalid; running interactive authentication check'
    Ensure-CodexAuthentication -Reason 'startup-check'
}
Initialize-TaskCodexHome
Write-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY' -Detail 'portable runtime ready; redundant Codex version/auth probes skipped when local state is valid'
'@
if(-not $agent.Contains($old)){throw 'startup auth anchor not found'}
$agent=$agent.Replace($old,$new)

# 4) Use the already-running timer inside Codex execution instead of creating/stopping a second timer.
$agent=$agent.Replace('$stdoutStream=$null; $stderrStream=$null; $process=$null; $timer=$null','$stdoutStream=$null; $stderrStream=$null; $process=$null')
$old=@'
        $process.StandardInput.Write($promptText)
        $process.StandardInput.Close()
        $timer=Start-LargeTaskTimer
        while(-not $process.HasExited){ Update-LargeTaskTimer -State $timer; Start-Sleep -Milliseconds 150; $process.Refresh() }
        Update-LargeTaskTimer -State $timer -Force
'@
$new=@'
        $process.StandardInput.Write($promptText)
        $process.StandardInput.Close()
        while(-not $process.HasExited){ Update-LargeTaskTimer -State $script:taskTimer; Start-Sleep -Milliseconds 150; $process.Refresh() }
        Update-LargeTaskTimer -State $script:taskTimer -Force
'@
if(-not $agent.Contains($old)){throw 'Codex timer loop anchor not found'}
$agent=$agent.Replace($old,$new)
$agent=$agent.Replace('        if($null -ne $timer){ Stop-LargeTaskTimer -State $timer }'+"`r`n",'')
$agent=$agent.Replace('        if($null -ne $timer){ Stop-LargeTaskTimer -State $timer }'+"`n",'')

# 5) Stop the single timer once the whole task pipeline is complete, immediately before rendering the result.
$old=@'
if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    Show-ResultHeader
'@
$new=@'
if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    if($null -ne $script:taskTimer){ Stop-LargeTaskTimer -State $script:taskTimer; Write-PreAgentLog -Stage 'task-timer' -Status 'STOP' -Detail 'task pipeline completed' }
    Show-ResultHeader
'@
if(-not $agent.Contains($old)){throw 'result timer stop anchor not found'}
$agent=$agent.Replace($old,$new)

# 6) Encourage high-signal one-pass handling for simple fact checks.
$old='Once the available evidence is sufficient to answer the user''s task with stated uncertainty, stop investigating instead of collecting redundant evidence.'
$new=$old+"`nFor simple read-only fact checks, use the highest-signal direct source first and stop immediately when it gives a conclusive answer; do not fan out into redundant alternative probes."
if(-not $agent.Contains($old)){throw 'prompt efficiency anchor not found'}
$agent=$agent.Replace($old,$new)

Set-Content -LiteralPath $agentPath -Value $agent -Encoding UTF8
Set-Content -LiteralPath $versionPath -Value "Dr.Swinux v1.5.64-final`n" -Encoding UTF8

$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($agentPath,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw (($errors|ForEach-Object{$_.Message}) -join "`n")}
$check=Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8
foreach($needle in @('READY_CACHED','codex-auth'' -Status ''FAST_PATH','$script:taskTimer=Start-LargeTaskTimer','Update-LargeTaskTimer -State $script:taskTimer','highest-signal direct source first')){
    if(-not $check.Contains($needle)){throw "missing invariant: $needle"}
}
if($check -match '\$timer=Start-LargeTaskTimer'){throw 'old delayed timer start remains'}
if($check -match 'danger-full-access'){throw 'unsafe sandbox regression'}
Write-Host 'v1.5.64 fast-start migration validated.'
