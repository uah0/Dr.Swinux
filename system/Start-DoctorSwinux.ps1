param(
    [string]$Task,
    [switch]$SingleTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Branding compatibility layer for the proven Windows runtime.
# Internal Dr.Swintus identifiers and filenames are intentionally preserved during
# the transition so existing update packages, reports and automation keep working.
$legacyAgent=Join-Path $PSScriptRoot 'Start-Agent.ps1'
if(-not (Test-Path -LiteralPath $legacyAgent -PathType Leaf)){
    throw ('Dr.Swinux runtime not found: {0}' -f $legacyAgent)
}

try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}

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
            if($_ -is [string]){ ([string]$_).Replace('Dr.Swintus','Dr.Swinux') }
            else { $_ }
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
    & $legacyAgent -Task $Task -SingleTask:$SingleTask
    $code=$LASTEXITCODE
    if($null -eq $code){ $code=0 }
    exit [int]$code
} finally {
    try { $Host.UI.RawUI.WindowTitle='Dr.Swinux' } catch {}
}
