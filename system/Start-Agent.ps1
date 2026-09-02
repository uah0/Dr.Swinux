
param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Keep natural-language input/output UTF-8 end-to-end.
$utf8NoBom=[System.Text.UTF8Encoding]::new($false)
try { [Console]::InputEncoding=$utf8NoBom } catch {}
try { [Console]::OutputEncoding=$utf8NoBom } catch {}
$OutputEncoding=$utf8NoBom

function Stop-WithMessage {
    param([string]$Message)
    try { if(Get-Command Write-PreAgentLog -ErrorAction SilentlyContinue){ Write-PreAgentLog -Stage 'start-agent' -Status 'STOP' -Detail $Message } } catch {}
    Write-Host ''
    Write-Host 'ОШИБКА Dr.Swintus:'
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
$reportsRoot=Join-Path $root 'reports'
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
$preAgentLog=Join-Path $reportsRoot 'pre-agent.log'
$script:agentTaskStarted=$false

function Write-PreAgentLog {
    param(
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Detail=''
    )
    if($script:agentTaskStarted){ return }
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
    } catch {}
}

function Get-DrSwintusVersionLabel {
    $versionFile=Join-Path $systemRoot 'VERSION.txt'
    try {
        if(Test-Path -LiteralPath $versionFile -PathType Leaf){
            return (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
        }
    } catch {}
    return 'Dr.Swintus version unknown'
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
    try { $Host.UI.RawUI.WindowTitle='Dr.Swintus' } catch {}
    $versionFile=Join-Path $systemRoot 'VERSION.txt'
    $displayVersion='Dr.Swintus'
    try {
        if(Test-Path -LiteralPath $versionFile -PathType Leaf){
            $versionText=(Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
            $m=[regex]::Match($versionText,'(?i)Dr\.Swintus\s+v?([0-9]+\.[0-9]+\.[0-9]+)')
            if($m.Success){ $displayVersion=('Dr.Swintus '+$m.Groups[1].Value) }
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
    $state=[pscustomobject]@{
        Enabled=$false
        Top=0
        Width=0
        Stopwatch=[System.Diagnostics.Stopwatch]::StartNew()
        LastSecond=-1
    }

    try {
        if([Console]::IsOutputRedirected){ return $state }
        Write-Host ''
        Write-Host 'Время выполнения:'
        $state.Width=[Math]::Max([Console]::BufferWidth-1,1)
        foreach($line in (Get-LargeTimerLines -Elapsed ([TimeSpan]::Zero))){ Write-Host $line }
        # Capture the block position after reserving all five rows so console scrolling
        # near the bottom of the buffer cannot make the timer overwrite older output.
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
    } catch {
        $State.Enabled=$false
    }
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
    return $normalized -in @(
        'нет',
        'нет проблем',
        'проблем нет',
        'ничего',
        'отмена',
        'выход'
    )
}

function Read-TaskWithHistory {
    param(
        [string]$HistoryPath,
        [string]$Prompt='Опишите задачу'
    )

    $history=@()
    if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){
        try {
            $history=@(Get-Content -LiteralPath $HistoryPath -Encoding UTF8 | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
        } catch {}
    }

    $index=$history.Count
    $buffer=''
    $cursor=0

    Write-Host -NoNewline ($Prompt + ': ')

    while($true){
        $key=[Console]::ReadKey($true)

        if($key.Key -eq [ConsoleKey]::Enter){
            Write-Host ''
            return $buffer
        }

        if($key.Key -eq [ConsoleKey]::UpArrow){
            if($history.Count -gt 0 -and $index -gt 0){
                $index--
                $buffer=$history[$index]
                $cursor=$buffer.Length
            }
        } elseif($key.Key -eq [ConsoleKey]::DownArrow){
            if($history.Count -gt 0 -and $index -lt $history.Count - 1){
                $index++
                $buffer=$history[$index]
            } elseif($index -lt $history.Count){
                $index=$history.Count
                $buffer=''
            }
            $cursor=$buffer.Length
        } elseif($key.Key -eq [ConsoleKey]::Backspace){
            if($buffer.Length -gt 0){
                $buffer=$buffer.Substring(0,$buffer.Length-1)
                $cursor=$buffer.Length
            }
        } elseif(-not [char]::IsControl($key.KeyChar)){
            $buffer += $key.KeyChar
            $cursor=$buffer.Length
        } else {
            continue
        }

        try {
            $left=[Console]::CursorLeft
            $top=[Console]::CursorTop
            [Console]::SetCursorPosition(0,$top)
            Write-Host -NoNewline ((' ' * [Math]::Max([Console]::BufferWidth-1,1)))
            [Console]::SetCursorPosition(0,$top)
            Write-Host -NoNewline ($Prompt + ': ' + $buffer)
        } catch {}
    }
}

$historyPath=Join-Path $reportsRoot 'prompt-history.txt'

Write-PreAgentLog -Stage 'ui' -Status 'READY' -Detail 'main prompt is about to be displayed'
Show-MainHeader

# Check for Dr.Swintus updates before offering the first task prompt.
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
        Write-Host ('Доступно обновление Dr.Swintus {0}.' -f $remoteLabel)
        Write-Host '  1 — установить обновление'
        Write-Host '  2 — не обновляться и продолжить на текущей версии'
        $choice=''
        Write-Host -NoNewline 'Выберите 1 или 2: '
        while($choice -notin @('1','2')){
            $key=[Console]::ReadKey($true)
            $candidate=[string]$key.KeyChar
            if($candidate -in @('1','2')){
                $choice=$candidate
                Write-Host $choice
            }
        }
        Write-PreAgentLog -Stage 'updater' -Status 'USER_CHOICE' -Detail ('choice={0}; remote={1}' -f $choice,$remoteLabel)
        if($choice -eq '1'){
            Show-Status 'Устанавливаю обновление...'
            & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $updater -ProjectRoot $root -Mode Install *> $updateLog
            $installExit=$LASTEXITCODE
            Write-PreAgentLog -Stage 'updater' -Status 'INSTALL_EXIT' -Detail ('exit={0}; log={1}' -f $installExit,$updateLog)
            if($installExit -eq 20){
                Show-Status 'Обновление установлено. Перезапускаю Dr.Swintus...'
                Write-PreAgentLog -Stage 'updater' -Status 'RESTART_REQUESTED' -Detail ('installed={0}' -f $remoteLabel)
                exit 23
            }
            Show-Status 'Не удалось установить обновление. Продолжаю на текущей версии.'
        } else {
            Show-Status 'Продолжаю на текущей версии.'
        }
    } elseif($updateExit -ne 0){
        Show-Status 'Не удалось проверить обновления. Продолжаю работу.'
    }
} elseif($SingleTask) {
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

Write-PreAgentLog -Stage 'environment' -Status 'BEGIN' -Detail 'validating portable runtime before Codex task execution'
if(-not (Test-Path -LiteralPath $pwsh -PathType Leaf)){
    Write-PreAgentLog -Stage 'powershell' -Status 'FAIL' -Detail ('missing={0}' -f $pwsh)
    Stop-WithMessage ("Переносимый PowerShell не найден: {0}" -f $pwsh)
}
try {
    $pwshVersion=(& $pwsh --version 2>&1 | Out-String).Trim()
    $pwshExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'powershell' -Status $(if($pwshExit -eq 0){'OK'}else{'WARN'}) -Detail ('exit={0}; version={1}; path={2}' -f $pwshExit,$pwshVersion,$pwsh)
} catch {
    Write-PreAgentLog -Stage 'powershell' -Status 'WARN' -Detail ('version probe failed: {0}' -f $_.Exception.Message)
}

$env:CODEX_HOME=$codexHome
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

# v0.151.0 is the last Codex Windows runtime proven on the real Dr.Swintus test machine.
# Newer stable builds are not adopted automatically until they pass the same startup/auth test.
$requiredCodexVersion='0.151.0'

# Dr.Swintus uses its own ChatGPT file auth. Ignore inherited API/access-token overrides
# only inside this launcher process; user/machine environment variables are never changed.
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
        if(($LASTEXITCODE -eq 0) -and ($versionText -match ('(?m)^codex-cli\s+{0}(?:\s|$)' -f [regex]::Escape($requiredCodexVersion)))){
            $mainCliValid=$true
        }
    } catch {}
}

$codeModeHostPresent=Test-Path -LiteralPath $codeModeHost -PathType Leaf
$commandRunnerPresent=Test-Path -LiteralPath $commandRunner -PathType Leaf
$sandboxSetupPresent=Test-Path -LiteralPath $sandboxSetup -PathType Leaf
Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($mainCliValid -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent){'OK'}else{'NEEDS_SETUP'}) -Detail ('requiredVersion={0}; cliValid={1}; codeModeHost={2}; commandRunner={3}; sandboxSetup={4}; cliPath={5}' -f $requiredCodexVersion,$mainCliValid,$codeModeHostPresent,$commandRunnerPresent,$sandboxSetupPresent,$codex)

