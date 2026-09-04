param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$utf8NoBom=[System.Text.UTF8Encoding]::new($false)
try { [Console]::InputEncoding=$utf8NoBom } catch {}
try { [Console]::OutputEncoding=$utf8NoBom } catch {}
$OutputEncoding=$utf8NoBom

function Stop-WithMessage {
    param([string]$Message)
    try { if(Get-Command Write-PreAgentLog -ErrorAction SilentlyContinue){ Write-PreAgentLog -Stage 'start-agent' -Status 'STOP' -Detail $Message } } catch {}
    Write-Host ''
    Write-Host 'ОШИБКА Dr.Swinux:'
    Write-Host $Message
    Write-Host ''
    throw $Message
}

$systemRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $systemRoot
$toolsRoot=Join-Path $root 'tools'
$pwsh=Join-Path $toolsRoot 'PowerShell\pwsh.exe'
$codex=Join-Path $toolsRoot 'Codex\codex.exe'
$codexHome=Join-Path $toolsRoot 'CodexHome'
$setup=Join-Path $systemRoot 'Setup-PortableCodex.ps1'
$brokerServer=Join-Path $systemRoot 'Privileged-Broker.ps1'
$brokerClient=Join-Path $systemRoot 'Broker-Request.ps1'
$failureReporter=Join-Path $systemRoot 'Failure-Reporter.ps1'
$autoRepair=Join-Path $systemRoot 'Auto-Repair.ps1'
$repairSubmitter=Join-Path $systemRoot 'Submit-RepairCandidate.ps1'
$autoRepairConfig=Join-Path $systemRoot 'auto-repair.json'
$reportsRoot=Join-Path $root 'reports'
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
$preAgentLog=Join-Path $reportsRoot 'pre-agent.log'
$script:taskLog=$null

function Write-PreAgentLog {
    param(
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Detail=''
    )
    try {
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        $clean=[string]$Detail
        $clean=$clean -replace '[\r\n]+',' '
        $clean=$clean -replace '\s{2,}',' '
        $clean=$clean.Trim()
        $line=if([string]::IsNullOrWhiteSpace($clean)){
            '[{0}] [{1}] {2}' -f $stamp,$Stage,$Status
        } else {
            '[{0}] [{1}] {2} :: {3}' -f $stamp,$Stage,$Status,$clean
        }
        Add-Content -LiteralPath $preAgentLog -Value $line -Encoding UTF8
        if(-not [string]::IsNullOrWhiteSpace($script:taskLog)){
            Add-Content -LiteralPath $script:taskLog -Value $line -Encoding UTF8
        }
    } catch {}
}

