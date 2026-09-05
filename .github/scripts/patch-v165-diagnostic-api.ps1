Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Read-Utf8([string]$Path){ [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path),[Text.UTF8Encoding]::new($false)) }
function Write-Utf8([string]$Path,[string]$Text){ [IO.File]::WriteAllText((Join-Path (Get-Location) $Path),$Text,[Text.UTF8Encoding]::new($false)) }
function Replace-Once([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $i=$Text.IndexOf($Old,[StringComparison]::Ordinal)
    if($i -lt 0){throw "Anchor not found: $Label"}
    if($Text.IndexOf($Old,$i+$Old.Length,[StringComparison]::Ordinal) -ge 0){throw "Anchor not unique: $Label"}
    $Text.Substring(0,$i)+$New+$Text.Substring($i+$Old.Length)
}

# 1) Typed read-only activation probe in elevated broker.
$path='system/Privileged-Broker.ps1'
$t=Read-Utf8 $path
$activation=@'
function Get-WindowsActivationStatus {
    $applicationId='55c92734-d682-4d71-983e-d6ec3f16059f'
    $os=$null
    try { $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1 Caption,Version,BuildNumber } catch {}

    $products=@()
    try {
        $products=@(Get-CimInstance SoftwareLicensingProduct -Filter ("ApplicationID='{0}'" -f $applicationId) -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.PartialProductKey) } |
            Select-Object Name,Description,LicenseStatus,LicenseStatusReason,GracePeriodRemaining,PartialProductKey)
    } catch { Write-BrokerLog ("ACTIVATION_CIM_WARN error={0}" -f $_.Exception.Message) }

    $selected=$null
    if($products.Count -gt 0){
        $licensed=@($products | Where-Object {[int]$_.LicenseStatus -eq 1} | Select-Object -First 1)
        if($licensed.Count -gt 0){$selected=$licensed[0]}else{$selected=$products[0]}
    }

    $activationResult=$null
    try {
        $reg=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\Activation' -ErrorAction Stop
        if($null -ne $reg.PSObject.Properties['ProductActivationResult']){$activationResult=[int]$reg.ProductActivationResult}
    } catch { Write-BrokerLog ("ACTIVATION_REGISTRY_WARN error={0}" -f $_.Exception.Message) }

    $statusMap=@{0='Unlicensed';1='Licensed';2='OOBGrace';3='OOTGrace';4='NonGenuineGrace';5='Notification';6='ExtendedGrace'}
    $activated=$null;$status='Unknown';$licenseStatus=$null;$source='Unavailable'
    $reason=$null;$grace=$null;$productName=$null;$description=$null;$partialKey=$null
    if($null -ne $selected){
        $licenseStatus=[int]$selected.LicenseStatus
        if($statusMap.ContainsKey($licenseStatus)){$status=$statusMap[$licenseStatus]}
        $activated=($licenseStatus -eq 1);$source='SoftwareLicensingProduct'
        $reason=$selected.LicenseStatusReason;$grace=$selected.GracePeriodRemaining
        $productName=[string]$selected.Name;$description=[string]$selected.Description;$partialKey=[string]$selected.PartialProductKey
    } elseif($null -ne $activationResult){
        $activated=($activationResult -eq 0);$status=if($activated){'Licensed'}else{'NotLicensedOrError'};$source='SoftwareProtectionPlatformRegistry'
    }

    $channel=$null
    if(-not [string]::IsNullOrWhiteSpace($description)){
        if($description -match '(?i)OEM_DM'){$channel='OEM_DM'}
        elseif($description -match '(?i)VOLUME_KMSCLIENT'){$channel='Volume_KMSClient'}
        elseif($description -match '(?i)VOLUME_MAK'){$channel='Volume_MAK'}
        elseif($description -match '(?i)RETAIL'){$channel='Retail'}
        elseif($description -match '(?i)OEM'){$channel='OEM'}
    }
    $windowsName=$null;$windowsVersion=$null;$buildNumber=$null
    if($null -ne $os){$windowsName=[string]$os.Caption;$windowsVersion=[string]$os.Version;$buildNumber=[string]$os.BuildNumber}
    Write-BrokerLog ("ACTIVATION_RESULT source={0} activated={1} licenseStatus={2} activationResult={3}" -f $source,$activated,$licenseStatus,$activationResult)
    [pscustomobject]@{
        Activated=$activated;Status=$status;LicenseStatus=$licenseStatus;LicenseStatusReason=$reason
        GracePeriodRemainingMinutes=$grace;ActivationResult=$activationResult;EvidenceSource=$source
        WindowsName=$windowsName;WindowsVersion=$windowsVersion;BuildNumber=$buildNumber
        ProductName=$productName;Channel=$channel;PartialProductKey=$partialKey
    }
}