if((-not $mainCliValid) -or (-not $codeModeHostPresent) -or (-not $commandRunnerPresent) -or (-not $sandboxSetupPresent)){
    Write-PreAgentLog -Stage 'codex-setup' -Status 'BEGIN' -Detail ('setupScript={0}' -f $setup)
    Write-Host 'Подготавливаю компоненты Dr.Swintus...'
    $setupLog=Join-Path (Join-Path $root 'reports') 'setup.log'
    New-Item -ItemType Directory -Path (Split-Path -Parent $setupLog) -Force | Out-Null
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup *> $setupLog
    $setupExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'codex-setup' -Status $(if($setupExit -eq 0){'OK'}else{'FAIL'}) -Detail ('exit={0}; setupLog={1}' -f $setupExit,$setupLog)
    if($setupExit -ne 0){
        Stop-WithMessage ("Не удалось подготовить Codex. Подробности: {0}" -f $setupLog)
    }
} else {
    Write-PreAgentLog -Stage 'codex-setup' -Status 'SKIP' -Detail 'all required portable Codex components already validated'
}

if(-not (Test-Path -LiteralPath $codex -PathType Leaf)){
    Stop-WithMessage ("После подготовки не найден codex.exe: {0}" -f $codex)
}
if(-not (Test-Path -LiteralPath $codeModeHost -PathType Leaf)){
    Stop-WithMessage ("После подготовки не найден компонент Codex code-mode host: {0}" -f $codeModeHost)
}
if(-not (Test-Path -LiteralPath $commandRunner -PathType Leaf)){
    Stop-WithMessage ("После подготовки не найден компонент Codex command runner: {0}" -f $commandRunner)
}
if(-not (Test-Path -LiteralPath $sandboxSetup -PathType Leaf)){
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'FAIL' -Detail ('missing sandbox setup helper={0}' -f $sandboxSetup)
    Stop-WithMessage ("После подготовки не найден компонент песочницы Codex: {0}" -f $sandboxSetup)
}
try {
    $finalCodexVersion=(& $codex --version 2>&1 | Out-String).Trim()
    $finalCodexExit=$LASTEXITCODE
    Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($finalCodexExit -eq 0){'READY'}else{'WARN'}) -Detail ('exit={0}; version={1}; CODEX_HOME={2}' -f $finalCodexExit,$finalCodexVersion,$codexHome)
} catch {
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'WARN' -Detail ('final version probe failed: {0}' -f $_.Exception.Message)
}

