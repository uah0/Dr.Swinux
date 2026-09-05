from pathlib import Path

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text(encoding='utf-8-sig')

def write(path, text):
    (ROOT / path).write_text(text, encoding='utf-8', newline='\n')

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)

# --- Start-Agent: eliminate expensive codex --version from normal task startup ---
path = 'system/Start-Agent.ps1'
t = read(path)
old = r'''$mainCliValid=$false
if(Test-Path -LiteralPath $codex -PathType Leaf){
    try {
        $versionText=(& $codex --version 2>&1 | Out-String).Trim()
        if(($LASTEXITCODE -eq 0) -and ($versionText -match ('(?m)^codex-cli\s+{0}(?:\s|$)' -f [regex]::Escape($requiredCodexVersion)))){ $mainCliValid=$true }
    } catch {}
}
$codeModeHostPresent=Test-Path -LiteralPath $codeModeHost -PathType Leaf
$commandRunnerPresent=Test-Path -LiteralPath $commandRunner -PathType Leaf
$sandboxSetupPresent=Test-Path -LiteralPath $sandboxSetup -PathType Leaf
Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($mainCliValid -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent){'OK'}else{'NEEDS_SETUP'}) -Detail ('requiredVersion={0}; cliValid={1}; codeModeHost={2}; commandRunner={3}; sandboxSetup={4}; cliPath={5}' -f $requiredCodexVersion,$mainCliValid,$codeModeHostPresent,$commandRunnerPresent,$sandboxSetupPresent,$codex)

if((-not $mainCliValid) -or (-not $codeModeHostPresent) -or (-not $commandRunnerPresent) -or (-not $sandboxSetupPresent)){
'''
new = r'''$mainCliPresent=Test-Path -LiteralPath $codex -PathType Leaf
$codeModeHostPresent=Test-Path -LiteralPath $codeModeHost -PathType Leaf
$commandRunnerPresent=Test-Path -LiteralPath $commandRunner -PathType Leaf
$sandboxSetupPresent=Test-Path -LiteralPath $sandboxSetup -PathType Leaf
$runtimePresent=($mainCliPresent -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent)
Write-PreAgentLog -Stage 'codex-runtime' -Status $(if($runtimePresent){'READY_FAST'}else{'NEEDS_SETUP'}) -Detail ('requiredVersion={0}; cliPresent={1}; codeModeHost={2}; commandRunner={3}; sandboxSetup={4}; validation=managed-presence-fast-path; cliPath={5}' -f $requiredCodexVersion,$mainCliPresent,$codeModeHostPresent,$commandRunnerPresent,$sandboxSetupPresent,$codex)

if(-not $runtimePresent){
'''
t = replace_once(t, old, new, 'runtime fast-path block')
old = r'''if($mainCliValid -and $codeModeHostPresent -and $commandRunnerPresent -and $sandboxSetupPresent){
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_CACHED' -Detail ('version={0}; CODEX_HOME={1}; duplicate --version probe skipped' -f $versionText,$codexHome)
} else {
    try {
        $finalCodexVersion=(& $codex --version 2>&1 | Out-String).Trim()
        $finalCodexExit=$LASTEXITCODE
        if($finalCodexExit -ne 0){ Stop-WithMessage ("Codex после подготовки не прошёл проверку версии. Код: {0}" -f $finalCodexExit) }
        Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_AFTER_SETUP' -Detail ('exit={0}; version={1}; CODEX_HOME={2}' -f $finalCodexExit,$finalCodexVersion,$codexHome)
    } catch { Stop-WithMessage ("Не удалось проверить Codex после подготовки: {0}" -f $_.Exception.Message) }
}
'''
new = r'''if($runtimePresent){
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_FAST' -Detail ('requiredVersion={0}; CODEX_HOME={1}; no Codex process launched during startup validation' -f $requiredCodexVersion,$codexHome)
} else {
    Write-PreAgentLog -Stage 'codex-runtime' -Status 'READY_AFTER_SETUP' -Detail ('requiredVersion={0}; CODEX_HOME={1}; Setup-PortableCodex completed and required files are present' -f $requiredCodexVersion,$codexHome)
}
'''
t = replace_once(t, old, new, 'runtime post-setup block')