'@
$t=Replace-Once $t 'function Get-NetworkExtended {' ($activation+'function Get-NetworkExtended {') 'activation function'
$t=$t.Replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'","'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
$t=Replace-Once $t "        'EnsureWinget' { return Ensure-Winget }" "        'GetWindowsActivationStatus' { return Get-WindowsActivationStatus }`n        'EnsureWinget' { return Ensure-Winget }" 'activation dispatch'
Write-Utf8 $path $t

# 2) Client allowlist: activation is read-only and therefore allowed in READ_ONLY mode.
$path='system/Broker-Request.ps1'
$t=Read-Utf8 $path
$t=$t.Replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'","'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
if($t -notmatch "'GetWindowsActivationStatus'"){throw 'Broker client action insertion failed.'}
Write-Utf8 $path $t

# 3) Stable diagnostic facade. No third-party binaries are bundled in this release.
$diag=@'
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
'@
Write-Utf8 'system/Diagnostic-Tool.ps1' $diag
New-Item -ItemType Directory -Path 'tools/Diagnostics' -Force | Out-Null
Write-Utf8 'tools/Diagnostics/README.txt' @'
Dr.Swinux managed diagnostic backends

This directory is reserved for portable diagnostic backends managed by Dr.Swinux adapters.
Codex must not execute third-party binaries from this directory directly. It uses the typed
system/Diagnostic-Tool.ps1 facade (copied into each task workspace) so backends can be added,
replaced, version-pinned, verified, or removed without changing the agent-facing API.

No third-party diagnostic binaries are bundled in v1.5.65. Future osquery/Sysinternals or other
backends must be integrated through fixed typed adapters with source/version/hash/licensing review.
'@

# 4) Agent wiring, activation prefetch and cleanup.
$path='system/Start-Agent.ps1'
$t=Read-Utf8 $path
$t=Replace-Once $t @'
$brokerClient=Join-Path $systemRoot 'Broker-Request.ps1'
'@ @'
$brokerClient=Join-Path $systemRoot 'Broker-Request.ps1'
$diagnosticToolSource=Join-Path $systemRoot 'Diagnostic-Tool.ps1'
'@ 'diagnostic source'
$t=$t.Replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'","'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
$t=Replace-Once $t @'
$brokerTool=Join-Path $session 'broker-tool.ps1'
New-Item -ItemType Directory -Path $brokerRoot -Force | Out-Null
'@ @'
$brokerTool=Join-Path $session 'broker-tool.ps1'
$diagnosticTool=Join-Path $session 'diagnostic-tool.ps1'
New-Item -ItemType Directory -Path $brokerRoot -Force | Out-Null
'@ 'diagnostic workspace tool'
$t=Replace-Once $t @'
Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8
Write-PreAgentLog -Stage 'broker' -Status 'PREPARED'
'@ @'
Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8
if(-not(Test-Path -LiteralPath $diagnosticToolSource -PathType Leaf)){ Stop-WithMessage ('Diagnostic-Tool.ps1 not found: '+$diagnosticToolSource) }
Copy-Item -LiteralPath $diagnosticToolSource -Destination $diagnosticTool -Force
Write-PreAgentLog -Stage 'diagnostic-api' -Status 'PREPARED' -Detail ('tool={0}' -f $diagnosticTool)
Write-PreAgentLog -Stage 'broker' -Status 'PREPARED'
'@ 'diagnostic copy'

$ready=@'
Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)
'@
$prefetch=@'
Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)

$prefetchedDiagnosticEvidence='None'
if(($taskMode -eq 'READ_ONLY') -and ($Task -match '(?i)(активац|активирован\s+ли\s+windows|активирован\s+ли\s+виндовс|windows\s+(?:is\s+)?activated|activation\s+status)')){
    try {
        Write-PreAgentLog -Stage 'diagnostic-prefetch' -Status 'BEGIN' -Detail 'action=GetWindowsActivationStatus'
        $activationRaw=(& $brokerClient -Session $session -Action 'GetWindowsActivationStatus' -ParametersJson '{}' -TimeoutSeconds 20 | Out-String).Trim()
        $activationResponse=$activationRaw | ConvertFrom-Json -ErrorAction Stop
        if([bool]$activationResponse.Ok){
            $prefetchedDiagnosticEvidence=('GetWindowsActivationStatus: '+($activationResponse.Data | ConvertTo-Json -Compress -Depth 6))
            Write-PreAgentLog -Stage 'diagnostic-prefetch' -Status 'OK' -Detail 'conclusive typed activation evidence available before Codex'
        } else {
            $prefetchedDiagnosticEvidence=('GetWindowsActivationStatus failed: '+[string]$activationResponse.Error)
            Write-PreAgentLog -Stage 'diagnostic-prefetch' -Status 'WARN' -Detail ([string]$activationResponse.Error)
        }
    } catch {
        $prefetchedDiagnosticEvidence=('GetWindowsActivationStatus failed: '+$_.Exception.Message)
        Write-PreAgentLog -Stage 'diagnostic-prefetch' -Status 'WARN' -Detail $_.Exception.Message
    }
}
'@
$t=Replace-Once $t $ready $prefetch 'activation prefetch'