# Authentication is performed with Codex's normal ChatGPT browser OAuth flow.
# On a normal Windows desktop this is the primary supported interactive login path.
# Device-code auth is deliberately not used here: real Windows tests of this project
# repeatedly stopped inside `codex login --device-auth` before Codex returned control.
$authLog=Join-Path (Join-Path $root 'reports') 'auth-status.log'
$portableAuth=Join-Path $codexHome 'auth.json'
function Test-CodexLoggedIn {
    param([string]$StatusText,[int]$ExitCode)
    if($ExitCode -ne 0){ return $false }
    return ($StatusText -match '(?im)^\s*Logged in(?:\s+using\s+.+)?\s*$')
}
function Ensure-CodexAuthentication {
    param([switch]$ForceFresh,[string]$Reason='initial')

    if($ForceFresh -and (Test-Path -LiteralPath $portableAuth -PathType Leaf)){
        try {
            Remove-Item -LiteralPath $portableAuth -Force -ErrorAction Stop
            Write-PreAgentLog -Stage 'codex-auth' -Status 'STALE_AUTH_REMOVED' -Detail ('reason={0}; path={1}' -f $Reason,$portableAuth)
        } catch {
            Stop-WithMessage ("Не удалось очистить нерабочую переносную авторизацию Codex: {0}" -f $_.Exception.Message)
        }
    }

    $loginStatusText=(& $codex login status 2>&1 | Out-String)
    $loginExit=$LASTEXITCODE
    try {
        $entry=("--- {0} ---`r`n{1}" -f $Reason,$loginStatusText)
        if(Test-Path -LiteralPath $authLog -PathType Leaf){ Add-Content -LiteralPath $authLog -Value ("`r`n"+$entry) -Encoding UTF8 }
        else { Set-Content -LiteralPath $authLog -Value $entry -Encoding UTF8 }
    } catch {}

    $loggedIn=Test-CodexLoggedIn -StatusText $loginStatusText -ExitCode $loginExit
    $statusSummary=($loginStatusText -replace '[\r\n]+',' ').Trim()
    Write-PreAgentLog -Stage 'codex-auth' -Status $(if($loggedIn){'OK'}else{'LOGIN_REQUIRED'}) -Detail ('reason={0}; exit={1}; status={2}' -f $Reason,$loginExit,$statusSummary)
    if($loggedIn){ return }

    Write-PreAgentLog -Stage 'codex-auth' -Status 'BROWSER_AUTH_BEGIN' -Detail ('direct current-console browser OAuth; codex={0}; CODEX_HOME={1}' -f $codex,$codexHome)
    Write-Host ''
    Write-Host 'Требуется вход в ChatGPT для Codex.'
    Write-Host 'Сейчас откроется официальный вход ChatGPT в браузере. После успешного входа вернитесь в это окно.'
    Write-Host 'Dr.Swintus продолжит исходную задачу автоматически.'
    Write-Host ''

    $browserExit=$null
    try {
        # Do not redirect stdin/stdout/stderr. Codex owns this visible console while
        # it waits for the localhost OAuth callback from the browser.
        & $codex login
        $browserExit=$LASTEXITCODE
        Write-PreAgentLog -Stage 'codex-auth' -Status 'BROWSER_AUTH_RETURN' -Detail ('exit={0}' -f $browserExit)
    } catch {
        Write-PreAgentLog -Stage 'codex-auth' -Status 'BROWSER_AUTH_EXCEPTION' -Detail ('type={0}; message={1}' -f $_.Exception.GetType().FullName,$_.Exception.Message)
        Stop-WithMessage ("Не удалось запустить вход ChatGPT для Codex: {0}" -f $_.Exception.Message)
    }
    if($browserExit -ne 0){
        Stop-WithMessage ("Вход ChatGPT для Codex завершился с кодом {0}. См. {1}" -f $browserExit,$authLog)
    }

    $loginStatusText=(& $codex login status 2>&1 | Out-String)
    $loginExit=$LASTEXITCODE
    try { Add-Content -LiteralPath $authLog -Value ("`r`n--- post-browser-auth ---`r`n"+$loginStatusText) -Encoding UTF8 } catch {}
    $loggedIn=Test-CodexLoggedIn -StatusText $loginStatusText -ExitCode $loginExit
    $postStatusSummary=($loginStatusText -replace '[\r\n]+',' ').Trim()
    Write-PreAgentLog -Stage 'codex-auth' -Status $(if($loggedIn){'CONFIRMED'}else{'FAIL'}) -Detail ('postBrowserExit={0}; status={1}' -f $loginExit,$postStatusSummary)
    if(-not $loggedIn){ Stop-WithMessage 'Вход завершён, но Codex не подтвердил авторизацию.' }
}