function Get-DrSwintusVersionLabel {
    $versionFile=Join-Path $systemRoot 'VERSION.txt'
    try {
        if(Test-Path -LiteralPath $versionFile -PathType Leaf){
            return (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
        }
    } catch {}
    return 'Dr.Swinux version unknown'
}

Write-PreAgentLog -Stage 'start-agent' -Status 'BEGIN' -Detail ('pid={0}; version={1}; root={2}; system={3}; reports={4}' -f $PID,(Get-DrSwintusVersionLabel),$root,$systemRoot,$reportsRoot)

trap {
    try {
        $line=$_.InvocationInfo.ScriptLineNumber
        Write-PreAgentLog -Stage 'start-agent' -Status 'UNHANDLED_ERROR' -Detail ('line={0}; message={1}' -f $line,$_.Exception.Message)
    } catch {}
    throw
}

function Show-MainHeader {
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
    $versionFile=Join-Path $systemRoot 'VERSION.txt'
    $displayVersion='Dr.Swinux'
    try {
        if(Test-Path -LiteralPath $versionFile -PathType Leaf){
            $versionText=(Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
            $m=[regex]::Match($versionText,'(?i)Dr\.(?:Swinux|Swintus)\s+v?([0-9]+\.[0-9]+\.[0-9]+)')
            if($m.Success){ $displayVersion=('Dr.Swinux '+$m.Groups[1].Value) }
        }
    } catch {}
    Clear-Host
    Write-Host $displayVersion
    Write-Host '────────────────────────────────────────'
    Write-Host 'Переносной AI-инженер Windows'
    Write-Host ''
}

function Show-Status {
    param([string]$Text)
    Write-Host ''
    Write-Host ('• ' + $Text)
}

function Show-ResultHeader {
    Write-Host ''
    Write-Host '────────────────────────────────────────'
    Write-Host 'Результат'
    Write-Host '────────────────────────────────────────'
    Write-Host ''
}

function Get-LargeTimerLines {
    param([TimeSpan]$Elapsed)
    $font=@{
        '0'=@('███','█ █','█ █','█ █','███')
        '1'=@(' █ ','██ ',' █ ',' █ ','███')
        '2'=@('███','  █','███','█  ','███')
        '3'=@('███','  █','███','  █','███')
        '4'=@('█ █','█ █','███','  █','  █')
        '5'=@('███','█  ','███','  █','███')
        '6'=@('███','█  ','███','█ █','███')
        '7'=@('███','  █','  █','  █','  █')
        '8'=@('███','█ █','███','█ █','███')
        '9'=@('███','█ █','███','  █','███')
        ':'=@('   ',' █ ','   ',' █ ','   ')
    }
    $hours=[Math]::Floor($Elapsed.TotalHours)
    if($hours -gt 99){ $hours=99 }
    $stamp=('{0:00}:{1:00}:{2:00}' -f $hours,$Elapsed.Minutes,$Elapsed.Seconds)
    $lines=@('','','','','')
    foreach($char in $stamp.ToCharArray()){
        $key=[string]$char
        $glyph=$font[$key]
        for($row=0;$row -lt 5;$row++){
            if($lines[$row].Length -gt 0){ $lines[$row]+='  ' }
            $lines[$row]+=$glyph[$row]
        }
    }
    return $lines
}

function Start-LargeTaskTimer {
    $state=[pscustomobject]@{Enabled=$false;Top=0;Width=0;Stopwatch=[System.Diagnostics.Stopwatch]::StartNew();LastSecond=-1}
    try {
        if([Console]::IsOutputRedirected){ return $state }
        Write-Host ''
        Write-Host 'Время выполнения:'
        $state.Width=[Math]::Max([Console]::BufferWidth-1,1)
        foreach($line in (Get-LargeTimerLines -Elapsed ([TimeSpan]::Zero))){ Write-Host $line }
        $state.Top=[Math]::Max([Console]::CursorTop-5,0)
        $state.Enabled=$true
    } catch {}
    return $state
}

function Update-LargeTaskTimer {
    param($State,[switch]$Force)
    if($null -eq $State){ return }
    $second=[int][Math]::Floor($State.Stopwatch.Elapsed.TotalSeconds)
    if((-not $Force) -and ($second -eq $State.LastSecond)){ return }
    $State.LastSecond=$second
    if(-not $State.Enabled){ return }
    try {
        $left=[Console]::CursorLeft
        $top=[Console]::CursorTop
        $width=[Math]::Max([Console]::BufferWidth-1,1)
        $State.Width=$width
        $lines=Get-LargeTimerLines -Elapsed $State.Stopwatch.Elapsed
        for($row=0;$row -lt $lines.Count;$row++){
            [Console]::SetCursorPosition(0,$State.Top+$row)
            $line=$lines[$row]
            if($line.Length -gt $width){ $line=$line.Substring(0,$width) }
            Write-Host -NoNewline ($line.PadRight($width))
        }
        [Console]::SetCursorPosition($left,$top)
    } catch { $State.Enabled=$false }
}

function Stop-LargeTaskTimer {
    param($State)
    if($null -eq $State){ return }
    try {
        $State.Stopwatch.Stop()
        Update-LargeTaskTimer -State $State -Force
        if($State.Enabled){
            $targetTop=$State.Top+5
            if([Console]::CursorTop -lt $targetTop){ [Console]::SetCursorPosition(0,$targetTop) }
            Write-Host ''
        }
    } catch {}
}

function Test-NoTask {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){ return $false }
    $normalized=($Text.Trim().ToLowerInvariant() -replace '\s+',' ')
    return $normalized -in @('нет','нет проблем','проблем нет','ничего','отмена','выход')
}

function Read-TaskWithHistory {
    param([string]$HistoryPath,[string]$Prompt='Опишите задачу')
    $history=@()
    if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){
        try { $history=@(Get-Content -LiteralPath $HistoryPath -Encoding UTF8 | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}) } catch {}
    }
    $index=$history.Count
    $buffer=''
    Write-Host -NoNewline ($Prompt + ': ')
    while($true){
        $key=[Console]::ReadKey($true)
        if($key.Key -eq [ConsoleKey]::Enter){ Write-Host ''; return $buffer }
        if($key.Key -eq [ConsoleKey]::UpArrow){
            if($history.Count -gt 0 -and $index -gt 0){ $index--; $buffer=$history[$index] }
        } elseif($key.Key -eq [ConsoleKey]::DownArrow){
            if($history.Count -gt 0 -and $index -lt $history.Count-1){ $index++; $buffer=$history[$index] }
            elseif($index -lt $history.Count){ $index=$history.Count; $buffer='' }
        } elseif($key.Key -eq [ConsoleKey]::Backspace){
            if($buffer.Length -gt 0){ $buffer=$buffer.Substring(0,$buffer.Length-1) }
        } elseif(-not [char]::IsControl($key.KeyChar)){
            $buffer += $key.KeyChar
        } else { continue }
        try {
            $top=[Console]::CursorTop
            [Console]::SetCursorPosition(0,$top)
            Write-Host -NoNewline ((' ' * [Math]::Max([Console]::BufferWidth-1,1)))
            [Console]::SetCursorPosition(0,$top)
            Write-Host -NoNewline ($Prompt + ': ' + $buffer)
        } catch {}
    }
}

function Write-TaskEnvironmentSnapshot {
    param([string]$Path)
    try {
        $pwdText=''
        try { $pwdText=(Get-Location).Path } catch {}
        Set-Content -LiteralPath $Path -Encoding UTF8 -Value @(
            'PWD='+$pwdText,
            'ROOT='+$root,
            'REPORTS_ROOT='+$reportsRoot,
            'CODEX_HOME='+$codexHome,
            'TEMP='+[string]$env:TEMP,
            'TMP='+[string]$env:TMP,
            'TMPDIR='+[string]$env:TMPDIR,
            'USERPROFILE='+[string]$env:USERPROFILE,
            'HOME='+[string]$env:HOME,
            'LOCALAPPDATA='+[string]$env:LOCALAPPDATA,
            'APPDATA='+[string]$env:APPDATA,
            'SYSTEMDRIVE='+[string]$env:SystemDrive,
            'SYSTEMROOT='+[string]$env:SystemRoot
        )
    } catch {}
}

$historyPath=Join-Path $reportsRoot 'prompt-history.txt'
Write-PreAgentLog -Stage 'ui' -Status 'READY' -Detail 'main prompt is about to be displayed'
Show-MainHeader

