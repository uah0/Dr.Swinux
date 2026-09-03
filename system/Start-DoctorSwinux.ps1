param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$legacyAgent=Join-Path $PSScriptRoot 'Start-Agent.ps1'
$wrapperPath=$MyInvocation.MyCommand.Path
$root=Split-Path -Parent $PSScriptRoot
$reportsRoot=Join-Path $root 'reports'
$startupLog=Join-Path $reportsRoot 'startup-error.log'
$preAgentLog=Join-Path $reportsRoot 'pre-agent.log'
$toolsRoot=Join-Path $root 'tools'
$codex=Join-Path $toolsRoot 'Codex\codex.exe'
$codexHome=Join-Path $toolsRoot 'CodexHome'
$codexConfig=Join-Path $codexHome 'config.toml'
$script:runtimeAgent=$null
$script:preflightSession=$null
$script:preflightLog=$null

if(-not (Test-Path -LiteralPath $legacyAgent -PathType Leaf)){ throw ('Dr.Swinux runtime not found: {0}' -f $legacyAgent) }
try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}

function Write-PreflightLog {
    param([string]$Stage,[string]$Status,[string]$Detail='')
    if([string]::IsNullOrWhiteSpace($script:preflightLog)){ return }
    try {
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        $clean=([string]$Detail -replace '[\r\n]+',' ' -replace '\s{2,}',' ').Trim()
        $line=if([string]::IsNullOrWhiteSpace($clean)){'[{0}] [{1}] {2}' -f $stamp,$Stage,$Status}else{'[{0}] [{1}] {2} :: {3}' -f $stamp,$Stage,$Status,$clean}
        Add-Content -LiteralPath $script:preflightLog -Value $line -Encoding UTF8
        Add-Content -LiteralPath $preAgentLog -Value $line -Encoding UTF8
    } catch {}
}

function Write-StartupFailure {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        $message=[string]$ErrorRecord.Exception.Message
        Add-Content -LiteralPath $startupLog -Encoding UTF8 -Value @('',('[{0}] Start-DoctorSwinux UNHANDLED_ERROR' -f $stamp),('Message: {0}' -f $message),('Position: {0}' -f [string]$ErrorRecord.InvocationInfo.PositionMessage),('Stack: {0}' -f [string]$ErrorRecord.ScriptStackTrace))
        Add-Content -LiteralPath $preAgentLog -Encoding UTF8 -Value ('[{0}] [start-wrapper] UNHANDLED_ERROR :: {1}' -f $stamp,($message -replace '[\r\n]+',' '))
        Write-PreflightLog -Stage 'wrapper' -Status 'UNHANDLED_ERROR' -Detail $message
    } catch {}
}

function Read-WrapperTaskWithHistory {
    param([string]$HistoryPath)
    $history=@()
    if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){
        try { $history=@(Get-Content -LiteralPath $HistoryPath -Encoding UTF8 | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}) } catch {}
    }
    $index=$history.Count
    $buffer=''
    Write-Host '↑/↓ — история задач'
    Write-Host ''
    Write-Host -NoNewline 'Опишите задачу: '
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
            Write-Host -NoNewline ('Опишите задачу: ' + $buffer)
        } catch {}
    }
}

function Ensure-PortableCodexConfig {
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $config=@'
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"

[sandbox_workspace_write]
exclude_tmpdir_env_var = true
exclude_slash_tmp = true
'@
    Set-Content -LiteralPath $codexConfig -Value $config -Encoding UTF8
}

function New-PreflightSession {
    New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    $computer=if([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)){'WINDOWS'}else{$env:COMPUTERNAME}
    $suffix=[guid]::NewGuid().ToString('N').Substring(0,8)
    $name='{0}_{1}_{2}_preflight' -f $computer,(Get-Date -Format 'yyyy-MM-dd_HHmmss'),$suffix
    $script:preflightSession=Join-Path $reportsRoot $name
    New-Item -ItemType Directory -Path $script:preflightSession -Force | Out-Null
    $script:preflightLog=Join-Path $script:preflightSession 'preflight.log'
    $taskCharacters=if($null -eq $Task){0}else{$Task.Length}
    Write-PreflightLog -Stage 'preflight' -Status 'CREATED' -Detail ('session={0}; taskCharacters={1}; singleTask={2}' -f $script:preflightSession,$taskCharacters,$SingleTask)
}