$t=Replace-Once $t @'
For simple read-only fact checks, use the highest-signal direct source first and stop immediately when it gives a conclusive answer; do not fan out into redundant alternative probes.
'@ @'
For simple read-only fact checks, use the highest-signal direct source first and stop immediately when it gives a conclusive answer; do not fan out into redundant alternative probes.
Use .\diagnostic-tool.ps1 before ad-hoc shell/WMI/CIM/registry probes whenever it provides the requested fact. For Windows activation/licensing status, GetWindowsActivationStatus is authoritative for this task; if prefetched evidence below is conclusive, answer from it immediately and run no alternative activation probes.
'@ 'diagnostic prompt priority'
$t=Replace-Once $t @'
TASK MODE:
- This session is $taskMode.
'@ @'
PREFETCHED DIAGNOSTIC EVIDENCE:
$prefetchedDiagnosticEvidence
- Treat successful typed diagnostic evidence as the primary source. If it directly answers the user, do not re-check the same fact through slmgr, cmd, wmic, registry, event logs, or other redundant paths.

TASK MODE:
- This session is $taskMode.
'@ 'prefetched prompt evidence'
$t=Replace-Once $t @'
- The broker tool is inside your current workspace as .\broker-tool.ps1.
'@ @'
- The broker tool is inside your current workspace as .\broker-tool.ps1.
- The preferred read-only diagnostic facade is .\diagnostic-tool.ps1. It exposes only typed read actions and routes them to managed Dr.Swinux backends.
'@ 'diagnostic facade prompt'
$t=Replace-Once $t @'
  GetScheduledTaskSnapshot
  GetRegistryRead
  SetRegistryValue
'@ @'
  GetScheduledTaskSnapshot
  GetRegistryRead
  GetWindowsActivationStatus
  SetRegistryValue
'@ 'activation prompt allowlist'

$cleanup=@'
function Invoke-SessionRuntimeCleanup {
    $removed=@();$warnings=@()
    foreach($runtimeDir in @($codexSessionTemp,$taskCodexHome)){
        try { if(Test-Path -LiteralPath $runtimeDir){Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction Stop;$removed+=(Split-Path -Leaf $runtimeDir)} }
        catch {$warnings+=((Split-Path -Leaf $runtimeDir)+': '+$_.Exception.Message)}
    }
    try {if($null -ne $brokerProcess -and -not $brokerProcess.HasExited){try{$brokerProcess.WaitForExit(2500)|Out-Null}catch{}}} catch {}
    foreach($name in @('requests','responses')){
        $dir=Join-Path $brokerRoot $name
        try {if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop;$removed+=('broker/'+$name)}} catch {$warnings+=('broker/'+$name+': '+$_.Exception.Message)}
    }
    foreach($name in @('ready.json','stop')){
        $p=Join-Path $brokerRoot $name
        try {if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force -ErrorAction Stop;$removed+=('broker/'+$name)}} catch {$warnings+=('broker/'+$name+': '+$_.Exception.Message)}
    }
    Write-PreAgentLog -Stage 'session-cleanup' -Status $(if($warnings.Count -eq 0){'OK'}else{'WARN'}) -Detail ('removed={0}; warnings={1}' -f ($removed -join ','),($warnings -join ' | '))
}

'@
$t=Replace-Once $t 'function Test-CodexAuthenticationFailure {' ($cleanup+'function Test-CodexAuthenticationFailure {') 'cleanup function'
$t=Replace-Once $t @'
if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    if($null -ne $script:taskTimer){
'@ @'
Invoke-SessionRuntimeCleanup

if(Test-Path -LiteralPath $finalPath -PathType Leaf){
    if($null -ne $script:taskTimer){
'@ 'cleanup invocation'

if($t -match 'danger-full-access'){throw 'Forbidden danger-full-access found.'}
if($t -notmatch 'approval_policy=\\?"never\\?"'){throw 'approval_policy never invariant missing.'}
if($t -notmatch 'windows\.sandbox=\\?"unelevated\\?"'){throw 'unelevated Windows sandbox invariant missing.'}
if($t -notmatch 'diagnostic-prefetch'){throw 'Diagnostic prefetch missing.'}
if($t -notmatch 'Invoke-SessionRuntimeCleanup'){throw 'Cleanup function missing.'}
Write-Utf8 $path $t

Write-Utf8 'system/VERSION.txt' "Dr.Swinux v1.5.65-final`n"

foreach($ps in @('system/Start-Agent.ps1','system/Privileged-Broker.ps1','system/Broker-Request.ps1','system/Diagnostic-Tool.ps1')){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ps),[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw ("PowerShell parse error in {0}: {1}" -f $ps,(($errors | ForEach-Object {$_.Message}) -join '; '))}
}
Write-Host 'v1.5.65 diagnostic API migration completed.'