$updater=Join-Path $systemRoot 'Update-DrSwintus.ps1'
if((-not $SingleTask) -and (Test-Path -LiteralPath $updater -PathType Leaf)){
    Write-PreAgentLog -Stage 'updater' -Status 'BEGIN' -Detail ('script={0}' -f $updater)
    Show-Status 'Проверяю обновления...'
    $updateLog=Join-Path $reportsRoot 'update-console.log'
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $updater -ProjectRoot $root -Mode Check *> $updateLog
    $updateExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'updater' -Status 'CHECK_EXIT' -Detail ('exit={0}; log={1}' -f $updateExit,$updateLog)
    if($updateExit -eq 10){
        $availablePath=Join-Path $reportsRoot '_update\update-available.json'
        $available=$null
        try { $available=Get-Content -LiteralPath $availablePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        $remoteLabel=if($null -ne $available -and $available.Tag){ [string]$available.Tag } else { 'новая версия' }
        Write-Host ''
        Write-Host ('Доступно обновление Dr.Swinux {0}.' -f $remoteLabel)
        Write-Host '  1 — установить обновление'
        Write-Host '  2 — не обновляться и продолжить на текущей версии'
        $choice=''
        Write-Host -NoNewline 'Выберите 1 или 2: '
        while($choice -notin @('1','2')){
            $key=[Console]::ReadKey($true)
            $candidate=[string]$key.KeyChar
            if($candidate -in @('1','2')){ $choice=$candidate; Write-Host $choice }
        }
        Write-PreAgentLog -Stage 'updater' -Status 'USER_CHOICE' -Detail ('choice={0}; remote={1}' -f $choice,$remoteLabel)
        if($choice -eq '1'){
            Show-Status 'Устанавливаю обновление...'
            & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $updater -ProjectRoot $root -Mode Install *> $updateLog
            $installExit=$LASTEXITCODE
            Write-PreAgentLog -Stage 'updater' -Status 'INSTALL_EXIT' -Detail ('exit={0}; log={1}' -f $installExit,$updateLog)
            if($installExit -eq 20){ Show-Status 'Обновление установлено. Перезапускаю Dr.Swinux...'; exit 23 }
            Show-Status 'Не удалось установить обновление. Продолжаю на текущей версии.'
        } else { Show-Status 'Продолжаю на текущей версии.' }
    } elseif($updateExit -ne 0){ Show-Status 'Не удалось проверить обновления. Продолжаю работу.' }
} elseif($SingleTask){
    Write-PreAgentLog -Stage 'updater' -Status 'SKIP' -Detail 'update check already handled by the persistent task dispatcher'
} else {
    Write-PreAgentLog -Stage 'updater' -Status 'SKIP' -Detail 'Update-DrSwintus.ps1 not found'
}

if([string]::IsNullOrWhiteSpace($Task)){
    Write-PreAgentLog -Stage 'task-input' -Status 'WAITING' -Detail 'waiting for user task in the visible console'
    Write-Host '↑/↓ — история задач'
    Write-Host ''
    $Task=Read-TaskWithHistory -HistoryPath $historyPath -Prompt 'Опишите задачу'
}
if([string]::IsNullOrWhiteSpace($Task)){
    Write-PreAgentLog -Stage 'task-input' -Status 'FAIL' -Detail 'empty task'
    Stop-WithMessage 'Задача не может быть пустой.'
}
Write-PreAgentLog -Stage 'task-input' -Status 'ACCEPTED' -Detail ('characters={0}' -f $Task.Length)

if(Test-NoTask -Text $Task){
    Write-PreAgentLog -Stage 'task-input' -Status 'NO_TASK' -Detail 'normalized no-task phrase; stopping before environment/auth/broker/Codex'
    Show-Status 'Диагностика не требуется. Работа завершена.'
    exit 0
}

$computer=if([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)){'WINDOWS'}else{$env:COMPUTERNAME}
$session=Join-Path $reportsRoot ('{0}_{1}_{2}_codex' -f $computer,(Get-Date -Format 'yyyy-MM-dd_HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $session -Force | Out-Null
$script:taskLog=Join-Path $session 'preflight.log'
Write-PreAgentLog -Stage 'session' -Status 'CREATED' -Detail ('session={0}' -f $session)
Write-TaskEnvironmentSnapshot -Path (Join-Path $session 'environment.log')
Add-Content -LiteralPath $historyPath -Value $Task -Encoding UTF8
Write-PreAgentLog -Stage 'history' -Status 'OK' -Detail ('history={0}' -f $historyPath)

$finalPath=Join-Path $session 'final-answer.txt'
$promptPath=Join-Path $session 'prompt.txt'
$codexSessionTemp=Join-Path $session '.codex-tmp'
$taskCodexHome=Join-Path $session '.codex-home'
New-Item -ItemType Directory -Path $codexSessionTemp -Force | Out-Null
New-Item -ItemType Directory -Path $taskCodexHome -Force | Out-Null

function Test-PathInsideTaskWorkspace {
    param([Parameter(Mandatory=$true)][string]$Path)
    $workspaceFull=[IO.Path]::GetFullPath($session).TrimEnd('\\')+'\\'
    $pathFull=[IO.Path]::GetFullPath($Path).TrimEnd('\\')+'\\'
    return $pathFull.StartsWith($workspaceFull,[StringComparison]::OrdinalIgnoreCase)
}
foreach($sandboxWritable in @($codexSessionTemp,$taskCodexHome)){
    if(-not(Test-PathInsideTaskWorkspace -Path $sandboxWritable)){
        Stop-WithMessage ("Внутренняя ошибка sandbox: writable path находится вне task workspace: {0}" -f $sandboxWritable)
    }
}
Write-PreAgentLog -Stage 'sandbox' -Status 'WRITABLE_ROOT_OK' -Detail ('workspace={0}; taskCodexHome={1}; temp={2}' -f $session,$taskCodexHome,$codexSessionTemp)

function Initialize-TaskCodexHome {
    New-Item -ItemType Directory -Path $taskCodexHome -Force | Out-Null
    foreach($name in @('auth.json','config.toml')){
        $source=Join-Path $codexHome $name
        $destination=Join-Path $taskCodexHome $name
        if(Test-Path -LiteralPath $source -PathType Leaf){
            Copy-Item -LiteralPath $source -Destination $destination -Force
        } elseif(Test-Path -LiteralPath $destination -PathType Leaf){
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-TaskCodexAuthentication {
    $source=Join-Path $taskCodexHome 'auth.json'
    $destination=Join-Path $codexHome 'auth.json'
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){return}
    try {
        $json=Get-Content -LiteralPath $source -Raw -Encoding UTF8
        $null=$json | ConvertFrom-Json -ErrorAction Stop
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-PreAgentLog -Stage 'codex-auth' -Status 'TASK_AUTH_SYNCED' -Detail 'session-local auth state synchronized without logging credential contents'
    } catch {
        Write-PreAgentLog -Stage 'codex-auth' -Status 'TASK_AUTH_SYNC_WARN' -Detail $_.Exception.Message
    }
}

Set-Content -LiteralPath (Join-Path $session 'sandbox-env.log') -Encoding UTF8 -Value @(
    'CHILD_TEMP='+$codexSessionTemp,
    'CHILD_TMP='+$codexSessionTemp,
    'CHILD_TMPDIR='+$codexSessionTemp,
    'PERSISTENT_CODEX_HOME='+$codexHome,
    'TASK_CODEX_HOME='+$taskCodexHome,
    'WORKSPACE='+$session,
    'PARENT_TEMP='+[string]$env:TEMP,
    'PARENT_TMP='+[string]$env:TMP,
    'PARENT_TMPDIR='+[string]$env:TMPDIR,
    'USERPROFILE='+[string]$env:USERPROFILE,
    'LOCALAPPDATA='+[string]$env:LOCALAPPDATA
)

Write-PreAgentLog -Stage 'environment' -Status 'BEGIN' -Detail 'validating portable runtime before Codex task execution'
if(-not (Test-Path -LiteralPath $pwsh -PathType Leaf)){
    Write-PreAgentLog -Stage 'powershell' -Status 'FAIL' -Detail ('missing={0}' -f $pwsh)
    Stop-WithMessage ("Переносимый PowerShell не найден: {0}" -f $pwsh)
}
try {
    $pwshVersion=(& $pwsh --version 2>&1 | Out-String).Trim()
    $pwshExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'powershell' -Status $(if($pwshExit -eq 0){'OK'}else{'WARN'}) -Detail ('exit={0}; version={1}; path={2}' -f $pwshExit,$pwshVersion,$pwsh)
} catch { Write-PreAgentLog -Stage 'powershell' -Status 'WARN' -Detail ('version probe failed: {0}' -f $_.Exception.Message) }

$env:CODEX_HOME=$codexHome
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
$requiredCodexVersion='0.151.0'
$authOverrideNames=@('CODEX_ACCESS_TOKEN','OPENAI_API_KEY')
$presentOverrides=@($authOverrideNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_,'Process')) })
foreach($name in $authOverrideNames){ Remove-Item -LiteralPath ("Env:{0}" -f $name) -ErrorAction SilentlyContinue }
Write-PreAgentLog -Stage 'codex-auth-env' -Status 'ISOLATED' -Detail ('clearedProcessOverrides={0}' -f ($(if($presentOverrides.Count -gt 0){$presentOverrides -join ','}else{'none'})))

$codeModeHost=Join-Path $toolsRoot 'Codex\codex-code-mode-host.exe'
$commandRunner=Join-Path $toolsRoot 'Codex\codex-command-runner.exe'
$sandboxSetup=Join-Path $toolsRoot 'Codex\codex-windows-sandbox-setup.exe'
$mainCliValid=$false
if(Test-Path -LiteralPath $codex -PathType Leaf){
    try {
        $versionText=(& $codex --version 2>&1 | Out-String).Trim()
        if(($LASTEXITCODE -eq 0) -and ($versionText -match ('(?m)^codex-cli\s+{0}(?:\s|$)' -f [regex]::Escape($requiredCodexVersion)))){ $mainCliValid=$true }
    } catch {}
}
$codeModeHostPresent=Test-Path -LiteralPath $codeModeHost -PathType Leaf
$commandRunnerPresent=Test-Path -LiteralPath $commandRunner -PathType Leaf
$sandboxSetupPresent=Test-Path -LiteralPath $sandboxSetup -PathType Leaf
Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($mainCliValid -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent){'OK'}else{'NEEDS_SETUP'}) -Detail ('requiredVersion={0}; cliValid={1}; codeModeHost={2}; commandRunner={3}; sandboxSetup={4}; cliPath={5}' -f $requiredCodexVersion,$mainCliValid,$codeModeHostPresent,$commandRunnerPresent,$sandboxSetupPresent,$codex)

if((-not $mainCliValid) -or (-not $codeModeHostPresent) -or (-not $commandRunnerPresent) -or (-not $sandboxSetupPresent)){
    Write-PreAgentLog -Stage 'codex-setup' -Status 'BEGIN' -Detail ('setupScript={0}' -f $setup)
    Write-Host 'Подготавливаю компоненты Dr.Swinux...'
    $setupLog=Join-Path $reportsRoot 'setup.log'
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup *> $setupLog
    $setupExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'codex-setup' -Status $(if($setupExit -eq 0){'OK'}else{'FAIL'}) -Detail ('exit={0}; setupLog={1}' -f $setupExit,$setupLog)
    if($setupExit -ne 0){ Stop-WithMessage ("Не удалось подготовить Codex. Подробности: {0}" -f $setupLog) }
} else { Write-PreAgentLog -Stage 'codex-setup' -Status 'SKIP' -Detail 'all required portable Codex components already validated' }

foreach($requiredPath in @($codex,$codeModeHost,$commandRunner,$sandboxSetup)){
    if(-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)){ Stop-WithMessage ("После подготовки не найден компонент Codex: {0}" -f $requiredPath) }
}
try {
    $finalCodexVersion=(& $codex --version 2>&1 | Out-String).Trim()
    $finalCodexExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($finalCodexExit -eq 0){'READY'}else{'WARN'}) -Detail ('exit={0}; version={1}; CODEX_HOME={2}' -f $finalCodexExit,$finalCodexVersion,$codexHome)
} catch { Write-PreAgentLog -Stage 'codex-runtime' -Status 'WARN' -Detail ('final version probe failed: {0}' -f $_.Exception.Message) }

