param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$agent=Join-Path $PSScriptRoot 'Start-Agent.ps1'
$root=Split-Path -Parent $PSScriptRoot
$reportsRoot=Join-Path $root 'reports'
$startupLog=Join-Path $reportsRoot 'startup-error.log'

if(-not (Test-Path -LiteralPath $agent -PathType Leaf)){
    throw ('Dr.Swinux runtime not found: {0}' -f $agent)
}

try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}

try {
    if(-not [Environment]::Is64BitOperatingSystem){
        throw 'Dr.Swinux requires 64-bit Windows for its current Codex runtime. This computer is running 32-bit Windows.'
    }

    & $agent -Task $Task -SingleTask:$SingleTask
    $code=$LASTEXITCODE
    if($null -eq $code){ $code=0 }
    exit [int]$code
} catch {
    try {
        New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
        $stamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        Add-Content -LiteralPath $startupLog -Encoding UTF8 -Value @(
            ''
            ('[{0}] Start-DoctorSwinux UNHANDLED_ERROR' -f $stamp)
            ('Message: {0}' -f [string]$_.Exception.Message)
            ('Position: {0}' -f [string]$_.InvocationInfo.PositionMessage)
            ('Stack: {0}' -f [string]$_.ScriptStackTrace)
        )
    } catch {}
    Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $_
    exit 1
} finally {
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
}