Write-PreAgentLog -Stage 'codex-auth' -Status 'BEGIN' -Detail 'checking portable Codex authorization'
Ensure-CodexAuthentication -Reason 'startup-check'
Write-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY' -Detail 'portable PowerShell, Codex runtime and authorization are ready before the task agent starts'


Add-Content -LiteralPath $historyPath -Value $Task -Encoding UTF8
Write-PreAgentLog -Stage 'history' -Status 'OK' -Detail ('history={0}' -f $historyPath)

$session=Join-Path $reportsRoot ("{0}_{1}_codex" -f $env:COMPUTERNAME,(Get-Date -Format 'yyyy-MM-dd_HHmmss'))
New-Item -ItemType Directory -Path $session -Force | Out-Null
Write-PreAgentLog -Stage 'session' -Status 'CREATED' -Detail ('session={0}' -f $session)

$finalPath=Join-Path $session 'final-answer.txt'
$promptPath=Join-Path $session 'prompt.txt'

$brokerRoot=Join-Path $session 'broker'
$brokerReady=Join-Path $brokerRoot 'ready.json'
$brokerStop=Join-Path $brokerRoot 'stop'
$brokerTool=Join-Path $session 'broker-tool.ps1'
New-Item -ItemType Directory -Path $brokerRoot -Force | Out-Null