$authLog=Join-Path $reportsRoot 'auth-status.log'
$portableAuth=Join-Path $codexHome 'auth.json'
function Test-CodexLoggedIn {
    param([string]$StatusText,[int]$ExitCode)
    if($ExitCode -ne 0){ return $false }
    return ($StatusText -match '(?im)^\s*Logged in(?:\s+using\s+.+)?\s*$')
}

function Invoke-CodexLoginStatusWithTimeout {
    param([string]$Reason='status',[int]$TimeoutSeconds=8)
    $result=[ordered]@{TimedOut=$false;ExitCode=-1;Stdout='';Stderr='';ElapsedMs=0}
    $psi=[System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$codex
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    [void]$psi.ArgumentList.Add('login')
    [void]$psi.ArgumentList.Add('status')
    $psi.Environment['CODEX_HOME']=$codexHome
    $psi.Environment['TEMP']=$codexSessionTemp
    $psi.Environment['TMP']=$codexSessionTemp
    $psi.Environment['TMPDIR']=$codexSessionTemp
    $process=[System.Diagnostics.Process]::new()
    $process.StartInfo=$psi
    $watch=[System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-PreAgentLog -Stage 'codex-auth' -Status 'STATUS_PROCESS_START' -Detail ('reason={0}; timeoutSeconds={1}' -f $Reason,$TimeoutSeconds)
        if(-not $process.Start()){ throw 'Process.Start returned false.' }
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){
            $result.TimedOut=$true
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            try { $process.WaitForExit(3000)|Out-Null } catch {}
        } else {
            $process.WaitForExit()
            $result.ExitCode=$process.ExitCode
        }
        if($process.HasExited){
            try { $result.Stdout=$stdoutTask.GetAwaiter().GetResult() } catch {}
            try { $result.Stderr=$stderrTask.GetAwaiter().GetResult() } catch {}
            if((-not $result.TimedOut)-and $result.ExitCode -lt 0){ $result.ExitCode=$process.ExitCode }
        }
    } finally {
        $watch.Stop()
        $result.ElapsedMs=$watch.ElapsedMilliseconds
        $process.Dispose()
    }
    try {
        Set-Content -LiteralPath (Join-Path $session ('auth-status.{0}.stdout.log' -f ($Reason -replace '[^A-Za-z0-9_-]','_'))) -Value $result.Stdout -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $session ('auth-status.{0}.stderr.log' -f ($Reason -replace '[^A-Za-z0-9_-]','_'))) -Value $result.Stderr -Encoding UTF8
    } catch {}
    return [pscustomobject]$result
}

