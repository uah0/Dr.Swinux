param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Compatibility entrypoint for the proven Windows runtime.
$legacyAgent=Join-Path $PSScriptRoot 'Start-Agent.ps1'
$root=Split-Path -Parent $PSScriptRoot
$reportsRoot=Join-Path $root 'reports'
$startupLog=Join-Path $reportsRoot 'startup-error.log'
$preAgentLog=Join-Path $reportsRoot 'pre-agent.log'
$toolsRoot=Join-Path $root 'tools'
$codex=Join-Path $toolsRoot 'Codex\codex.exe'
$codexHome=Join-Path $toolsRoot 'CodexHome'
$codexConfig=Join-Path $codexHome 'config.toml'
$runtimeAgent=$null
$preflightSession=$null
$preflightLog=$null

if(-not (Test-Path -LiteralPath $legacyAgent -PathType Leaf)){
    throw ('Dr.Swinux runtime not found: {0}' -f $legacyAgent)
}

try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}

function Write-StartupFailure {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        $message=[string]$ErrorRecord.Exception.Message
        $position=[string]$ErrorRecord.InvocationInfo.PositionMessage
        $stack=[string]$ErrorRecord.ScriptStackTrace
        Add-Content -LiteralPath $startupLog -Encoding UTF8 -Value @(
            ''
            ('[{0}] Start-DoctorSwinux UNHANDLED_ERROR' -f $stamp)
            ('Message: {0}' -f $message)
            ('Position: {0}' -f $position)
            ('Stack: {0}' -f $stack)
        )
        Add-Content -LiteralPath $preAgentLog -Encoding UTF8 -Value ('[{0}] [start-wrapper] UNHANDLED_ERROR :: {1}' -f $stamp,($message -replace '[\r\n]+',' '))
        if(-not [string]::IsNullOrWhiteSpace($script:preflightLog)){
            Add-Content -LiteralPath $script:preflightLog -Encoding UTF8 -Value ('[{0}] [wrapper] UNHANDLED_ERROR :: {1}' -f $stamp,($message -replace '[\r\n]+',' '))
        }
    } catch {}
}

function Write-PreflightLog {
    param(
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Detail=''
    )
    if([string]::IsNullOrWhiteSpace($script:preflightLog)){ return }
    try {
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        $clean=([string]$Detail -replace '[\r\n]+',' ' -replace '\s{2,}',' ').Trim()
        $line=if([string]::IsNullOrWhiteSpace($clean)){
            '[{0}] [{1}] {2}' -f $stamp,$Stage,$Status
        } else {
            '[{0}] [{1}] {2} :: {3}' -f $stamp,$Stage,$Status,$clean
        }
        Add-Content -LiteralPath $script:preflightLog -Value $line -Encoding UTF8
        Add-Content -LiteralPath $preAgentLog -Value $line -Encoding UTF8
    } catch {}
}

function Ensure-PortableCodexConfig {
    # Keep the Windows restricted-token workspace-write sandbox enabled while
    # excluding generic temp roots that can create split writable-root sets.
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

function Invoke-CodexLoginStatusWithTimeout {
    param([int]$TimeoutSeconds=20)

    $result=[ordered]@{
        Started=$false
        TimedOut=$false
        ExitCode=-1
        Stdout=''
        Stderr=''
        ElapsedMs=0
    }

    $psi=[System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$codex
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.ArgumentList.Add('login')
    $psi.ArgumentList.Add('status')
    $psi.Environment['CODEX_HOME']=$codexHome

    $process=[System.Diagnostics.Process]::new()
    $process.StartInfo=$psi
    $watch=[System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'PROCESS_START' -Detail ('timeoutSeconds={0}; codex={1}; CODEX_HOME={2}' -f $TimeoutSeconds,$codex,$codexHome)
        if(-not $process.Start()){
            throw 'Process.Start returned false.'
        }
        $result.Started=$true
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'PROCESS_STARTED' -Detail ('pid={0}' -f $process.Id)

        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds * 1000)){
            $result.TimedOut=$true
            Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'TIMEOUT' -Detail ('pid={0}; elapsedMs={1}' -f $process.Id,$watch.ElapsedMilliseconds)
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            try { $process.WaitForExit(5000) | Out-Null } catch {}
        } else {
            $process.WaitForExit()
            $result.ExitCode=$process.ExitCode
        }

        try { $result.Stdout=$stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $result.Stderr=$stderrTask.GetAwaiter().GetResult() } catch {}
        if((-not $result.TimedOut) -and $result.ExitCode -lt 0 -and $process.HasExited){
            $result.ExitCode=$process.ExitCode
        }
    } finally {
        $watch.Stop()
        $result.ElapsedMs=$watch.ElapsedMilliseconds
        $process.Dispose()
    }
    return [pscustomobject]$result
}

function New-PreflightSession {
    New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    $computer=if([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)){'WINDOWS'}else{$env:COMPUTERNAME}
    $name='{0}_{1}_preflight' -f $computer,(Get-Date -Format 'yyyy-MM-dd_HHmmss')
    $script:preflightSession=Join-Path $reportsRoot $name
    New-Item -ItemType Directory -Path $script:preflightSession -Force | Out-Null
    $script:preflightLog=Join-Path $script:preflightSession 'preflight.log'
    $taskCharacters=if($null -eq $Task){0}else{$Task.Length}
    Write-PreflightLog -Stage 'preflight' -Status 'CREATED' -Detail ('session={0}; taskCharacters={1}' -f $script:preflightSession,$taskCharacters)
}