# Codex runs with the report session as its workspace. Put the broker entrypoint
# inside that workspace so the agent can invoke it without reaching into system/.
$brokerToolText=@'
param(
    [Parameter(Mandatory=$true)][ValidateSet(
        'GetWifiDetails','GetNetworkExtended','GetProcessExtended','GetDriverInventory',
        'GetDeviceInventory','GetServiceExtended','GetStorageExtended','GetStorageReliability',
        'GetEventLogElevated','GetUpdateHistory','GetFirewallSecurityStatus',
        'GetScheduledTaskSnapshot','GetRegistryRead','GetInstalledPackages','SearchPackage',
        'InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'
    )][string]$Action,
    [string]$ParametersJson='{}',
    [int]$TimeoutSeconds=45
)
$ErrorActionPreference='Stop'
$sessionRoot=$PSScriptRoot
$clientPath=Join-Path (Split-Path -Parent (Split-Path -Parent $sessionRoot)) 'system\Broker-Request.ps1'
if(-not (Test-Path -LiteralPath $clientPath -PathType Leaf)){
    throw ('SWINTUS broker client not found: '+$clientPath)
}
& $clientPath -Session $sessionRoot -Action $Action -ParametersJson $ParametersJson -TimeoutSeconds $TimeoutSeconds
if($LASTEXITCODE -ne $null){exit $LASTEXITCODE}
'@
Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8

Write-PreAgentLog -Stage 'broker' -Status 'PREPARED' -Detail ('tool={0}; server={1}; client={2}' -f $brokerTool,$brokerServer,$brokerClient)
Show-Status 'Для системных действий Windows может запросить права администратора.'

$brokerArgs=@(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
    '-File',('"{0}"' -f $brokerServer),
    '-Session',('"{0}"' -f $session)
)
try {
    Write-PreAgentLog -Stage 'broker' -Status 'LAUNCH_BEGIN' -Detail 'requesting one UAC-elevated typed broker process'
    $brokerProcess=Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList $brokerArgs -PassThru
    Write-PreAgentLog -Stage 'broker' -Status 'PROCESS_STARTED' -Detail ('pid={0}' -f $brokerProcess.Id)
} catch {
    Write-PreAgentLog -Stage 'broker' -Status 'FAIL' -Detail $_.Exception.Message
    Stop-WithMessage ("Не удалось запустить системный Broker: {0}" -f $_.Exception.Message)
}

$readyDeadline=(Get-Date).AddSeconds(30)
while((Get-Date) -lt $readyDeadline){
    if(Test-Path -LiteralPath $brokerReady -PathType Leaf){break}
    if($brokerProcess.HasExited){
        Stop-WithMessage ("Системный Broker завершился до запуска. Код ошибки: {0}" -f $brokerProcess.ExitCode)
    }
    Start-Sleep -Milliseconds 250
}
if(-not (Test-Path -LiteralPath $brokerReady -PathType Leaf)){
    Write-PreAgentLog -Stage 'broker' -Status 'FAIL' -Detail 'ready.json was not created within 30 seconds'
    Stop-WithMessage 'Системный Broker не запустился за 30 секунд.'
}
Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)

$instructions=@"
You are Dr.Swintus's autonomous Windows engineer, physically running on the user's CURRENT Windows computer. Act as an experienced Windows engineer: understand the user's goal, form technical hypotheses when needed, choose the smallest useful checks or actions, test against evidence from this computer, revise the plan as evidence changes, and continue until the task is completed or you can explain the concrete blocker. Do not wait for the user to tell you which commands or checks to run.

REAL USER TASK:
$Task

