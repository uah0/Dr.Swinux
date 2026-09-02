param(
    [Parameter(Mandatory=$true)][string]$SystemRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-DrSwintusPlatformId {
    if(-not [string]::IsNullOrWhiteSpace($env:ANDROID_ROOT) -or -not [string]::IsNullOrWhiteSpace($env:ANDROID_DATA)){
        return 'android'
    }
    if($IsWindows){ return 'windows' }
    if($IsLinux){ return 'linux' }
    return 'unsupported'
}

$platformId=Get-DrSwintusPlatformId
if($platformId -eq 'unsupported'){
    throw 'Dr.Swintus: unsupported operating system.'
}

$manifestPath=Join-Path (Join-Path (Join-Path $SystemRoot 'platform') $platformId) 'manifest.json'
if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    throw ('Dr.Swintus platform manifest not found: {0}' -f $manifestPath)
}

$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -ne $platformId){
    throw ('Dr.Swintus platform manifest id mismatch: detected={0}; manifest={1}' -f $platformId,[string]$manifest.id)
}

$manifest