function Ensure-CodexAuthentication {
    param([switch]$ForceFresh,[string]$Reason='initial')
    if($ForceFresh -and (Test-Path -LiteralPath $portableAuth -PathType Leaf)){
        try {
            Remove-Item -LiteralPath $portableAuth -Force -ErrorAction Stop
            Write-PreAgentLog -Stage 'codex-auth' -Status 'STALE_AUTH_REMOVED' -Detail ('reason={0}; path={1}' -f $Reason,$portableAuth)
        } catch { Stop-WithMessage ("Не удалось очистить нерабочую переносную авторизацию Codex: {0}" -f $_.Exception.Message) }
    }

    $status=Invoke-CodexLoginStatusWithTimeout -Reason $Reason -TimeoutSeconds 8
    $loginStatusText=($status.Stdout+"`r`n"+$status.Stderr)
    $loginExit=$status.ExitCode
    try {
        $entry=("--- {0} ---`r`n{1}" -f $Reason,$loginStatusText)
        if(Test-Path -LiteralPath $authLog -PathType Leaf){ Add-Content -LiteralPath $authLog -Value ("`r`n"+$entry) -Encoding UTF8 }
        else { Set-Content -LiteralPath $authLog -Value $entry -Encoding UTF8 }
    } catch {}

    if($status.TimedOut -and -not $ForceFresh){
        Write-PreAgentLog -Stage 'codex-auth' -Status 'STATUS_TIMEOUT_CONTINUE' -Detail ('reason={0}; elapsedMs={1}; real Codex request will validate server auth' -f $Reason,$status.ElapsedMs)
        Show-Status 'Проверка входа отвечает медленно. Продолжаю запуск задачи...'
        return
    }

    $loggedIn=(-not $status.TimedOut) -and (Test-CodexLoggedIn -StatusText $loginStatusText -ExitCode $loginExit)
    $statusSummary=($loginStatusText -replace '[\r\n]+',' ').Trim()
    Write-PreAgentLog -Stage 'codex-auth' -Status $(if($loggedIn){'OK'}else{'LOGIN_REQUIRED'}) -Detail ('reason={0}; exit={1}; timeout={2}; status={3}' -f $Reason,$loginExit,$status.TimedOut,$statusSummary)
    if($loggedIn){ return }

    Write-PreAgentLog -Stage 'codex-auth' -Status 'BROWSER_AUTH_BEGIN' -Detail ('codex={0}; CODEX_HOME={1}' -f $codex,$codexHome)
    Write-Host ''
    Write-Host 'Требуется вход в ChatGPT для Codex.'
    Write-Host 'Сейчас откроется официальный вход ChatGPT в браузере. После успешного входа вернитесь в это окно.'
    Write-Host 'Dr.Swinux продолжит исходную задачу автоматически.'
    Write-Host ''
    $browserExit=$null
    try {
        & $codex login
        $browserExit=$LASTEXITCODE
        Write-PreAgentLog -Stage 'codex-auth' -Status 'BROWSER_AUTH_RETURN' -Detail ('exit={0}' -f $browserExit)
    } catch { Stop-WithMessage ("Не удалось запустить вход ChatGPT для Codex: {0}" -f $_.Exception.Message) }
    if($browserExit -ne 0){ Stop-WithMessage ("Вход ChatGPT для Codex завершился с кодом {0}. См. {1}" -f $browserExit,$authLog) }

    $post=Invoke-CodexLoginStatusWithTimeout -Reason 'post-browser-auth' -TimeoutSeconds 10
    $postText=($post.Stdout+"`r`n"+$post.Stderr)
    if($post.TimedOut){
        if(Test-Path -LiteralPath $portableAuth -PathType Leaf){
            Write-PreAgentLog -Stage 'codex-auth' -Status 'POST_AUTH_TIMEOUT_CONTINUE' -Detail 'auth.json exists; real Codex request will verify credentials'
            return
        }
        Stop-WithMessage 'Вход завершён, но Codex не подтвердил авторизацию.'
    }
    $loggedIn=Test-CodexLoggedIn -StatusText $postText -ExitCode $post.ExitCode
    Write-PreAgentLog -Stage 'codex-auth' -Status $(if($loggedIn){'CONFIRMED'}else{'FAIL'}) -Detail ('postBrowserExit={0}' -f $post.ExitCode)
    if(-not $loggedIn){ Stop-WithMessage 'Вход завершён, но Codex не подтвердил авторизацию.' }
}

