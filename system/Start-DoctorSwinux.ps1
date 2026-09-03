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
$codexHome=Join-Path (Join-Path $root 'tools') 'CodexHome'
$codexConfig=Join-Path $codexHome 'config.toml'

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
    } catch {}
}

function Ensure-PortableCodexConfig {
    # Real Windows testing showed Codex 0.151.0 refusing every local process with
    # "cannot enforce split writable root sets" while using the unelevated
    # restricted-token workspace-write sandbox. Dr.Swinux only needs the current
    # report session writable; privileged/state-changing work goes through Broker.
    # Excluding generic temp roots keeps the managed sandbox's writable-root set
    # aligned with the legacy Windows restricted-token projection while keeping
    # the Codex sandbox enabled and unelevated.
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
    # A 32-bit Windows OS cannot execute it. Detect that platform blocker before
    # Start-Agent tries to validate/download x64 Codex binaries and fails as an
    # opaque ScriptHalted/native-loader error.
    if(-not [Environment]::Is64BitOperatingSystem){
        throw 'Dr.Swinux requires 64-bit Windows for its current Codex runtime. This computer is running 32-bit Windows. Use a 64-bit Windows 10/11 installation or VM.'
    }

    Ensure-PortableCodexConfig
    & $legacyAgent -Task $Task -SingleTask:$SingleTask
    $code=$LASTEXITCODE
    if($null -eq $code){ $code=0 }
    exit [int]$code
} catch {
    Write-StartupFailure -ErrorRecord $_
    Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $_
    exit 1
} finally {
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
}