function New-PrevalidatedRuntimeAgent {
    # Start-Agent historically performs a synchronous `codex login status` before
    # creating its task session. The wrapper has already performed the same check
    # with a hard timeout. Use a same-directory runtime copy that skips only that
    # duplicate startup check; later server-auth rejection and browser re-auth paths
    # inside Start-Agent remain unchanged.
    $source=Get-Content -LiteralPath $legacyAgent -Raw -Encoding UTF8
    $needle="Ensure-CodexAuthentication -Reason 'startup-check'"
    if(-not $source.Contains($needle)){
        throw 'Start-Agent startup authentication call was not found; refusing an unsafe runtime rewrite.'
    }
    $replacement="Write-PreAgentLog -Stage 'codex-auth' -Status 'PREFLIGHT_OK' -Detail 'timeout-guarded login status already confirmed by Start-DoctorSwinux'"
    $patched=$source.Replace($needle,$replacement)
    $script:runtimeAgent=Join-Path $PSScriptRoot ('Start-Agent.runtime.{0}.ps1' -f $PID)
    Set-Content -LiteralPath $script:runtimeAgent -Value $patched -Encoding UTF8
    Write-PreflightLog -Stage 'runtime-agent' -Status 'READY' -Detail ('path={0}' -f $script:runtimeAgent)
    return $script:runtimeAgent
}

function global:Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true,ValueFromRemainingArguments=$true)]
        [object[]]$Object,
        [object]$Separator=' ',
        [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )
    process {
        $mapped=@($Object | ForEach-Object {
            if($_ -is [string]){
                ([string]$_).Replace('Doctor Swinux','Dr.Swinux').Replace('Dr.Swintus','Dr.Swinux')
            } else { $_ }
        })
        $p=@{Object=$mapped}
        if($PSBoundParameters.ContainsKey('Separator')){ $p.Separator=$Separator }
        if($NoNewline){ $p.NoNewline=$true }
        if($PSBoundParameters.ContainsKey('ForegroundColor')){ $p.ForegroundColor=$ForegroundColor }
        if($PSBoundParameters.ContainsKey('BackgroundColor')){ $p.BackgroundColor=$BackgroundColor }
        Microsoft.PowerShell.Utility\Write-Host @p
    }
}

try {
    # The pinned Windows Codex runtime bundled/installed by Dr.Swinux is x64.
    if(-not [Environment]::Is64BitOperatingSystem){
        throw 'Dr.Swinux requires 64-bit Windows for its current Codex runtime. This computer is running 32-bit Windows. Use a 64-bit Windows 10/11 installation or VM.'
    }

    New-PreflightSession
    Ensure-PortableCodexConfig

    $agentToRun=$legacyAgent
    if(Test-Path -LiteralPath $codex -PathType Leaf){
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host '• Проверяю вход ChatGPT...'
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'BEGIN' -Detail 'timeout-guarded login status before task runtime'
        $authResult=Invoke-CodexLoginStatusWithTimeout -TimeoutSeconds 20

        try {
            Set-Content -LiteralPath (Join-Path $preflightSession 'auth-status.stdout.log') -Value $authResult.Stdout -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $preflightSession 'auth-status.stderr.log') -Value $authResult.Stderr -Encoding UTF8
        } catch {}

        if($authResult.TimedOut){
            throw ('Codex login status did not return within 20 seconds. The process was stopped to avoid an indefinite VM hang. Diagnostic log: {0}' -f $preflightLog)
        }

        $combined=($authResult.Stdout + "`n" + $authResult.Stderr)
        $loggedIn=($authResult.ExitCode -eq 0) -and ($combined -match '(?im)^\s*Logged in(?:\s+using\s+.+)?\s*$')
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status $(if($loggedIn){'OK'}else{'LOGIN_REQUIRED'}) -Detail ('exit={0}; elapsedMs={1}' -f $authResult.ExitCode,$authResult.ElapsedMs)

        if($loggedIn){
            $agentToRun=New-PrevalidatedRuntimeAgent
        }
    } else {
        Write-PreflightLog -Stage 'codex-auth-preflight' -Status 'SKIP' -Detail 'codex.exe not present yet; Start-Agent will prepare the runtime'
    }

    Write-PreflightLog -Stage 'agent-launch' -Status 'BEGIN' -Detail ('agent={0}' -f $agentToRun)
    & $agentToRun -Task $Task -SingleTask:$SingleTask
    $code=$LASTEXITCODE
    if($null -eq $code){ $code=0 }
    Write-PreflightLog -Stage 'agent-launch' -Status 'RETURN' -Detail ('exit={0}' -f $code)
    exit [int]$code
} catch {
    Write-StartupFailure -ErrorRecord $_
    Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $_
    exit 1
} finally {
    if(-not [string]::IsNullOrWhiteSpace($script:runtimeAgent)){
        try { Remove-Item -LiteralPath $script:runtimeAgent -Force -ErrorAction Stop } catch {
            try { Write-PreflightLog -Stage 'runtime-agent' -Status 'CLEANUP_WARN' -Detail $_.Exception.Message } catch {}
        }
    }
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
}