Write-PreAgentLog -Stage 'codex-auth' -Status 'BEGIN' -Detail 'checking portable Codex authorization'
Ensure-CodexAuthentication -Reason 'startup-check'
Initialize-TaskCodexHome
Write-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY' -Detail 'portable PowerShell and Codex runtime are ready; startup auth was confirmed or deferred to the real request after bounded status timeout'

$brokerRoot=Join-Path $session 'broker'
$brokerReady=Join-Path $brokerRoot 'ready.json'
$brokerStop=Join-Path $brokerRoot 'stop'
$brokerTool=Join-Path $session 'broker-tool.ps1'
New-Item -ItemType Directory -Path $brokerRoot -Force | Out-Null

$brokerToolText=@'
param(
    [Parameter(Mandatory=$true)][ValidateSet(
        'GetWifiDetails','GetNetworkExtended','GetProcessExtended','GetDriverInventory',
        'GetDeviceInventory','GetServiceExtended','GetStorageExtended','GetStorageReliability',
        'GetEventLogElevated','GetUpdateHistory','GetFirewallSecurityStatus',
        'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget','GetInstalledPackages','SearchPackage',
        'SearchTrustedPackages','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'
    )][string]$Action,
    [string]$ParametersJson='{}',
    [int]$TimeoutSeconds=45
)
$ErrorActionPreference='Stop'
$sessionRoot=$PSScriptRoot
$clientPath=Join-Path (Split-Path -Parent (Split-Path -Parent $sessionRoot)) 'system\Broker-Request.ps1'
if(-not (Test-Path -LiteralPath $clientPath -PathType Leaf)){ throw ('SWINTUS broker client not found: '+$clientPath) }
& $clientPath -Session $sessionRoot -Action $Action -ParametersJson $ParametersJson -TimeoutSeconds $TimeoutSeconds
if($LASTEXITCODE -ne $null){exit $LASTEXITCODE}
'@
Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8
Write-PreAgentLog -Stage 'broker' -Status 'PREPARED' -Detail ('tool={0}; server={1}; client={2}' -f $brokerTool,$brokerServer,$brokerClient)
Show-Status 'Для системных действий Windows может запросить права администратора.'

$brokerArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $brokerServer),'-Session',('"{0}"' -f $session))
try {
    Write-PreAgentLog -Stage 'broker' -Status 'LAUNCH_BEGIN' -Detail 'requesting one UAC-elevated typed broker process'
    $brokerProcess=Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList $brokerArgs -PassThru
    Write-PreAgentLog -Stage 'broker' -Status 'PROCESS_STARTED' -Detail ('pid={0}' -f $brokerProcess.Id)
} catch { Stop-WithMessage ("Не удалось запустить системный Broker: {0}" -f $_.Exception.Message) }
$readyDeadline=(Get-Date).AddSeconds(30)
while((Get-Date) -lt $readyDeadline){
    if(Test-Path -LiteralPath $brokerReady -PathType Leaf){break}
    if($brokerProcess.HasExited){ Stop-WithMessage ("Системный Broker завершился до запуска. Код ошибки: {0}" -f $brokerProcess.ExitCode) }
    Start-Sleep -Milliseconds 250
}
if(-not (Test-Path -LiteralPath $brokerReady -PathType Leaf)){ Stop-WithMessage 'Системный Broker не запустился за 30 секунд.' }
Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)

$instructions=@"
You are Dr.Swinux's autonomous Windows engineer, physically running on the user's CURRENT Windows computer. Act as an experienced Windows engineer: understand the user's goal, form technical hypotheses when needed, choose the smallest useful checks or actions, test against evidence from this computer, revise the plan as evidence changes, and continue until the task is completed or you can explain the concrete blocker. Do not wait for the user to tell you which commands or checks to run.

REAL USER TASK:
$Task

Work on this computer immediately. Use local Windows evidence and the allowed Dr.Swinux tools to solve the real task.
Form hypotheses when useful, test them, inspect evidence, reject or refine them, take allowed actions, and continue until you have a useful verified result.
Do not stop after a generic first check. Prefer targeted evidence over broad checklists.
Prefer small, focused diagnostic commands over large compound PowerShell one-liners.
If a diagnostic command fails because of quoting, parsing, permissions, or tool behavior, inspect the error, simplify or split the command, and continue automatically.
Do not treat a failed diagnostic command as evidence about the computer itself.
Once the available evidence is sufficient to answer the user's task with stated uncertainty, stop investigating instead of collecting redundant evidence.
Do not ask the user to manually run commands that you can run yourself.

PRIVILEGED BROKER:
- A separate UAC-elevated SWINTUS broker is already running for this session.
- Codex itself remains unelevated.
- When normal commands are blocked by permissions or when administrator-only evidence would materially improve the diagnosis, use the broker automatically instead of asking the user.
- The broker tool is inside your current workspace as .\broker-tool.ps1.
- Invoke privileged reads directly from the current session:
  & .\broker-tool.ps1 -Action ACTION -ParametersJson 'JSON'
- IMPORTANT: if ordinary diagnostics report access denied, elevation required, or omit a requested value because of permissions, that is not a stopping condition. Immediately retry the needed observation through broker-tool.ps1 when a matching broker action exists.
- Do not finish with "could not read because of permissions" while a matching broker action remains untried.
- Allowed elevated read actions:
  GetWifiDetails
  GetNetworkExtended
  GetProcessExtended
  GetDriverInventory
  GetDeviceInventory
  GetServiceExtended
  GetStorageExtended
  GetStorageReliability
  GetEventLogElevated
  GetUpdateHistory
  GetFirewallSecurityStatus
  GetScheduledTaskSnapshot
  GetRegistryRead
  SetRegistryValue
  RemoveRegistryValue
- broker-tool.ps1 was created in the current workspace before Codex started, and the elevated broker reported READY.
- Treat broker failure as a tool failure, not evidence about the computer.