function Write-PreflightEnvironmentSnapshot {
    $snapshot=Join-Path $script:preflightSession 'environment.log'
    $pwdText=''
    try { $pwdText=(Get-Location).Path } catch {}
    $values=@(
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
    Set-Content -LiteralPath $snapshot -Value $values -Encoding UTF8
    Write-PreflightLog -Stage 'environment-snapshot' -Status 'SAVED' -Detail ('path={0}; rootDrive={1}; temp={2}; tmp={3}; tmpdir={4}' -f $snapshot,[IO.Path]::GetPathRoot($root),$env:TEMP,$env:TMP,$env:TMPDIR)
}

function Invoke-CodexLoginStatusWithTimeout {
    param([int]$TimeoutSeconds=8)
    $result=[ordered]@{TimedOut=$false;ExitCode=-1;Stdout='';Stderr='';ElapsedMs=0}
    $psi=[System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$codex
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.ArgumentList.Add('login'); $psi.ArgumentList.Add('status')
    $psi.Environment['CODEX_HOME']=$codexHome
    $process=[System.Diagnostics.Process]::new(); $process.StartInfo=$psi
    $watch=[System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'PROCESS_START' -Detail ('timeoutSeconds={0}; codex={1}' -f $TimeoutSeconds,$codex)
        if(-not $process.Start()){ throw 'Process.Start returned false.' }
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'PROCESS_STARTED' -Detail ('pid={0}' -f $process.Id)
        $stdoutTask=$process.StandardOutput.ReadToEndAsync(); $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){
            $result.TimedOut=$true
            Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'TIMEOUT' -Detail ('pid={0}; elapsedMs={1}; action=kill-and-continue' -f $process.Id,$watch.ElapsedMilliseconds)
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
    } finally { $watch.Stop(); $result.ElapsedMs=$watch.ElapsedMilliseconds; $process.Dispose() }
    return [pscustomobject]$result
}

function New-RuntimeAgent {
    param([string]$PreflightDisposition='not confirmed',[switch]$SkipStartupAuth)
    $source=Get-Content -LiteralPath $legacyAgent -Raw -Encoding UTF8
    $authNeedle="Ensure-CodexAuthentication -Reason 'startup-check'"
    if(-not $source.Contains($authNeedle)){ throw 'Start-Agent startup authentication call was not found.' }
    if($SkipStartupAuth){
        $safeDisposition=($PreflightDisposition -replace "'","''")
        $authReplacement="Write-PreAgentLog -Stage 'codex-auth' -Status 'PREFLIGHT_HANDLED' -Detail 'startup login-status preflight $safeDisposition; duplicate blocking startup check skipped; task/server auth recovery remains active'"
        $source=$source.Replace($authNeedle,$authReplacement)
    }

    $psiPattern='(?m)^(\s*)\$psi=\[System\.Diagnostics\.ProcessStartInfo\]::new\(\)\r?\n\1\$psi\.FileName=\$codex\r?\n\1\$psi\.UseShellExecute=\$false\r?\n\1\$psi\.CreateNoWindow=\$true'
    $psiMatches=[regex]::Matches($source,$psiPattern)
    if($psiMatches.Count -ne 1){ throw ('Expected exactly one Codex ProcessStartInfo block, found {0}.' -f $psiMatches.Count) }
    $indent=$psiMatches[0].Groups[1].Value
    $psiReplacement=@(
        ($indent+'$psi=[System.Diagnostics.ProcessStartInfo]::new()'),
        ($indent+'$psi.FileName=$codex'),
        ($indent+'$psi.UseShellExecute=$false'),
        ($indent+'$psi.CreateNoWindow=$true'),
        ($indent+"`$codexSessionTemp=Join-Path `$session '.codex-tmp'"),
        ($indent+'New-Item -ItemType Directory -Path $codexSessionTemp -Force | Out-Null'),
        ($indent+"`$psi.Environment['TEMP']=`$codexSessionTemp"),
        ($indent+"`$psi.Environment['TMP']=`$codexSessionTemp"),
        ($indent+"`$psi.Environment['TMPDIR']=`$codexSessionTemp"),
        ($indent+"Set-Content -LiteralPath (Join-Path `$session 'sandbox-env.log') -Encoding UTF8 -Value @('TEMP='+`$codexSessionTemp,'TMP='+`$codexSessionTemp,'TMPDIR='+`$codexSessionTemp,'CODEX_HOME='+`$codexHome,'USERPROFILE='+[string]`$env:USERPROFILE,'LOCALAPPDATA='+[string]`$env:LOCALAPPDATA)")
    ) -join "`r`n"
    $source=[regex]::Replace($source,$psiPattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $psiReplacement },1)

    $dispatchNeedle='& $PSCommandPath -Task $nextTask -SingleTask'
    $escapedWrapper=$wrapperPath.Replace("'","''")
    $dispatchReplacement="& '$escapedWrapper' -Task `$nextTask -SingleTask"
    if(-not $source.Contains($dispatchNeedle)){ throw 'Start-Agent persistent dispatcher call was not found.' }
    $source=$source.Replace($dispatchNeedle,$dispatchReplacement)
    $id=[guid]::NewGuid().ToString('N')
    $script:runtimeAgent=Join-Path $PSScriptRoot ('Start-Agent.runtime.{0}.ps1' -f $id)
    Set-Content -LiteralPath $script:runtimeAgent -Value $source -Encoding UTF8
    Write-PreflightLog -Stage 'runtime-agent' -Status 'READY' -Detail ('path={0}; dispatcherTarget={1}; authDisposition={2}; skipStartupAuth={3}; codexTemp=session-local' -f $script:runtimeAgent,$wrapperPath,$PreflightDisposition,$SkipStartupAuth.IsPresent)
    return $script:runtimeAgent
}

function global:Write-Host {
    [CmdletBinding()]
    param([Parameter(Position=0,ValueFromPipeline=$true,ValueFromRemainingArguments=$true)][object[]]$Object,[object]$Separator=' ',[switch]$NoNewline,[ConsoleColor]$ForegroundColor,[ConsoleColor]$BackgroundColor)
    process {
        $mapped=@($Object|ForEach-Object{if($_ -is [string]){([string]$_).Replace('Doctor Swinux','Dr.Swinux').Replace('Dr.Swintus','Dr.Swinux')}else{$_}})
        $p=@{Object=$mapped}; if($PSBoundParameters.ContainsKey('Separator')){$p.Separator=$Separator}; if($NoNewline){$p.NoNewline=$true}; if($PSBoundParameters.ContainsKey('ForegroundColor')){$p.ForegroundColor=$ForegroundColor}; if($PSBoundParameters.ContainsKey('BackgroundColor')){$p.BackgroundColor=$BackgroundColor}
        Microsoft.PowerShell.Utility\Write-Host @p
    }
}

try {
    if(-not [Environment]::Is64BitOperatingSystem){ throw 'Dr.Swinux requires 64-bit Windows for its current Codex runtime. This computer is running 32-bit Windows. Use a 64-bit Windows 10/11 installation or VM.' }

    if([string]::IsNullOrWhiteSpace($Task)){
        $historyPath=Join-Path $reportsRoot 'prompt-history.txt'
        $Task=Read-WrapperTaskWithHistory -HistoryPath $historyPath
        if([string]::IsNullOrWhiteSpace($Task)){ throw 'Задача не может быть пустой.' }
    }

    New-PreflightSession
    Write-PreflightEnvironmentSnapshot
    Ensure-PortableCodexConfig
    $agentToRun=$legacyAgent
    if(Test-Path -LiteralPath $codex -PathType Leaf){
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host '• Проверяю вход ChatGPT...'
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'BEGIN' -Detail 'timeout-guarded login status before task runtime'
        $authResult=Invoke-CodexLoginStatusWithTimeout -TimeoutSeconds 8
        Set-Content -LiteralPath (Join-Path $preflightSession 'auth-status.stdout.log') -Value $authResult.Stdout -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $preflightSession 'auth-status.stderr.log') -Value $authResult.Stderr -Encoding UTF8
        if($authResult.TimedOut){
            Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'TIMEOUT_CONTINUE' -Detail ('elapsedMs={0}; duplicate startup auth check will be skipped; real Codex task will validate server auth' -f $authResult.ElapsedMs)
            Microsoft.PowerShell.Utility\Write-Host '• Проверка входа отвечает медленно. Продолжаю запуск задачи...'
            $agentToRun=New-RuntimeAgent -PreflightDisposition 'timed out; status unknown' -SkipStartupAuth
        } else {
            $combined=$authResult.Stdout+"`n"+$authResult.Stderr
            $loggedIn=($authResult.ExitCode -eq 0)-and($combined -match '(?im)^\s*Logged in(?:\s+using\s+.+)?\s*$')
            Write-PreflightLog -Stage 'codex-auth-preflight' -Status $(if($loggedIn){'OK'}else{'LOGIN_REQUIRED'}) -Detail ('exit={0}; elapsedMs={1}' -f $authResult.ExitCode,$authResult.ElapsedMs)
            if($loggedIn){
                $agentToRun=New-RuntimeAgent -PreflightDisposition 'confirmed logged in' -SkipStartupAuth
            } else {
                $agentToRun=New-RuntimeAgent -PreflightDisposition 'login required; Start-Agent auth retained'
            }
        }
    } else { Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'SKIP' -Detail 'codex.exe not present yet; Start-Agent will prepare runtime' }
    Write-PreflightLog -Stage 'agent-launch' -Status 'BEGIN' -Detail ('agent={0}' -f $agentToRun)
    & $agentToRun -Task $Task -SingleTask:$SingleTask
    $code=$LASTEXITCODE; if($null -eq $code){$code=0}
    Write-PreflightLog -Stage 'agent-launch' -Status 'RETURN' -Detail ('exit={0}' -f $code)
    exit [int]$code
} catch {
    Write-StartupFailure -ErrorRecord $_
    Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $_
    exit 1
} finally {
    if(-not [string]::IsNullOrWhiteSpace($script:runtimeAgent)){
        try { Remove-Item -LiteralPath $script:runtimeAgent -Force -ErrorAction Stop } catch { Write-PreflightLog -Stage 'runtime-agent' -Status 'CLEANUP_WARN' -Detail $_.Exception.Message }
    }
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
}