Work on this computer immediately. Use local Windows evidence and the allowed Dr.Swintus tools to solve the real task.
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
  SetRegistryValue (confirmed registry value write across standard local hives; sensitive/security/persistence targets remain denied by Broker policy)
  RemoveRegistryValue (confirmed removal of an existing registry value; ordinary startup Run/RunOnce/StartupApproved entries may be removed, while higher-risk persistence/security targets remain denied)
- Example Wi-Fi privileged read:
  & .\broker-tool.ps1 -Action GetWifiDetails
- Example Security event read:
  & .\broker-tool.ps1 -Action GetEventLogElevated -ParametersJson '{"LogName":"Security","Hours":24,"ProviderContains":"","Ids":[],"MaxEvents":100}'
- Example registry read:
  & .\broker-tool.ps1 -Action GetRegistryRead -ParametersJson '{"Path":"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WlanSvc","Name":""}'
- broker-tool.ps1 was created in the current workspace before Codex started, and the elevated broker reported READY.
- Treat broker failure as a tool failure, not evidence about the computer. Inspect the returned error and continue with another useful observation.

AUTONOMY RULE:
- Before concluding that evidence is unavailable because of permissions, check whether one of the broker actions can obtain it.
- If yes, call the broker yourself and continue the same hypothesis loop.
- Do not ask the user to approve another elevation: the broker is already elevated for this session.

CONFIRMED WINDOWS SETTINGS:
- You may change a Windows/user setting when that is necessary to complete the user's explicit task, but use the typed SetRegistryValue broker action instead of direct registry-writing shell commands.
- GetRegistryRead may inspect ordinary startup locations such as Run/RunOnce/StartupApproved; credential/secret stores remain denied.
- SetRegistryValue can write values in HKLM, HKCU, HKCR, HKU, and HKCC when the target exists. It still cannot create/modify startup persistence or other broker-denied security/execution-hook targets.
- RemoveRegistryValue can remove an EXISTING value after broker-owned Yes/No confirmation. This includes ordinary Run/RunOnce/StartupApproved startup entries, so explicit tasks such as removing an application from startup can be completed. It does not create startup persistence and higher-risk targets remain denied.
- It supports only DWord, QWord, and String values. The broker shows a Yes/No confirmation containing the exact path, value name, old value, and new value. You cannot bypass this confirmation.
- Read the current value first with GetRegistryRead, make the smallest necessary change/remove only the evidenced value, then read it again and verify the requested result.
- Example remove an existing startup value after identifying its exact name:
  & .\broker-tool.ps1 -Action RemoveRegistryValue -ParametersJson '{"Path":"HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run","Name":"ExactExistingValueName","NotifyShell":true}'
- Example for the real Explorer hidden-files setting:
  & .\broker-tool.ps1 -Action SetRegistryValue -ParametersJson '{"Path":"HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced","Name":"Hidden","Value":2,"Type":"DWord","NotifyShell":true}'
- If multiple registry values must change for one user-visible setting, change only the values supported by evidence and verify each one. Each write is separately confirmation-gated.

PACKAGE MANAGEMENT:
- You may search installed/available software and install or uninstall a program when that is part of the user's task.
- Use the broker's typed winget actions instead of arbitrary installer commands: GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage.
- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id.
- InstallPackage and UninstallPackage always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation.
- Example search:
  & .\broker-tool.ps1 -Action SearchPackage -ParametersJson '{"Query":"KiCad"}'
- Example install after identifying the exact Id:
  & .\broker-tool.ps1 -Action InstallPackage -ParametersJson '{"Id":"KiCad.KiCad","DisplayName":"KiCad"}' -TimeoutSeconds 1800
- Example uninstall after identifying the exact installed Id:
  & .\broker-tool.ps1 -Action UninstallPackage -ParametersJson '{"Id":"VideoLAN.VLC","DisplayName":"VLC media player"}' -TimeoutSeconds 1800
- After a confirmed install/uninstall, verify the requested result with GetInstalledPackages or another direct observation. Do not report success solely from a zero exit code.
- If the user declines the broker confirmation, respect that decision and do not retry the same change unless the user explicitly asks again in a later task.