PACKAGE MANAGEMENT:
- You may search installed/available software and install or uninstall a program when that is part of the user's task.
- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, SearchTrustedPackages, InstallTrustedPackage, UninstallTrustedPackage.
- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available, use SearchTrustedPackages with the program name. If it returns an exact catalog Id, call InstallTrustedPackage with that Id. The trusted catalog is packaged with Dr.Swinux and contains broker-owned HTTPS URLs, SHA-256 hashes, installer types, fixed silent arguments, and verification metadata generated from WinGet manifests; Codex cannot supply or override those fields. Call InstallTrustedPackage at most once per exact Id per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action.
- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id.
- Call EnsureWinget at most once per task. If it fails deterministically, do not retry it.
- For an uninstall task when winget is unavailable, use SearchTrustedPackages to resolve an exact trusted catalog Id, then call UninstallTrustedPackage with only that Id. UninstallTrustedPackage correlates the packaged catalog with an HKLM uninstall entry, accepts only a quoted EXE under Program Files with narrowly allowlisted silent switches, shows a broker-owned Yes/No confirmation, executes without cmd.exe or another shell, and verifies that the uninstall entry disappeared. Call it at most once per exact Id per task.
- InstallPackage, UninstallPackage, and InstallTrustedPackage always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation.
- After a confirmed install/uninstall, verify the requested result with GetInstalledPackages or another direct observation.

STRICT BOUNDARY:
- The elevated broker remains typed and allowlist-only. It does not accept arbitrary elevated command text, scripts, installer paths, URLs, or free-form command-line arguments. Trusted direct installers are broker-owned catalog definitions only; the catalog is read-only at runtime and package Id is the only installer-selection input accepted from Codex.
- Apart from confirmed typed broker actions, treat ordinary shell commands as read-only and do not write outside the report session.
- Do not modify registry directly; use typed broker actions.
- Do not run cleanup, deletion, formatting, partitioning, boot/BCD, BitLocker, security-disabling, account-deletion, or mass-deletion commands.
- Do not inspect passwords, tokens, browser secrets, credential stores, SAM/SECURITY secrets, or any auth.json. The .codex-home and .codex-tmp directories inside the task workspace are launcher-managed runtime internals and must not be inspected.

Finish with the result, evidence/verification, any remaining uncertainty, and the next useful step only if needed.
Reply in the same language as the user's task.

TASK OUTCOME PROTOCOL:
- Your final answer MUST end with exactly one machine-readable line: DRSW_TASK_STATUS: SUCCESS, DRSW_TASK_STATUS: FAILURE, DRSW_TASK_STATUS: BLOCKED, or DRSW_TASK_STATUS: DECLINED.
- SUCCESS means the user's requested goal was actually completed and verified, not merely investigated.
- FAILURE means an attempted task/action failed and the user's requested goal remains incomplete.
- BLOCKED means a concrete external/system prerequisite prevents completion after the allowed recovery paths were exhausted.
- DECLINED means the user explicitly declined a broker-owned confirmation; do not classify that as a software failure.
- Do not mention or explain this protocol line elsewhere in the answer. Dr.Swinux removes it before displaying the answer to the user.
"@

Set-Content -LiteralPath $promptPath -Value $instructions -Encoding UTF8
Write-PreAgentLog -Stage 'prompt' -Status 'READY' -Detail ('promptFile={0}' -f $promptPath)
Write-PreAgentLog -Stage 'environment' -Status 'READY_FOR_AGENT' -Detail ('PowerShell=ready; Codex=ready; Broker=ready; session={0}' -f $session)
Show-Status 'Инженер выполняет задачу. Это может занять несколько минут...'

$promptText=$instructions
$codexStdout=Join-Path $session 'codex-console.log'
$codexStderr=Join-Path $session 'codex-error.log'

