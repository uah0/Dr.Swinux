param(
    [Parameter(Mandatory=$true)][string]$Session,
    [Parameter(Mandatory=$true)][ValidateSet(
        'GetWifiDetails','GetNetworkExtended','GetProcessExtended','GetDriverInventory',
        'GetDeviceInventory','GetServiceExtended','GetStorageExtended','GetStorageReliability',
        'GetEventLogElevated','GetUpdateHistory','GetFirewallSecurityStatus',
        'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget','GetInstalledPackages','SearchPackage',
        'InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'
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

if(-not (Test-Path -LiteralPath $readyPath -PathType Leaf)){
    throw 'SWINTUS privileged broker is not ready.'
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
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding UTF8

$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
while((Get-Date) -lt $deadline){
    if(Test-Path -LiteralPath $responsePath -PathType Leaf){
        $raw=Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
        $raw
        exit 0
    }
    Start-Sleep -Milliseconds 150
}

throw ("Timed out waiting for privileged broker response to {0}." -f $Action)
