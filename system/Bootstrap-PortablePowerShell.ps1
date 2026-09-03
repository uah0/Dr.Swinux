Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$RootPath=Split-Path -Parent $PSScriptRoot
if(-not (Test-Path -LiteralPath $RootPath -PathType Container)){
    throw ("Dr.Swinux root does not exist: {0}" -f $RootPath)
}

$toolsRoot=Join-Path $RootPath 'tools'
$reportsRoot=Join-Path $RootPath 'reports'
$psDir=Join-Path $toolsRoot 'PowerShell'
$pwsh=Join-Path $psDir 'pwsh.exe'

# A release ZIP can legitimately contain no tools directory at all because
# empty directories are not guaranteed to survive ZIP creation/extraction.
# Bootstrap must therefore create its own parent directories before moving
# the extracted portable PowerShell tree into Dr.Swinux\tools.
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null

if(Test-Path -LiteralPath $pwsh -PathType Leaf){
    try {
        $v=& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1
        if($LASTEXITCODE -eq 0){
            Write-Host ("Dr.Swinux portable PowerShell is ready: {0}" -f ($v | Out-String).Trim())
            exit 0
        }
    } catch {}
}

$arch=$env:PROCESSOR_ARCHITECTURE
if($env:PROCESSOR_ARCHITEW6432){
    $arch=$env:PROCESSOR_ARCHITEW6432
}

$version='7.6.5'
switch -Regex ($arch){
    '^(AMD64|x64)$' {
        $asset="PowerShell-$version-win-x64.zip"
        $sha='32EB8F6CDCE08F86E987D625A2733E54AC3E289AE7E1621B14C0B5BCEC2434EA'
        break
    }
    '^(ARM64)$' {
        $asset="PowerShell-$version-win-arm64.zip"
        $sha='20514A755D16428DC4355C85E0883C859531E71CC3E122670AA1FCCDBF96BA7E'
        break
    }
    '^(x86|X86)$' {
        $asset="PowerShell-$version-win-x86.zip"
        $sha='6444ECB222A6B51C8D10FFE9BDA99B83EAEEFE90160DE90DEEA6B638914C4A25'
        break
    }
    default {
        throw ("Unsupported Windows architecture: {0}" -f $arch)
    }
}

$url="https://github.com/PowerShell/PowerShell/releases/download/v$version/$asset"
$tmpRoot=Join-Path $reportsRoot '_DrSwinux-bootstrap'
$zipPath=Join-Path $tmpRoot $asset
$extract=Join-Path $tmpRoot 'extract'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

Write-Host ("Downloading portable PowerShell {0} for {1}..." -f $version,$arch)

try {
    # Windows PowerShell 5.1 can inherit an old TLS default on some Windows 10
    # systems. GitHub requires TLS 1.2+, so explicitly enable TLS 1.2 before
    # Invoke-WebRequest. Preserve any protocols already enabled by the host.
    try {
        $tls12=[System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor $tls12
    } catch {
        throw ("Unable to enable TLS 1.2 for PowerShell bootstrap: {0}" -f $_.Exception.Message)
    }

    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 240
    $actual=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if($actual -ne $sha){
        throw ("PowerShell SHA256 verification failed. Expected {0}, got {1}." -f $sha,$actual)
    }

    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

    if(Test-Path -LiteralPath $psDir){
        Remove-Item -LiteralPath $psDir -Recurse -Force
    }
    Move-Item -LiteralPath $extract -Destination $psDir

    if(-not (Test-Path -LiteralPath $pwsh -PathType Leaf)){
        throw ("Dr.Swinux portable PowerShell extraction completed but pwsh.exe is missing: {0}" -f $pwsh)
    }

    $v=& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1
    if($LASTEXITCODE -ne 0){
        throw ("Dr.Swinux portable PowerShell failed its startup test: {0}" -f (($v | Out-String).Trim()))
    }

    Write-Host ("Dr.Swinux portable PowerShell ready: {0}" -f (($v | Out-String).Trim()))
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