function Invoke-DrSwintusCodexTask {
    param([switch]$AppendLogs)
    if(Test-Path -LiteralPath $finalPath -PathType Leaf){ Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue }
    $stdoutMode=if($AppendLogs){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
    $stderrMode=if($AppendLogs){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
    $stdoutStream=$null; $stderrStream=$null; $process=$null; $timer=$null
    try {
        $stdoutStream=[System.IO.FileStream]::new($codexStdout,$stdoutMode,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
        $stderrStream=[System.IO.FileStream]::new($codexStderr,$stderrMode,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
        $psi=[System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName=$codex
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true
        $psi.RedirectStandardOutput=$true
        $psi.RedirectStandardError=$true
        $psi.Environment['CODEX_HOME']=$taskCodexHome
        $psi.Environment['TEMP']=$codexSessionTemp
        $psi.Environment['TMP']=$codexSessionTemp
        $psi.Environment['TMPDIR']=$codexSessionTemp
        foreach($argument in @('exec','--config','approval_policy="never"','--config','windows.sandbox="unelevated"','--sandbox','workspace-write','--cd',$session,'--skip-git-repo-check','--output-last-message',$finalPath,'-')){ [void]$psi.ArgumentList.Add([string]$argument) }
        $process=[System.Diagnostics.Process]::new()
        $process.StartInfo=$psi
        Write-PreAgentLog -Stage 'codex-process' -Status 'START' -Detail ('workspace={0}; taskCodexHome={1}; temp={2}' -f $session,$taskCodexHome,$codexSessionTemp)
        if(-not $process.Start()){ throw 'Не удалось запустить Codex.' }
        $stdoutCopy=$process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopy=$process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $process.StandardInput.Write($promptText)
        $process.StandardInput.Close()
        $timer=Start-LargeTaskTimer
        while(-not $process.HasExited){ Update-LargeTaskTimer -State $timer; Start-Sleep -Milliseconds 150; $process.Refresh() }
        Update-LargeTaskTimer -State $timer -Force
        $null=$stdoutCopy.GetAwaiter().GetResult(); $null=$stderrCopy.GetAwaiter().GetResult()
        $stdoutStream.Flush(); $stderrStream.Flush()
        Write-PreAgentLog -Stage 'codex-process' -Status 'EXIT' -Detail ('exit={0}' -f $process.ExitCode)
        return [int]$process.ExitCode
    } finally {
        if($null -ne $timer){ Stop-LargeTaskTimer -State $timer }
        if($null -ne $process){ $process.Dispose() }
        if($null -ne $stdoutStream){ $stdoutStream.Dispose() }
        if($null -ne $stderrStream){ $stderrStream.Dispose() }
    }
}

function Test-CodexAuthenticationFailure {
    param([string]$ErrorLogPath)
    if(-not (Test-Path -LiteralPath $ErrorLogPath -PathType Leaf)){ return $false }
    try { $text=Get-Content -LiteralPath $ErrorLogPath -Raw -Encoding UTF8 } catch { return $false }
    return ($text -match '(?i)refresh_token_reused|token_expired|access token could not be refreshed|please log out and sign in again|not logged in|authentication required|please run codex login|unauthorized')
}

Write-PreAgentLog -Stage 'handoff' -Status 'CODEX_TASK_START' -Detail ('codex={0}; workspace={1}; stdout={2}; stderr={3}' -f $codex,$session,$codexStdout,$codexStderr)
$codexExitResult=@(Invoke-DrSwintusCodexTask)
if($codexExitResult.Count -ne 1 -or $codexExitResult[0] -isnot [int]){
    $types=@($codexExitResult | ForEach-Object { if($null -eq $_){'null'}else{$_.GetType().FullName} }) -join ','
    Stop-WithMessage ("Внутренняя ошибка запуска Codex: ожидался один код завершения Int32, получено {0} значение(й): {1}. Подробности: {2}" -f $codexExitResult.Count,$types,$codexStderr)
}
$codexExit=[int]$codexExitResult[0]
Sync-TaskCodexAuthentication

if(($codexExit -ne 0) -and (Test-CodexAuthenticationFailure -ErrorLogPath $codexStderr)){
    Write-Host ''
    Write-Host 'Сессия Codex требует повторного входа в ChatGPT.'
    Write-Host 'Выполните вход один раз. После этого исходная задача продолжится автоматически.'
    Write-Host ''
    try { Ensure-CodexAuthentication -ForceFresh -Reason 'server-auth-rejection'; Initialize-TaskCodexHome } catch { try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}; throw }
    try { Add-Content -LiteralPath $codexStderr -Value "`r`n--- Dr.Swinux: retry after ChatGPT re-authentication ---`r`n" -Encoding UTF8 } catch {}
    Show-Status 'Вход обновлён. Продолжаю исходную задачу...'
    $retryExitResult=@(Invoke-DrSwintusCodexTask -AppendLogs)
    if($retryExitResult.Count -ne 1 -or $retryExitResult[0] -isnot [int]){ Stop-WithMessage 'Внутренняя ошибка повторного запуска Codex.' }
    $codexExit=[int]$retryExitResult[0]
    Sync-TaskCodexAuthentication
}

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
        $report=@(& $failureReporter -Session $session -Status $taskOutcome -CodexExit $codexExit -Task $Task -ReportsRoot $reportsRoot -ProjectRoot $root)
        $reportObject=@($report | Where-Object {$_ -and $_.PSObject.Properties['Bundle']}) | Select-Object -Last 1
        if($null -ne $reportObject){
            Write-PreAgentLog -Stage 'failure-reporter' -Status $(if([bool]$reportObject.Sent){'SENT'}else{'OUTBOX'}) -Detail ('bundle={0}; transport={1}; sendError={2}' -f $reportObject.Bundle,$reportObject.Transport,$reportObject.SendError)
            Show-Status ('Диагностический пакет ошибки подготовлен автоматически: {0}' -f $reportObject.Bundle)
            if([bool]$reportObject.Sent){Show-Status 'Диагностический пакет отправлен настроенному HTTPS relay.'}

            $repairConfig=$null
            try {if(Test-Path -LiteralPath $autoRepairConfig -PathType Leaf){$repairConfig=Get-Content -LiteralPath $autoRepairConfig -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}} catch {}
            $repairEnabled=($null -ne $repairConfig -and $repairConfig.PSObject.Properties['enabled'] -and [bool]$repairConfig.enabled)
            if($repairEnabled -and (Test-Path -LiteralPath $autoRepair -PathType Leaf)){
                Show-Status 'Запускаю изолированного repair-agent для анализа ошибки и подготовки исправления...'
                try {
                    $repairOutput=@(& $autoRepair -Session $session -Bundle ([string]$reportObject.Bundle) -ReportsRoot $reportsRoot -ProjectRoot $root -Codex $codex -CodexHome $codexHome)
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
                            $submitted=@(& $repairSubmitter -CandidateDirectory ([string]$repair.CandidateDirectory) -Repository $repo -BaseBranch $baseBranch)|Where-Object{$_ -and $_.PSObject.Properties['PullRequest']}|Select-Object -Last 1
                            if($null -ne $submitted){Write-PreAgentLog -Stage 'auto-repair' -Status 'PR_SUBMITTED' -Detail ('pr={0}; branch={1}' -f $submitted.PullRequest,$submitted.Branch);Show-Status ('Кандидат автоматически отправлен в GitHub как draft PR: {0}' -f $submitted.PullRequest)}
                        } catch {Write-PreAgentLog -Stage 'auto-repair' -Status 'PR_SUBMIT_ERROR' -Detail $_.Exception.Message;Show-Status 'Кандидат сохранён локально; автоматическая отправка PR не удалась.'}
                    } else {Write-PreAgentLog -Stage 'auto-repair' -Status 'LOCAL_ONLY' -Detail 'DRSW_GITHUB_TOKEN is not configured; validated candidate remains in repair outbox'}
                } catch {Write-PreAgentLog -Stage 'auto-repair' -Status 'ERROR' -Detail $_.Exception.Message;Show-Status 'Repair-agent не смог подготовить безопасный кандидат. Исходный failure bundle сохранён.'}
            }
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

if(-not $SingleTask){
    while($true){
        Write-Host ''
        Write-Host '────────────────────────────────────────'
        Write-Host 'Готов к следующей задаче.'
        Write-Host '↑/↓ — история задач'
        Write-Host ''
        $nextTask=Read-TaskWithHistory -HistoryPath $historyPath -Prompt 'Опишите задачу'
        if([string]::IsNullOrWhiteSpace($nextTask)){ Write-Host 'Задача не может быть пустой.'; continue }
        if(Test-NoTask -Text $nextTask){ Write-Host 'Работа Dr.Swinux завершена.'; break }
        try { & $PSCommandPath -Task $nextTask -SingleTask } catch { Write-Host ''; Write-Host 'Задача завершилась с ошибкой. Можно сразу ввести следующую задачу.' }
    }
}
