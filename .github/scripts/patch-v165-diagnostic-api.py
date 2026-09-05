from pathlib import Path


def read(path):
    return Path(path).read_text(encoding="utf-8")


def write(path, text):
    Path(path).write_text(text, encoding="utf-8", newline="\n")


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected 1 anchor, found {count}")
    return text.replace(old, new, 1)


# Privileged broker: one typed read-only activation probe.
path = "system/Privileged-Broker.ps1"
t = read(path)
activation = r'''function Get-WindowsActivationStatus {
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

'''
t = replace_once(t, "function Get-NetworkExtended {", activation + "function Get-NetworkExtended {", "activation function")
t = t.replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'", "'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
t = replace_once(t, "        'EnsureWinget' { return Ensure-Winget }", "        'GetWindowsActivationStatus' { return Get-WindowsActivationStatus }\n        'EnsureWinget' { return Ensure-Winget }", "activation dispatch")
write(path, t)

# Client allowlist.
path = "system/Broker-Request.ps1"
t = read(path)
t = t.replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'", "'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
if "'GetWindowsActivationStatus'" not in t:
    raise RuntimeError("Broker client activation action missing")
write(path, t)

# Stable diagnostic facade.
diag = r'''param(
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
'''
write("system/Diagnostic-Tool.ps1", diag)
Path("tools/Diagnostics").mkdir(parents=True, exist_ok=True)
write("tools/Diagnostics/README.txt", """Dr.Swinux managed diagnostic backends

This directory is reserved for portable diagnostic backends managed by Dr.Swinux adapters.
Codex must not execute third-party binaries from this directory directly. It uses the typed
system/Diagnostic-Tool.ps1 facade (copied into each task workspace) so backends can be added,
replaced, version-pinned, verified, or removed without changing the agent-facing API.

No third-party diagnostic binaries are bundled in v1.5.65. Future osquery/Sysinternals or other
backends must be integrated through fixed typed adapters with source/version/hash/licensing review.
""")

# Agent wiring.
path = "system/Start-Agent.ps1"
t = read(path)
t = replace_once(t,
    "$brokerClient=Join-Path $systemRoot 'Broker-Request.ps1'",
    "$brokerClient=Join-Path $systemRoot 'Broker-Request.ps1'\n$diagnosticToolSource=Join-Path $systemRoot 'Diagnostic-Tool.ps1'",
    "diagnostic source")
t = t.replace("'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget'", "'GetScheduledTaskSnapshot','GetRegistryRead','GetWindowsActivationStatus','EnsureWinget'")
t = replace_once(t,
    "$brokerTool=Join-Path $session 'broker-tool.ps1'",
    "$brokerTool=Join-Path $session 'broker-tool.ps1'\n$diagnosticTool=Join-Path $session 'diagnostic-tool.ps1'",
    "diagnostic workspace tool")
t = replace_once(t,
    "Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8\nWrite-PreAgentLog -Stage 'broker' -Status 'PREPARED'",
    "Set-Content -LiteralPath $brokerTool -Value $brokerToolText -Encoding UTF8\nif(-not(Test-Path -LiteralPath $diagnosticToolSource -PathType Leaf)){ Stop-WithMessage ('Diagnostic-Tool.ps1 not found: '+$diagnosticToolSource) }\nCopy-Item -LiteralPath $diagnosticToolSource -Destination $diagnosticTool -Force\nWrite-PreAgentLog -Stage 'diagnostic-api' -Status 'PREPARED' -Detail ('tool={0}' -f $diagnosticTool)\nWrite-PreAgentLog -Stage 'broker' -Status 'PREPARED'",
    "diagnostic copy")

ready = "Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)"
prefetch = r'''Write-PreAgentLog -Stage 'broker' -Status 'READY' -Detail ('readyFile={0}; pid={1}' -f $brokerReady,$brokerProcess.Id)

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
}'''
t = replace_once(t, ready, prefetch, "activation prefetch")

t = replace_once(t,
    "For simple read-only fact checks, use the highest-signal direct source first and stop immediately when it gives a conclusive answer; do not fan out into redundant alternative probes.",
    "For simple read-only fact checks, use the highest-signal direct source first and stop immediately when it gives a conclusive answer; do not fan out into redundant alternative probes.\nUse .\\diagnostic-tool.ps1 before ad-hoc shell/WMI/CIM/registry probes whenever it provides the requested fact. For Windows activation/licensing status, GetWindowsActivationStatus is authoritative for this task; if prefetched evidence below is conclusive, answer from it immediately and run no alternative activation probes.",
    "diagnostic priority prompt")
t = replace_once(t,
    "TASK MODE:\n- This session is $taskMode.",
    "PREFETCHED DIAGNOSTIC EVIDENCE:\n$prefetchedDiagnosticEvidence\n- Treat successful typed diagnostic evidence as the primary source. If it directly answers the user, do not re-check the same fact through slmgr, cmd, wmic, registry, event logs, or other redundant paths.\n\nTASK MODE:\n- This session is $taskMode.",
    "prefetched prompt evidence")
t = replace_once(t,
    "- The broker tool is inside your current workspace as .\\broker-tool.ps1.",
    "- The broker tool is inside your current workspace as .\\broker-tool.ps1.\n- The preferred read-only diagnostic facade is .\\diagnostic-tool.ps1. It exposes only typed read actions and routes them to managed Dr.Swinux backends.",
    "diagnostic facade prompt")
t = replace_once(t,
    "  GetScheduledTaskSnapshot\n  GetRegistryRead\n  SetRegistryValue",
    "  GetScheduledTaskSnapshot\n  GetRegistryRead\n  GetWindowsActivationStatus\n  SetRegistryValue",
    "activation prompt allowlist")

cleanup = r'''function Invoke-SessionRuntimeCleanup {
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

'''
t = replace_once(t, "function Test-CodexAuthenticationFailure {", cleanup + "function Test-CodexAuthenticationFailure {", "cleanup function")
t = replace_once(t,
    "if(Test-Path -LiteralPath $finalPath -PathType Leaf){\n    if($null -ne $script:taskTimer){",
    "Invoke-SessionRuntimeCleanup\n\nif(Test-Path -LiteralPath $finalPath -PathType Leaf){\n    if($null -ne $script:taskTimer){",
    "cleanup invocation")

for needle, label in [
    ("danger-full-access", "forbidden sandbox mode"),
]:
    if needle in t:
        raise RuntimeError(label)
if 'approval_policy=\\"never\\"' not in t and 'approval_policy="never"' not in t:
    raise RuntimeError("approval never invariant missing")
if 'windows.sandbox=\\"unelevated\\"' not in t and 'windows.sandbox="unelevated"' not in t:
    raise RuntimeError("unelevated sandbox invariant missing")
if "diagnostic-prefetch" not in t or "Invoke-SessionRuntimeCleanup" not in t:
    raise RuntimeError("agent diagnostic/cleanup wiring missing")
write(path, t)
write("system/VERSION.txt", "Dr.Swinux v1.5.65-final\n")
print("v1.5.65 diagnostic API migration completed")