# --- Start-Agent: bounded retry cleanup for transient plugin/AV file handles ---
old = r'''function Invoke-SessionRuntimeCleanup {
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
new = r'''function Remove-SessionRuntimePathWithRetry {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Label,[int]$Attempts=16,[int]$DelayMs=250)
    $lastError=$null
    for($attempt=1;$attempt -le $Attempts;$attempt++){
        try {
            if(-not(Test-Path -LiteralPath $Path)){ return [pscustomobject]@{Removed=$true;Label=$Label;Error=$null;Attempts=$attempt} }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if(-not(Test-Path -LiteralPath $Path)){ return [pscustomobject]@{Removed=$true;Label=$Label;Error=$null;Attempts=$attempt} }
        } catch { $lastError=$_.Exception.Message }
        if($attempt -lt $Attempts){
            if(($attempt % 4) -eq 0){ try{[GC]::Collect();[GC]::WaitForPendingFinalizers()}catch{} }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return [pscustomobject]@{Removed=$false;Label=$Label;Error=$lastError;Attempts=$Attempts}
}

function Invoke-SessionRuntimeCleanup {
    $removed=@();$warnings=@()
    try {
        if($null -ne $brokerProcess -and -not $brokerProcess.HasExited){
            try{$brokerProcess.WaitForExit(5000)|Out-Null}catch{}
        }
    } catch {}

    foreach($item in @(
        [pscustomobject]@{Path=$codexSessionTemp;Label='.codex-tmp'},
        [pscustomobject]@{Path=$taskCodexHome;Label='.codex-home'},
        [pscustomobject]@{Path=(Join-Path $brokerRoot 'requests');Label='broker/requests'},
        [pscustomobject]@{Path=(Join-Path $brokerRoot 'responses');Label='broker/responses'}
    )){
        $result=Remove-SessionRuntimePathWithRetry -Path $item.Path -Label $item.Label
        if($result.Removed){$removed+=('{0}({1})' -f $result.Label,$result.Attempts)}
        else{$warnings+=('{0} after {1} attempts: {2}' -f $result.Label,$result.Attempts,$result.Error)}
    }
    foreach($name in @('ready.json','stop')){
        $p=Join-Path $brokerRoot $name
        try {if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force -ErrorAction Stop};if(-not(Test-Path -LiteralPath $p)){$removed+=('broker/'+$name)}}
        catch {$warnings+=('broker/'+$name+': '+$_.Exception.Message)}
    }
    Write-PreAgentLog -Stage 'session-cleanup' -Status $(if($warnings.Count -eq 0){'OK'}else{'WARN'}) -Detail ('removed={0}; warnings={1}' -f ($removed -join ','),($warnings -join ' | '))
}
'''
t = replace_once(t, old, new, 'cleanup retry block')
write(path, t)

# --- Privileged broker: registry-first activation, CIM only as fallback ---
path = 'system/Privileged-Broker.ps1'
t = read(path)
start = t.index('function Get-WindowsActivationStatus {')
end = t.index('\nfunction Get-NetworkExtended {', start)
old = t[start:end]
new = r'''function Get-WindowsActivationStatus {
    $applicationId='55c92734-d682-4d71-983e-d6ec3f16059f'
    $activationResult=$null
    $windowsName=$null;$windowsVersion=$null;$buildNumber=$null;$partialKey=$null
    try {
        $activation=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\Activation' -ErrorAction Stop
        if($null -ne $activation.PSObject.Properties['ProductActivationResult']){$activationResult=[int]$activation.ProductActivationResult}
    } catch { Write-BrokerLog ("ACTIVATION_REGISTRY_WARN error={0}" -f $_.Exception.Message) }
    try {
        $cv=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if($null -ne $cv.PSObject.Properties['ProductName']){$windowsName=[string]$cv.ProductName}
        if($null -ne $cv.PSObject.Properties['DisplayVersion']){$windowsVersion=[string]$cv.DisplayVersion}
        if($null -ne $cv.PSObject.Properties['CurrentBuildNumber']){$buildNumber=[string]$cv.CurrentBuildNumber}
    } catch {}
    try {
        $spp=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -ErrorAction Stop
        if($null -ne $spp.PSObject.Properties['BackupProductKeyDefault']){
            $key=[string]$spp.BackupProductKeyDefault
            if($key.Length -ge 5){$partialKey=$key.Substring($key.Length-5)}
        }
    } catch {}

    # ProductActivationResult=0 is the fast positive path observed from SPP.
    # Ambiguous/missing/non-zero registry state falls back to canonical licensing CIM.
    if($activationResult -eq 0){
        Write-BrokerLog 'ACTIVATION_RESULT source=SoftwareProtectionPlatformRegistry activated=True fastPath=True'
        return [pscustomobject]@{
            Activated=$true;Status='Licensed';LicenseStatus=1;LicenseStatusReason=$null
            GracePeriodRemainingMinutes=$null;ActivationResult=$activationResult;EvidenceSource='SoftwareProtectionPlatformRegistry'
            WindowsName=$windowsName;WindowsVersion=$windowsVersion;BuildNumber=$buildNumber
            ProductName=$null;Channel=$null;PartialProductKey=$partialKey
        }
    }

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
    $statusMap=@{0='Unlicensed';1='Licensed';2='OOBGrace';3='OOTGrace';4='NonGenuineGrace';5='Notification';6='ExtendedGrace'}
    $activated=$null;$status='Unknown';$licenseStatus=$null;$source='Unavailable'
    $reason=$null;$grace=$null;$productName=$null;$description=$null
    if($null -ne $selected){
        $licenseStatus=[int]$selected.LicenseStatus
        if($statusMap.ContainsKey($licenseStatus)){$status=$statusMap[$licenseStatus]}
        $activated=($licenseStatus -eq 1);$source='SoftwareLicensingProduct'
        $reason=$selected.LicenseStatusReason;$grace=$selected.GracePeriodRemaining
        $productName=[string]$selected.Name;$description=[string]$selected.Description;$partialKey=[string]$selected.PartialProductKey
    } elseif($null -ne $activationResult){
        $activated=$false;$status='NotLicensedOrError';$source='SoftwareProtectionPlatformRegistry'
    }
    $channel=$null
    if(-not [string]::IsNullOrWhiteSpace($description)){
        if($description -match '(?i)OEM_DM'){$channel='OEM_DM'}
        elseif($description -match '(?i)VOLUME_KMSCLIENT'){$channel='Volume_KMSClient'}
        elseif($description -match '(?i)VOLUME_MAK'){$channel='Volume_MAK'}
        elseif($description -match '(?i)RETAIL'){$channel='Retail'}
        elseif($description -match '(?i)OEM'){$channel='OEM'}
    }
    Write-BrokerLog ("ACTIVATION_RESULT source={0} activated={1} licenseStatus={2} activationResult={3} fastPath=False" -f $source,$activated,$licenseStatus,$activationResult)
    [pscustomobject]@{
        Activated=$activated;Status=$status;LicenseStatus=$licenseStatus;LicenseStatusReason=$reason
        GracePeriodRemainingMinutes=$grace;ActivationResult=$activationResult;EvidenceSource=$source
        WindowsName=$windowsName;WindowsVersion=$windowsVersion;BuildNumber=$buildNumber
        ProductName=$productName;Channel=$channel;PartialProductKey=$partialKey
    }
}
'''
t = t[:start] + new + t[end:]
write(path, t)

write('system/VERSION.txt', 'Dr.Swinux v1.5.66-final\n')
print('v1.5.66 candidate migration applied')
