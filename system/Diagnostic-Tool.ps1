param(
    [Parameter(Mandatory=$true)][ValidateSet(
        'GetWindowsActivationStatus','GetWifiDetails','GetNetworkExtended','GetProcessExtended',
        'GetDriverInventory','GetDeviceInventory','GetServiceExtended','GetStorageExtended',
        'GetStorageReliability','GetEventLogElevated','GetUpdateHistory','GetFirewallSecurityStatus',
        'GetScheduledTaskSnapshot','GetRegistryRead'
    )][string]$Action,
    [string]$ParametersJson='{}',
    [int]$TimeoutSeconds=45
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$brokerTool=Join-Path $PSScriptRoot 'broker-tool.ps1'
if(-not(Test-Path -LiteralPath $brokerTool -PathType Leaf)){throw 'Dr.Swinux broker-tool.ps1 is not available in this task workspace.'}
& $brokerTool -Action $Action -ParametersJson $ParametersJson -TimeoutSeconds $TimeoutSeconds
if($null -ne $LASTEXITCODE){exit $LASTEXITCODE}
