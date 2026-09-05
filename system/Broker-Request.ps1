param(
    [Parameter(Mandatory=$true)][string]$Session,
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

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$Session=[System.IO.Path]::GetFullPath($Session)
$brokerRoot=Join-Path $Session 'broker'
$requestDir=Join-Path $brokerRoot 'requests'
$responseDir=Join-Path $brokerRoot 'responses'
$readyPath=Join-Path $brokerRoot 'ready.json'
$reportsRoot=Split-Path -Parent $Session
$stateDir=Join-Path $reportsRoot '_state'
$wingetBlockerPath=Join-Path $stateDir 'winget-bootstrap-blocker.json'

function Test-ClientWingetReady {
    $cmd=Get-Command winget.exe -ErrorAction SilentlyContinue
    if($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)){return $true}
    $aliasPath=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    return (Test-Path -LiteralPath $aliasPath -PathType Leaf)
}

function Clear-WingetBlockerCache {
    Remove-Item -LiteralPath $wingetBlockerPath -Force -ErrorAction SilentlyContinue
}

function Set-WingetBlockerCache {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $now=[DateTimeOffset]::UtcNow
    $state=[ordered]@{
        schemaVersion=1
        code='WindowsAppRuntime1.8Missing'
        observedAt=$now.ToString('o')
        expiresAt=$now.AddHours(6).ToString('o')
    }
    $tmp=$wingetBlockerPath+'.tmp'
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $wingetBlockerPath -Force
}

function Get-WingetBlockerCache {
    if(-not(Test-Path -LiteralPath $wingetBlockerPath -PathType Leaf)){return $null}
    try {
        $raw=Get-Content -LiteralPath $wingetBlockerPath -Raw -Encoding UTF8
        if($raw.Length -gt 4096){throw 'state file too large'}
        $state=$raw | ConvertFrom-Json -ErrorAction Stop
        if([int]$state.schemaVersion -ne 1){throw 'unexpected schema'}
        if([string]$state.code -ne 'WindowsAppRuntime1.8Missing'){throw 'unexpected blocker code'}
        $expires=[DateTimeOffset]::Parse([string]$state.expiresAt,[Globalization.CultureInfo]::InvariantCulture)
        if($expires -le [DateTimeOffset]::UtcNow){Clear-WingetBlockerCache;return $null}
        return [pscustomobject]@{Code=[string]$state.code;ExpiresAt=$expires}
    } catch {
        Clear-WingetBlockerCache
        return $null
    }
}

if(-not (Test-Path -LiteralPath $readyPath -PathType Leaf)){
    throw 'SWINTUS privileged broker is not ready.'
}

$taskModePath=Join-Path $Session 'task-mode.json'
$taskMode='SYSTEM_CHANGE'
if(Test-Path -LiteralPath $taskModePath -PathType Leaf){
    try {
        $modeDoc=Get-Content -LiteralPath $taskModePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if([string]$modeDoc.mode -in @('READ_ONLY','SYSTEM_CHANGE')){ $taskMode=[string]$modeDoc.mode }
        else { throw 'invalid task mode' }
    } catch {
        throw ('Invalid Dr.Swinux task mode metadata: '+$_.Exception.Message)
    }
}
if($taskMode -eq 'READ_ONLY'){
    $mutationActions=@('EnsureWinget','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue')
    if($Action -in $mutationActions){
        throw ("Action '{0}' is blocked because this Dr.Swinux session is READ_ONLY." -f $Action)
    }
}

if($Action -eq 'EnsureWinget'){
    if(Test-ClientWingetReady){
        Clear-WingetBlockerCache
    } else {
        $cached=Get-WingetBlockerCache
        if($null -ne $cached){
            [pscustomobject]@{
                Ok=$false
                Action='EnsureWinget'
                Data=$null
                Error=("Known WinGet bootstrap blocker is cached: Microsoft.WindowsAppRuntime.1.8 was confirmed missing. Retry is suppressed until {0:o}; winget availability is checked before this cache is used." -f $cached.ExpiresAt)
                Timestamp=(Get-Date).ToString('o')
            } | ConvertTo-Json -Depth 4
            exit 0
        }
    }
}

if($TimeoutSeconds -eq 45){
    $taskModePath=Join-Path $Session 'task-mode.json'
$taskMode='SYSTEM_CHANGE'
if(Test-Path -LiteralPath $taskModePath -PathType Leaf){
    try {
        $modeDoc=Get-Content -LiteralPath $taskModePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if([string]$modeDoc.mode -in @('READ_ONLY','SYSTEM_CHANGE')){ $taskMode=[string]$modeDoc.mode }
        else { throw 'invalid task mode' }
    } catch {
        throw ('Invalid Dr.Swinux task mode metadata: '+$_.Exception.Message)
    }
}
if($taskMode -eq 'READ_ONLY'){
    $mutationActions=@('EnsureWinget','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue')
    if($Action -in $mutationActions){
        throw ("Action '{0}' is blocked because this Dr.Swinux session is READ_ONLY." -f $Action)
    }
}

if($Action -eq 'EnsureWinget'){$TimeoutSeconds=180}
    elseif($Action -in @('InstallPackage','UninstallPackage','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback')){$TimeoutSeconds=300}
}
if($TimeoutSeconds -lt 5){$TimeoutSeconds=5}
if($TimeoutSeconds -gt 1800){$TimeoutSeconds=1800}

$params=$ParametersJson | ConvertFrom-Json
$id=[guid]::NewGuid().ToString('N')
$requestPath=Join-Path $requestDir ($id+'.json')
$responsePath=Join-Path $responseDir ($id+'.json')

$request=[pscustomobject]@{
    Action=$Action
    Parameters=$params
    Requested=(Get-Date)
}
$requestTempPath=$requestPath+'.tmp'
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestTempPath -Encoding UTF8
Move-Item -LiteralPath $requestTempPath -Destination $requestPath -Force

$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
while((Get-Date) -lt $deadline){
    if(Test-Path -LiteralPath $responsePath -PathType Leaf){
        $raw=Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
        $taskModePath=Join-Path $Session 'task-mode.json'
$taskMode='SYSTEM_CHANGE'
if(Test-Path -LiteralPath $taskModePath -PathType Leaf){
    try {
        $modeDoc=Get-Content -LiteralPath $taskModePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if([string]$modeDoc.mode -in @('READ_ONLY','SYSTEM_CHANGE')){ $taskMode=[string]$modeDoc.mode }
        else { throw 'invalid task mode' }
    } catch {
        throw ('Invalid Dr.Swinux task mode metadata: '+$_.Exception.Message)
    }
}
if($taskMode -eq 'READ_ONLY'){
    $mutationActions=@('EnsureWinget','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue')
    if($Action -in $mutationActions){
        throw ("Action '{0}' is blocked because this Dr.Swinux session is READ_ONLY." -f $Action)
    }
}

if($Action -eq 'EnsureWinget'){
            try {
                $response=$raw | ConvertFrom-Json -ErrorAction Stop
                if([bool]$response.Ok){
                    Clear-WingetBlockerCache
                } else {
                    $errorText=[string]$response.Error
                    if($errorText -match '(?i)0x80073CF3' -and $errorText -match '(?i)Microsoft\.WindowsAppRuntime\.1\.8'){
                        Set-WingetBlockerCache
                    }
                }
            } catch {}
        }
        $raw
        exit 0
    }
    Start-Sleep -Milliseconds 150
}

throw ("Timed out waiting for privileged broker response to {0}." -f $Action)