STRICT BOUNDARY:
- The elevated broker remains typed and allowlist-only. It does not accept arbitrary elevated command text, scripts, installer paths, or free-form command-line arguments.
- Write capabilities enabled in this release are limited to confirmed package install/uninstall plus confirmed SetRegistryValue and RemoveRegistryValue operations; every registry change requires a broker-owned user confirmation and post-change verification.
- Apart from those confirmed broker actions, treat ordinary shell commands as read-only and do not write outside the report session.
- Do not modify registry directly: use SetRegistryValue for value changes and RemoveRegistryValue for value removals. Do not modify services, networking, boot, security, users, permissions, drivers, Windows Update configuration, or scheduled tasks except through an explicitly available typed Broker action.
- Do not run cleanup, deletion, formatting, partitioning, boot/BCD, BitLocker, security-disabling, account-deletion, or mass-deletion commands.
- Do not inspect passwords, tokens, browser secrets, credential stores, SAM/SECURITY secrets, or CodexHome/auth.json.

Finish with the result, evidence/verification, any remaining uncertainty, and the next useful step only if needed.
Reply in the same language as the user's task.
"@

Set-Content -LiteralPath $promptPath -Value $instructions -Encoding UTF8
Write-PreAgentLog -Stage 'prompt' -Status 'READY' -Detail ('promptFile={0}' -f $promptPath)
Write-PreAgentLog -Stage 'environment' -Status 'READY_FOR_AGENT' -Detail ('PowerShell=ready; Codex=ready; Auth=confirmed; Broker=ready; session={0}' -f $session)

Show-Status 'Инженер выполняет задачу. Это может занять несколько минут...'

$promptText=$instructions
$codexStdout=Join-Path $session 'codex-console.log'
$codexStderr=Join-Path $session 'codex-error.log'

# Keep the normal console clean: Codex technical streaming output is stored in the report session.
# The final natural-language answer is written separately to final-answer.txt.
# Codex runs asynchronously here so the visible console can keep a large elapsed-time
# counter moving while the engineer works (including while a Broker confirmation is open).
function Invoke-DrSwintusCodexTask {
    param([switch]$AppendLogs)

    if(Test-Path -LiteralPath $finalPath -PathType Leaf){
        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
    }

    $stdoutMode=if($AppendLogs){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
    $stderrMode=if($AppendLogs){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
    $stdoutStream=$null
    $stderrStream=$null
    $process=$null
    $timer=$null

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
        foreach($argument in @(
            'exec',
            '--config','approval_policy="never"',
            '--config','windows.sandbox="unelevated"',
            '--sandbox','workspace-write',
            '--cd',$session,
            '--skip-git-repo-check',
            '--output-last-message',$finalPath,
            '-'
        )){
            [void]$psi.ArgumentList.Add([string]$argument)
        }

        $process=[System.Diagnostics.Process]::new()
        $process.StartInfo=$psi
        if(-not $process.Start()){ throw 'Не удалось запустить Codex.' }

        $stdoutCopy=$process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopy=$process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $process.StandardInput.Write($promptText)
        $process.StandardInput.Close()

        $timer=Start-LargeTaskTimer
        while(-not $process.HasExited){
            $null=Update-LargeTaskTimer -State $timer
            Start-Sleep -Milliseconds 150
            $process.Refresh()
        }
        $null=Update-LargeTaskTimer -State $timer -Force
        $null=$stdoutCopy.GetAwaiter().GetResult()
        $null=$stderrCopy.GetAwaiter().GetResult()
        $stdoutStream.Flush()
        $stderrStream.Flush()
        return [int]$process.ExitCode
    } finally {
        if($null -ne $timer){ $null=Stop-LargeTaskTimer -State $timer }
        if($null -ne $process){ $process.Dispose() }
        if($null -ne $stdoutStream){ $stdoutStream.Dispose() }
        if($null -ne $stderrStream){ $stderrStream.Dispose() }
    }
}

function Test-CodexAuthenticationFailure {
    param([string]$ErrorLogPath)
    if(-not (Test-Path -LiteralPath $ErrorLogPath -PathType Leaf)){ return $false }
    try {
        $text=Get-Content -LiteralPath $ErrorLogPath -Raw -Encoding UTF8
    } catch {
        return $false
    }
    return ($text -match '(?i)refresh_token_reused|token_expired|access token could not be refreshed|please log out and sign in again')
}

Write-PreAgentLog -Stage 'handoff' -Status 'CODEX_TASK_START' -Detail ('codex={0}; workspace={1}; stdout={2}; stderr={3}' -f $codex,$session,$codexStdout,$codexStderr)
$script:agentTaskStarted=$true
$codexExitResult=@(Invoke-DrSwintusCodexTask)
if($codexExitResult.Count -ne 1 -or $codexExitResult[0] -isnot [int]){
    $types=@($codexExitResult | ForEach-Object { if($null -eq $_){'null'}else{$_.GetType().FullName} }) -join ','
    Stop-WithMessage ("Внутренняя ошибка запуска Codex: ожидался один код завершения Int32, получено {0} значение(й): {1}. Подробности: {2}" -f $codexExitResult.Count,$types,$codexStderr)
}
$codexExit=[int]$codexExitResult[0]

# `codex login status` only proves that credentials exist. A copied or rotated
# ChatGPT refresh token can still fail on the first real server request. Repair
# that state once, removing only the stale portable auth file and using Codex's
# official browser OAuth flow, then retry the
# exact same user task without asking the user to re-enter it.
if(($codexExit -ne 0) -and (Test-CodexAuthenticationFailure -ErrorLogPath $codexStderr)){
    Write-Host ''
    Write-Host 'Сессия Codex требует повторного входа в ChatGPT.'
    Write-Host 'Выполните вход один раз. После этого исходная задача продолжится автоматически.'
    Write-Host ''

    try {
        Ensure-CodexAuthentication -ForceFresh -Reason 'server-auth-rejection'
    } catch {
        try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}
        throw
    }

    try {
        Add-Content -LiteralPath $codexStderr -Value "`r`n--- Dr.Swintus: retry after ChatGPT re-authentication ---`r`n" -Encoding UTF8
    } catch {}
    Show-Status 'Вход обновлён. Продолжаю исходную задачу...'
    $retryExitResult=@(Invoke-DrSwintusCodexTask -AppendLogs)
    if($retryExitResult.Count -ne 1 -or $retryExitResult[0] -isnot [int]){
        $retryTypes=@($retryExitResult | ForEach-Object { if($null -eq $_){'null'}else{$_.GetType().FullName} }) -join ','
        Stop-WithMessage ("Внутренняя ошибка повторного запуска Codex: ожидался один код завершения Int32, получено {0} значение(й): {1}. Подробности: {2}" -f $retryExitResult.Count,$retryTypes,$codexStderr)
    }
    $codexExit=[int]$retryExitResult[0]
}

try {
    New-Item -ItemType File -Path $brokerStop -Force | Out-Null
} catch {}

if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    Show-ResultHeader
    Get-Content -LiteralPath $finalPath -Encoding UTF8
    Write-Host ''
    Write-Host '────────────────────────────────────────'
    Write-Host 'Отчёт сохранён.'
} else {
    Stop-WithMessage ("Задача завершилась без итогового ответа. Подробности: {0}" -f $codexStderr)
}

if($codexExit -ne 0){
    Stop-WithMessage ("Задача завершилась с ошибкой {0}. Подробности: {1}" -f $codexExit,$codexStderr)
}

# The top-level launcher stays alive after a completed task. Each subsequent task is
# executed in a child script scope with -SingleTask, so the dispatcher itself does
# not recurse and the user can keep using the same visible console.
if(-not $SingleTask){
    while($true){
        Write-Host ''
        Write-Host '────────────────────────────────────────'
        Write-Host 'Готов к следующей задаче.'
        Write-Host '↑/↓ — история задач'
        Write-Host ''

        $nextTask=Read-TaskWithHistory -HistoryPath $historyPath -Prompt 'Опишите задачу'
        if([string]::IsNullOrWhiteSpace($nextTask)){
            Write-Host 'Задача не может быть пустой.'
            continue
        }
        if(Test-NoTask -Text $nextTask){
            Write-Host 'Работа Dr.Swintus завершена.'
            break
        }

        try {
            & $PSCommandPath -Task $nextTask -SingleTask
        } catch {
            Write-Host ''
            Write-Host 'Задача завершилась с ошибкой. Можно сразу ввести следующую задачу.'
        }
    }
}
