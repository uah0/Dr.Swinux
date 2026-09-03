param(
    [Parameter(Mandatory=$true)][string]$Session
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$utf8NoBom=[System.Text.UTF8Encoding]::new($false)
try { [Console]::InputEncoding=$utf8NoBom } catch {}
try { [Console]::OutputEncoding=$utf8NoBom } catch {}
$OutputEncoding=$utf8NoBom

$Session=[System.IO.Path]::GetFullPath($Session)
$brokerRoot=Join-Path $Session 'broker'
$requestDir=Join-Path $brokerRoot 'requests'
$responseDir=Join-Path $brokerRoot 'responses'
$readyPath=Join-Path $brokerRoot 'ready.json'
$stopPath=Join-Path $brokerRoot 'stop'
$logPath=Join-Path $brokerRoot 'broker.log'

New-Item -ItemType Directory -Path $requestDir -Force | Out-Null
New-Item -ItemType Directory -Path $responseDir -Force | Out-Null

function Write-BrokerLog {
    param([string]$Text)
    Add-Content -LiteralPath $logPath -Value ("{0:o} {1}" -f (Get-Date),$Text) -Encoding UTF8
}

function Is-Administrator {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=[Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if(-not (Is-Administrator)){
    throw 'Dr.Swintus privileged broker must run elevated.'
}

function Truncate-Text {
    param([string]$Text,[int]$Max=12000)
    if($null -eq $Text){ return $null }
    if($Text.Length -le $Max){ return $Text }
    return $Text.Substring(0,$Max)
}

function Get-BrokerParameter {
    param(
        [hashtable]$Parameters,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default=$null
    )
    if($null -ne $Parameters -and $Parameters.ContainsKey($Name)){
        return $Parameters[$Name]
    }
    return $Default
}

function Initialize-BrokerMessageBox {
    if(('DrSwintus.NativeMessageBox' -as [type])){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DrSwintus {
    public static class NativeMessageBox {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
    }
}
'@
}

function Get-WifiDetails {
    $interfaces=''
    $drivers=''
    $profiles=''
    try { $interfaces=((& netsh wlan show interfaces) | Out-String) } catch { $interfaces=$_.Exception.Message }
    try { $drivers=((& netsh wlan show drivers) | Out-String) } catch { $drivers=$_.Exception.Message }
    try { $profiles=((& netsh wlan show profiles) | Out-String) } catch { $profiles=$_.Exception.Message }

    $adapters=@()
    try {
        $adapters=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress,DriverInformation,DriverVersion)
    } catch {}

    $advanced=@()
    try {
        $wifiNames=@($adapters | Where-Object {
            ([string]$_.Name -match 'Wi-?Fi|Wireless|WLAN') -or
            ([string]$_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|AX[0-9]')
        } | ForEach-Object {$_.Name})
        foreach($n in $wifiNames){
            $advanced += @(Get-NetAdapterAdvancedProperty -Name $n -ErrorAction SilentlyContinue |
                Select-Object Name,DisplayName,DisplayValue,RegistryKeyword,RegistryValue)
        }
    } catch {}

    [pscustomobject]@{
        Interfaces=Truncate-Text $interfaces
        Drivers=Truncate-Text $drivers
        Profiles=Truncate-Text $profiles
        Adapters=$adapters
        AdvancedProperties=$advanced
    }
}

function Get-NetworkExtended {
    $ip=@()
    $routes=@()
    $dns=@()
    $neighbors=@()
    try { $ip=@(Get-NetIPConfiguration -Detailed -ErrorAction SilentlyContinue) } catch {}
    try { $routes=@(Get-NetRoute -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix,NextHop,RouteMetric,InterfaceAlias,AddressFamily,State |
        Select-Object -First 300) } catch {}
    try { $dns=@(Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias,AddressFamily,ServerAddresses) } catch {}
    try { $neighbors=@(Get-NetNeighbor -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias,IPAddress,LinkLayerAddress,State |
        Select-Object -First 300) } catch {}
    [pscustomobject]@{IPConfiguration=$ip;Routes=$routes;DNS=$dns;Neighbors=$neighbors}
}

function Get-ProcessExtended {
    param([int]$Top=100)
    if($Top -lt 1){$Top=1}
    if($Top -gt 300){$Top=300}
    $rows=@()
    foreach($p in @(Get-Process -ErrorAction SilentlyContinue)){
        $path=$null;$start=$null;$company=$null
        try{$path=$p.Path}catch{}
        try{$start=$p.StartTime}catch{}
        try{$company=$p.Company}catch{}
        $owner=$null
        try {
            $c=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.Id) -ErrorAction SilentlyContinue
            if($c){
                $o=Invoke-CimMethod -InputObject $c -MethodName GetOwner -ErrorAction SilentlyContinue
                if($o -and $o.ReturnValue -eq 0){$owner=("{0}\{1}" -f $o.Domain,$o.User)}
            }
        } catch {}
        $rows += [pscustomobject]@{
            Name=$p.ProcessName;Id=$p.Id;Path=$path;Company=$company;Owner=$owner;
            CPUSeconds=if($p.CPU -ne $null){[math]::Round([double]$p.CPU,2)}else{$null};
            WorkingSetMB=[math]::Round(([double]$p.WorkingSet64)/1MB,1);
            StartTime=$start
        }
    }
    @($rows | Sort-Object WorkingSetMB -Descending | Select-Object -First $Top)
}

function Get-DriverInventory {
    param([int]$Top=300)
    if($Top -lt 1){$Top=1}
    if($Top -gt 500){$Top=500}
    @(
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Select-Object DeviceName,DeviceID,Manufacturer,DriverProviderName,DriverVersion,DriverDate,InfName,IsSigned,Signer |
        Select-Object -First $Top
    )
}

function Get-DeviceInventory {
    param([bool]$ProblemsOnly=$false,[int]$Top=300)
    if($Top -lt 1){$Top=1}
    if($Top -gt 500){$Top=500}
    $rows=@(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Select-Object Name,PNPDeviceID,Manufacturer,Service,Status,ConfigManagerErrorCode,ClassGuid,Present)
    if($ProblemsOnly){$rows=@($rows | Where-Object {$_.ConfigManagerErrorCode -ne 0})}
    @($rows | Select-Object -First $Top)
}

function Get-ServiceExtended {
    param([string]$NameContains='',[int]$Top=300)
    if($Top -lt 1){$Top=1}
    if($Top -gt 500){$Top=500}
    $rows=@(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Select-Object Name,DisplayName,State,StartMode,ProcessId,ExitCode,PathName,StartName,Description)
    if(-not [string]::IsNullOrWhiteSpace($NameContains)){
        $needle=$NameContains.ToLowerInvariant()
        $rows=@($rows | Where-Object {
            ([string]$_.Name).ToLowerInvariant().Contains($needle) -or
            ([string]$_.DisplayName).ToLowerInvariant().Contains($needle)
        })
    }
    @($rows | Select-Object -First $Top)
}

function Get-StorageExtended {
    $disks=@();$physical=@();$volumes=@();$partitions=@()
    try {$disks=@(Get-Disk -ErrorAction SilentlyContinue |
        Select-Object Number,FriendlyName,SerialNumber,BusType,PartitionStyle,HealthStatus,OperationalStatus,IsBoot,IsSystem,Size)} catch {}
    try {$physical=@(Get-PhysicalDisk -ErrorAction SilentlyContinue |
        Select-Object FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,OperationalStatus,Size,SpindleSpeed)} catch {}
    try {$volumes=@(Get-Volume -ErrorAction SilentlyContinue |
        Select-Object DriveLetter,FileSystemLabel,FileSystem,HealthStatus,OperationalStatus,Size,SizeRemaining,Path)} catch {}
    try {$partitions=@(Get-Partition -ErrorAction SilentlyContinue |
        Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size,IsBoot,IsSystem,IsActive,Offset)} catch {}
    [pscustomobject]@{Disks=$disks;PhysicalDisks=$physical;Volumes=$volumes;Partitions=$partitions}
}

function Get-StorageReliability {
    $out=@()
    try {
        foreach($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)){
            try {
                $r=Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction Stop
                $out += [pscustomobject]@{
                    FriendlyName=$pd.FriendlyName;SerialNumber=$pd.SerialNumber;
                    Temperature=$r.Temperature;TemperatureMax=$r.TemperatureMax;
                    Wear=$r.Wear;PowerOnHours=$r.PowerOnHours;
                    ReadErrorsTotal=$r.ReadErrorsTotal;WriteErrorsTotal=$r.WriteErrorsTotal;
                    ReadErrorsUncorrected=$r.ReadErrorsUncorrected;WriteErrorsUncorrected=$r.WriteErrorsUncorrected
                }
            } catch {}
        }
    } catch {}
    $out
}

function Get-EventLogElevated {
    param(
        [string]$LogName='System',
        [int]$Hours=24,
        [string]$ProviderContains='',
        [int[]]$Ids=@(),
        [int]$MaxEvents=200
    )
    if([string]::IsNullOrWhiteSpace($LogName)){throw 'LogName is required.'}
    if($LogName.Length -gt 180){throw 'LogName is too long.'}
    if($Hours -lt 1){$Hours=1}
    if($Hours -gt 24*90){$Hours=24*90}
    if($MaxEvents -lt 1){$MaxEvents=1}
    if($MaxEvents -gt 500){$MaxEvents=500}
    if(@($Ids).Count -gt 30){throw 'At most 30 event IDs are allowed.'}

    $exists=$false
    try {$exists=$null -ne (Get-WinEvent -ListLog $LogName -ErrorAction Stop)} catch {}
    if(-not $exists){throw ("Event log not found or unavailable: {0}" -f $LogName)}

    $events=@(Get-WinEvent -FilterHashtable @{LogName=$LogName;StartTime=(Get-Date).AddHours(-$Hours)} -ErrorAction SilentlyContinue)
    if(-not [string]::IsNullOrWhiteSpace($ProviderContains)){
        $needle=$ProviderContains.ToLowerInvariant()
        $events=@($events | Where-Object {([string]$_.ProviderName).ToLowerInvariant().Contains($needle)})
    }
    if(@($Ids).Count -gt 0){$events=@($events | Where-Object {@($Ids) -contains [int]$_.Id})}
    @($events | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEvents `
        TimeCreated,ProviderName,Id,LevelDisplayName,LogName,MachineName,
        @{N='Message';E={Truncate-Text ([string]$_.Message) 4000}})
}

function Get-UpdateHistory {
    param([int]$Top=100)
    if($Top -lt 1){$Top=1}
    if($Top -gt 300){$Top=300}
    $session=New-Object -ComObject Microsoft.Update.Session
    $searcher=$session.CreateUpdateSearcher()
    $count=$searcher.GetTotalHistoryCount()
    $take=[Math]::Min($count,$Top)
    if($take -le 0){return @()}
    @($searcher.QueryHistory(0,$take) | Select-Object Date,Title,Description,Operation,ResultCode,HResult,UnmappedResultCode)
}

function Get-FirewallSecurityStatus {
    $profiles=@();$defender=$null;$securityProducts=@()
    try {$profiles=@(Get-NetFirewallProfile -ErrorAction SilentlyContinue |
        Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction,NotifyOnListen,AllowInboundRules,AllowLocalFirewallRules)} catch {}
    try {$defender=Get-MpComputerStatus -ErrorAction SilentlyContinue |
        Select-Object AMServiceEnabled,AntivirusEnabled,AntispywareEnabled,BehaviorMonitorEnabled,
            IoavProtectionEnabled,NISEnabled,OnAccessProtectionEnabled,RealTimeProtectionEnabled,
            AntivirusSignatureLastUpdated,AntivirusSignatureVersion,QuickScanAge,FullScanAge} catch {}
    try {$securityProducts=@(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction SilentlyContinue |
        Select-Object displayName,productState,pathToSignedProductExe,pathToSignedReportingExe)} catch {}
    [pscustomobject]@{FirewallProfiles=$profiles;Defender=$defender;SecurityProducts=$securityProducts}
}

function Get-ObjectPropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    $prop=$Object.PSObject.Properties[$Name]
    if($null -eq $prop){return $Default}
    return $prop.Value
}

function Get-ScheduledTaskSnapshot {
    param([string]$TaskNameContains='',[int]$Top=300)
    if($Top -lt 1){$Top=1}
    if($Top -gt 500){$Top=500}
    $rows=@()
    foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)){
        if(-not [string]::IsNullOrWhiteSpace($TaskNameContains)){
            if(-not (([string]$t.TaskName).ToLowerInvariant().Contains($TaskNameContains.ToLowerInvariant()))){continue}
        }
        $info=$null
        try{$info=Get-ScheduledTaskInfo -InputObject $t -ErrorAction SilentlyContinue}catch{}
        $actions=@($t.Actions | ForEach-Object {
            [pscustomobject]@{
                Execute=[string](Get-ObjectPropertyValue -Object $_ -Name 'Execute' -Default '')
                Arguments=Truncate-Text ([string](Get-ObjectPropertyValue -Object $_ -Name 'Arguments' -Default '')) 1000
                WorkingDirectory=[string](Get-ObjectPropertyValue -Object $_ -Name 'WorkingDirectory' -Default '')
                ActionType=$_.GetType().FullName
            }
        })
        $rows += [pscustomobject]@{
            TaskPath=$t.TaskPath;TaskName=$t.TaskName;State=$t.State;
            Author=$t.Author;Description=Truncate-Text ([string]$t.Description) 1000;
            Actions=$actions;LastRunTime=if($info){$info.LastRunTime}else{$null};
            LastTaskResult=if($info){$info.LastTaskResult}else{$null};
            NextRunTime=if($info){$info.NextRunTime}else{$null}
        }
        if($rows.Count -ge $Top){break}
    }
    $rows
}

function Convert-RegistryPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){throw 'Path is required.'}
    if($Path.Length -gt 700){throw 'Registry path is too long.'}
    if($Path -match '[\x00-\x1F\x7F]'){throw 'Registry path contains control characters.'}

    $p=$Path.Trim().Replace('/','\')
    $map=[ordered]@{
        'Registry::HKEY_LOCAL_MACHINE\'='Registry::HKEY_LOCAL_MACHINE\'
        'Registry::HKEY_CURRENT_USER\'='Registry::HKEY_CURRENT_USER\'
        'Registry::HKEY_CLASSES_ROOT\'='Registry::HKEY_CLASSES_ROOT\'
        'Registry::HKEY_USERS\'='Registry::HKEY_USERS\'
        'Registry::HKEY_CURRENT_CONFIG\'='Registry::HKEY_CURRENT_CONFIG\'
        'HKEY_LOCAL_MACHINE\'='Registry::HKEY_LOCAL_MACHINE\'
        'HKEY_CURRENT_USER\'='Registry::HKEY_CURRENT_USER\'
        'HKEY_CLASSES_ROOT\'='Registry::HKEY_CLASSES_ROOT\'
        'HKEY_USERS\'='Registry::HKEY_USERS\'
        'HKEY_CURRENT_CONFIG\'='Registry::HKEY_CURRENT_CONFIG\'
        'HKLM:\'='Registry::HKEY_LOCAL_MACHINE\'
        'HKCU:\'='Registry::HKEY_CURRENT_USER\'
        'HKCR:\'='Registry::HKEY_CLASSES_ROOT\'
        'HKU:\'='Registry::HKEY_USERS\'
        'HKCC:\'='Registry::HKEY_CURRENT_CONFIG\'
    }
    foreach($prefix in $map.Keys){
        if($p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
            $tail=$p.Substring($prefix.Length).TrimStart('\')
            if([string]::IsNullOrWhiteSpace($tail)){throw 'Access to an entire registry hive root is not allowed.'}
            return ($map[$prefix]+$tail)
        }
    }
    throw 'Registry path must use HKLM, HKCU, HKCR, HKU, or HKCC.'
}

function Assert-RegistryReadTarget {
    param([string]$NormalizedPath,[string]$Name='')
    # Reads are broad because diagnostics often need startup/security configuration metadata,
    # but credential/secret-bearing stores remain unavailable to the agent.
    $deniedPathPatterns=@(
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SAM(\\|$)',
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SECURITY(\\|$)',
        '(?i)\\Credentials?(\\|$)',
        '(?i)\\Credential Manager(\\|$)',
        '(?i)\\Vault(\\|$)',
        '(?i)\\Protected Storage(\\|$)',
        '(?i)\\Control\\Lsa(\\|$)'
    )
    foreach($pattern in $deniedPathPatterns){
        if($NormalizedPath -match $pattern){throw 'This registry location is denied by the Dr.Swintus safety policy.'}
    }
}

function Assert-RegistryWriteTargetDenied {
    param([string]$NormalizedPath,[string]$Name='', [switch]$AllowStartupRemoval)
    # Writes remain blocked for credentials/security-disable and high-risk execution/persistence targets.
    # RemoveRegistryValue may remove an EXISTING value from ordinary startup-control locations only.
    $deniedPathPatterns=@(
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SAM(\\|$)',
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SECURITY(\\|$)',
        '(?i)\\Credentials?(\\|$)',
        '(?i)\\Credential Manager(\\|$)',
        '(?i)\\Vault(\\|$)',
        '(?i)\\Protected Storage(\\|$)',
        '(?i)\\Control\\Lsa(\\|$)',
        '(?i)\\Windows Defender(\\|$)',
        '(?i)\\SecurityHealth(\\|$)',
        '(?i)\\Winlogon(\\|$)',
        '(?i)\\Image File Execution Options(\\|$)',
        '(?i)\\SilentProcessExit(\\|$)',
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services(\\|$)',
        '(?i)^Registry::HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet[0-9]+\\Services(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\CLSID(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\AppID(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\TypeLib(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\.*\\shell(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\.*\\command(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\.*\\InprocServer32(\\|$)',
        '(?i)^Registry::HKEY_CLASSES_ROOT\\.*\\LocalServer32(\\|$)'
    )
    if(-not $AllowStartupRemoval){
        $deniedPathPatterns += '(?i)\\Run(Once|Services|ServicesOnce)?(\\|$)'
        $deniedPathPatterns += '(?i)\\StartupApproved(\\|$)'
    }
    foreach($pattern in $deniedPathPatterns){
        if($NormalizedPath -match $pattern){throw 'This registry location is denied by the Dr.Swintus safety policy.'}
    }
    $deniedValueNames=@('AppInit_DLLs','LoadAppInit_DLLs','Userinit','Shell','BootExecute','Debugger','GlobalFlag','DelegateExecute')
    foreach($deniedName in $deniedValueNames){
        if($Name.Equals($deniedName,[StringComparison]::OrdinalIgnoreCase)){
            throw 'This registry value is denied by the Dr.Swintus safety policy.'
        }
    }
}

function Test-RegistryStartupControlPath {
    param([string]$NormalizedPath)
    return ($NormalizedPath -match '(?i)\\Run(Once)?$' -or $NormalizedPath -match '(?i)\\StartupApproved(\\|$)')
}

function Get-RegistryRead {
    param([string]$Path,[string]$Name='')
    $normalized=Convert-RegistryPath -Path $Path
    Assert-RegistryReadTarget -NormalizedPath $normalized -Name $Name
    if(-not (Test-Path -LiteralPath $normalized)){throw ("Registry path not found: {0}" -f $normalized)}
    $item=Get-ItemProperty -LiteralPath $normalized -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($Name)){
        $props=[ordered]@{}
        foreach($pr in $item.PSObject.Properties){
            if($pr.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'){
                $v=$pr.Value
                if($v -is [string]){$v=Truncate-Text $v 4000}
                $props[$pr.Name]=$v
            }
        }
        return [pscustomobject]@{Path=$normalized;Values=[pscustomobject]$props}
    }
    $value=(Get-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop).$Name
    if($value -is [string]){$value=Truncate-Text $value 4000}
    [pscustomobject]@{Path=$normalized;Name=$Name;Value=$value}
}

function Assert-RegistryWriteTarget {
    param([string]$Path,[string]$Name)
    if([string]::IsNullOrWhiteSpace($Name)){throw 'Registry value Name is required.'}
    if($Name.Length -gt 200){throw 'Registry value name is too long.'}
    if($Name -match '[\x00-\x1F\x7F]'){throw 'Registry value name contains control characters.'}
    $normalized=Convert-RegistryPath -Path $Path
    Assert-RegistryWriteTargetDenied -NormalizedPath $normalized -Name $Name
    return $normalized
}

function Confirm-RegistryChange {
    param([string]$Path,[string]$Name,$OldValue,$NewValue,[string]$Type)
    $oldText=if($null -eq $OldValue){'<not set>'}else{[string]$OldValue}
    $newText=if($null -eq $NewValue){'<null>'}else{[string]$NewValue}
    if($oldText.Length -gt 300){$oldText=$oldText.Substring(0,300)+'...'}
    if($newText.Length -gt 300){$newText=$newText.Substring(0,300)+'...'}
    $message="Изменить параметр Windows?`r`n`r`nРаздел: $Path`r`nПараметр: $Name`r`nТип: $Type`r`nБыло: $oldText`r`nСтанет: $newText`r`n`r`nИзменение будет выполнено с повышенными правами через Broker."
    Write-BrokerLog ("REGISTRY_CONFIRM_DIALOG_SHOW path={0} name={1} type={2}" -f $Path,$Name,$Type)
    Initialize-BrokerMessageBox
    # MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST.
    # SYSTEMMODAL + SETFOREGROUND + TOPMOST keeps the explicit Broker consent dialog above normal application windows.
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swintus',$flags)
    if($answer -eq 6){
        Write-BrokerLog ("REGISTRY_CONFIRM_USER_YES path={0} name={1}" -f $Path,$Name)
        return $true
    }
    Write-BrokerLog ("REGISTRY_CONFIRM_USER_NO path={0} name={1} result={2}" -f $Path,$Name,$answer)
    return $false
}

function Confirm-RegistryRemove {
    param([string]$Path,[string]$Name,$OldValue)
    $oldText=if($null -eq $OldValue){'<null>'}else{[string]$OldValue}
    if($oldText.Length -gt 500){$oldText=$oldText.Substring(0,500)+'...'}
    $message="Удалить параметр реестра?`r`n`r`nРаздел: $Path`r`nПараметр: $Name`r`nТекущее значение: $oldText`r`n`r`nУдаление будет выполнено с повышенными правами через Broker."
    Write-BrokerLog ("REGISTRY_REMOVE_CONFIRM_DIALOG_SHOW path={0} name={1}" -f $Path,$Name)
    Initialize-BrokerMessageBox
    # MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST.
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swintus',$flags)
    if($answer -eq 6){
        Write-BrokerLog ("REGISTRY_REMOVE_CONFIRM_USER_YES path={0} name={1}" -f $Path,$Name)
        return $true
    }
    Write-BrokerLog ("REGISTRY_REMOVE_CONFIRM_USER_NO path={0} name={1} result={2}" -f $Path,$Name,$answer)
    return $false
}

function Remove-RegistryValueConfirmed {
    param([string]$Path,[string]$Name,[bool]$NotifyShell=$true)
    if([string]::IsNullOrWhiteSpace($Name)){throw 'Registry value Name is required.'}
    if($Name.Length -gt 200){throw 'Registry value name is too long.'}
    if($Name -match '[\x00-\x1F\x7F]'){throw 'Registry value name contains control characters.'}
    $normalized=Convert-RegistryPath -Path $Path
    if(-not (Test-Path -LiteralPath $normalized -PathType Container)){throw ("Registry path not found: {0}" -f $normalized)}

    $startupRemoval=Test-RegistryStartupControlPath -NormalizedPath $normalized
    Assert-RegistryWriteTargetDenied -NormalizedPath $normalized -Name $Name -AllowStartupRemoval:$startupRemoval

    try {
        $oldItem=Get-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop
        $oldValue=$oldItem.$Name
    } catch {
        throw ("Registry value not found: {0} -> {1}" -f $normalized,$Name)
    }

    Write-BrokerLog ("REGISTRY_REMOVE_BEGIN path={0} name={1} startupControl={2}" -f $normalized,$Name,$startupRemoval)
    if(-not (Confirm-RegistryRemove -Path $normalized -Name $Name -OldValue $oldValue)){
        Write-BrokerLog ("REGISTRY_REMOVE_DECLINED path={0} name={1}" -f $normalized,$Name)
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Path=$normalized;Name=$Name;OldValue=$oldValue;Verified=$false}
    }

    try {Remove-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop}
    catch {
        Write-BrokerLog ("REGISTRY_REMOVE_ERROR path={0} name={1} error={2}" -f $normalized,$Name,$_.Exception.Message)
        throw
    }
    if($NotifyShell){Notify-ShellSettingChanged -RegistryPath $normalized}

    $stillExists=$false
    try {
        [void](Get-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop)
        $stillExists=$true
    } catch [System.Management.Automation.PSArgumentException] {
        $stillExists=$false
    } catch [System.Management.Automation.ItemNotFoundException] {
        $stillExists=$false
    } catch {
        Write-BrokerLog ("REGISTRY_REMOVE_VERIFY_ERROR path={0} name={1} error={2}" -f $normalized,$Name,$_.Exception.Message)
        throw
    }
    $verified=-not $stillExists
    Write-BrokerLog ("REGISTRY_REMOVE_VERIFY path={0} name={1} verified={2}" -f $normalized,$Name,$verified)
    if(-not $verified){throw 'Registry value removal completed but verification shows the value still exists.'}
    [pscustomobject]@{Confirmed=$true;Changed=$true;Path=$normalized;Name=$Name;OldValue=$oldValue;Verified=$true;ShellNotified=$NotifyShell;StartupControl=$startupRemoval}
}

function Notify-ShellSettingChanged {
    param([string]$RegistryPath)
    if(-not ('DrSwintus.NativeSettingsNotify' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DrSwintus {
    public static class NativeSettingsNotify {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeoutW(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
'@
    }
    try {
        $result=[UIntPtr]::Zero
        [void][DrSwintus.NativeSettingsNotify]::SendMessageTimeoutW(
            [IntPtr]0xffff,0x001A,[UIntPtr]::Zero,$RegistryPath,0x0002,2000,[ref]$result)
        Write-BrokerLog ("REGISTRY_NOTIFY_SENT path={0}" -f $RegistryPath)
    } catch {
        Write-BrokerLog ("REGISTRY_NOTIFY_ERROR path={0} error={1}" -f $RegistryPath,$_.Exception.Message)
    }
}

function Set-RegistryValueConfirmed {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [ValidateSet('DWord','QWord','String')][string]$Type='String',
        [bool]$NotifyShell=$true
    )
    $normalized=Assert-RegistryWriteTarget -Path $Path -Name $Name
    if(-not (Test-Path -LiteralPath $normalized -PathType Container)){
        throw ("Registry path not found: {0}" -f $normalized)
    }

    $typedValue=$null
    switch($Type){
        'DWord' {
            try {$typedValue=[uint32]$Value} catch {throw 'DWord Value must be an unsigned 32-bit integer.'}
        }
        'QWord' {
            try {$typedValue=[uint64]$Value} catch {throw 'QWord Value must be an unsigned 64-bit integer.'}
        }
        'String' {
            $typedValue=[string]$Value
            if($typedValue.Length -gt 4000){throw 'String Value is too long.'}
            if($typedValue -match '[\x00]'){throw 'String Value contains a NUL character.'}
        }
    }

    $oldValue=$null
    $oldExists=$false
    try {
        $oldItem=Get-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop
        $oldValue=$oldItem.$Name
        $oldExists=$true
    } catch [System.Management.Automation.PSArgumentException] {
        $oldExists=$false
    } catch [System.Management.Automation.ItemNotFoundException] {
        $oldExists=$false
    }

    Write-BrokerLog ("REGISTRY_SET_BEGIN path={0} name={1} type={2}" -f $normalized,$Name,$Type)
    $oldForPrompt=if($oldExists){$oldValue}else{$null}
    if(-not (Confirm-RegistryChange -Path $normalized -Name $Name -OldValue $oldForPrompt -NewValue $typedValue -Type $Type)){
        Write-BrokerLog ("REGISTRY_SET_DECLINED path={0} name={1}" -f $normalized,$Name)
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Path=$normalized;Name=$Name;Type=$Type;OldValue=$oldValue;NewValue=$typedValue;Verified=$false}
    }

    try {
        if($oldExists){
            Set-ItemProperty -LiteralPath $normalized -Name $Name -Value $typedValue -ErrorAction Stop
        } else {
            New-ItemProperty -LiteralPath $normalized -Name $Name -Value $typedValue -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-BrokerLog ("REGISTRY_SET_ERROR path={0} name={1} error={2}" -f $normalized,$Name,$_.Exception.Message)
        throw
    }

    if($NotifyShell){Notify-ShellSettingChanged -RegistryPath $normalized}

    $verify=Get-ItemProperty -LiteralPath $normalized -Name $Name -ErrorAction Stop
    $actual=$verify.$Name
    $verified=([string]$actual -eq [string]$typedValue)
    Write-BrokerLog ("REGISTRY_SET_VERIFY path={0} name={1} verified={2} actual={3}" -f $normalized,$Name,$verified,$actual)
    if(-not $verified){throw 'Registry write completed but verification did not match the requested value.'}
    [pscustomobject]@{Confirmed=$true;Changed=$true;Path=$normalized;Name=$Name;Type=$Type;OldValue=$oldValue;NewValue=$typedValue;ActualValue=$actual;Verified=$true;ShellNotified=$NotifyShell}
}

function Get-WindowsPowerShellPath {
    $path=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Windows PowerShell 5.1 executable was not found.'}
    return $path
}

function Invoke-WindowsPowerShellAppx {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('RegisterDesktopAppInstaller','InstallBundle','GetDesktopAppInstaller')][string]$Operation,
        [string]$BundlePath=''
    )
    $powershell=Get-WindowsPowerShellPath
    $scriptText=''
    $envName='DRSW_APPX_BUNDLE'
    switch($Operation){
        'RegisterDesktopAppInstaller' {
            $scriptText="`$ErrorActionPreference='Stop'; Import-Module Appx -ErrorAction Stop; Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop"
        }
        'InstallBundle' {
            if([string]::IsNullOrWhiteSpace($BundlePath)){throw 'BundlePath is required for InstallBundle.'}
            $full=[IO.Path]::GetFullPath($BundlePath)
            if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'App Installer bundle file was not found.'}
            [Environment]::SetEnvironmentVariable($envName,$full,'Process')
            $scriptText="`$ErrorActionPreference='Stop'; Import-Module Appx -ErrorAction Stop; `$p=[Environment]::GetEnvironmentVariable('$envName','Process'); if([string]::IsNullOrWhiteSpace(`$p)){throw 'Bundle environment path missing.'}; Add-AppxPackage -Path `$p -ForceApplicationShutdown -ErrorAction Stop"
        }
        'GetDesktopAppInstaller' {
            $scriptText="`$ErrorActionPreference='Stop'; Import-Module Appx -ErrorAction Stop; `$p=Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1; if(`$null -eq `$p){exit 3}; [pscustomobject]@{Name=[string]`$p.Name;Version=[string]`$p.Version;Publisher=[string]`$p.Publisher;PackageFullName=[string]`$p.PackageFullName} | ConvertTo-Json -Compress"
        }
    }
    try {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
        $output=& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        $exit=$LASTEXITCODE
        $text=($output | Out-String).Trim()
        if($exit -ne 0){throw ("Windows PowerShell Appx operation {0} failed with exit code {1}: {2}" -f $Operation,$exit,(Truncate-Text $text 4000))}
        return $text
    } finally {
        if($Operation -eq 'InstallBundle'){[Environment]::SetEnvironmentVariable($envName,$null,'Process')}
    }
}

function Confirm-WingetBootstrap {
    $message="Windows Package Manager (winget) недоступен.`r`n`r`nУстановить или восстановить официальный Microsoft App Installer?`r`nИсточник загрузки: https://aka.ms/getwinget`r`n`r`nПосле установки Dr.Swinux продолжит управление пакетами через typed broker."
    Write-BrokerLog 'WINGET_BOOTSTRAP_CONFIRM_DIALOG_SHOW'
    Initialize-BrokerMessageBox
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swinux',$flags)
    if($answer -eq 6){Write-BrokerLog 'WINGET_BOOTSTRAP_CONFIRM_USER_YES';return $true}
    Write-BrokerLog ("WINGET_BOOTSTRAP_CONFIRM_USER_NO result={0}" -f $answer)
    return $false
}

function Test-WingetReady {
    try {$null=Get-WingetPath;return $true}catch{return $false}
}

function Ensure-Winget {
    if(Test-WingetReady){
        $path=Get-WingetPath
        Write-BrokerLog ("WINGET_BOOTSTRAP_ALREADY_READY path={0}" -f $path)
        return [pscustomobject]@{Confirmed=$null;Changed=$false;Ready=$true;Method='AlreadyAvailable';Path=$path}
    }
    if(-not (Confirm-WingetBootstrap)){
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Ready=$false;Method='Declined';Path=$null}
    }
    Write-BrokerLog 'WINGET_BOOTSTRAP_BEGIN'
    try {
        $null=Invoke-WindowsPowerShellAppx -Operation RegisterDesktopAppInstaller
        Write-BrokerLog 'WINGET_BOOTSTRAP_REGISTER_BY_FAMILY_OK host=WindowsPowerShell'
    } catch {
        Write-BrokerLog ("WINGET_BOOTSTRAP_REGISTER_BY_FAMILY_SKIPPED host=WindowsPowerShell error={0}" -f $_.Exception.Message)
    }
    if(Test-WingetReady){
        $path=Get-WingetPath
        Write-BrokerLog ("WINGET_BOOTSTRAP_READY method=RegisterByFamilyName host=WindowsPowerShell path={0}" -f $path)
        return [pscustomobject]@{Confirmed=$true;Changed=$true;Ready=$true;Method='RegisterByFamilyNameWindowsPowerShell';Path=$path}
    }
    $bundle=Join-Path $brokerRoot 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    try {
        Write-BrokerLog 'WINGET_BOOTSTRAP_DOWNLOAD_BEGIN source=https://aka.ms/getwinget'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        if(-not (Test-Path -LiteralPath $bundle -PathType Leaf)){throw 'App Installer download did not create a file.'}
        $length=(Get-Item -LiteralPath $bundle).Length
        if($length -lt 1MB){throw ("Downloaded App Installer bundle is unexpectedly small: {0} bytes." -f $length)}
        Write-BrokerLog ("WINGET_BOOTSTRAP_DOWNLOAD_OK bytes={0}" -f $length)
        $null=Invoke-WindowsPowerShellAppx -Operation InstallBundle -BundlePath $bundle
        Write-BrokerLog 'WINGET_BOOTSTRAP_ADD_APPX_OK host=WindowsPowerShell'
    } finally {
        Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
    }
    try {$null=Invoke-WindowsPowerShellAppx -Operation RegisterDesktopAppInstaller} catch {
        Write-BrokerLog ("WINGET_BOOTSTRAP_POST_REGISTER_SKIPPED host=WindowsPowerShell error={0}" -f $_.Exception.Message)
    }
    if(-not (Test-WingetReady)){throw 'Microsoft App Installer was installed/registered through Windows PowerShell, but winget is still unavailable.'}
    $packageText=Invoke-WindowsPowerShellAppx -Operation GetDesktopAppInstaller
    try {$package=$packageText | ConvertFrom-Json -ErrorAction Stop} catch {throw 'winget became available but App Installer package verification output was invalid.'}
    $publisher=[string]$package.Publisher
    if($publisher -notmatch '(?i)Microsoft Corporation'){throw ("Unexpected App Installer publisher: {0}" -f $publisher)}
    $path=Get-WingetPath
    Write-BrokerLog ("WINGET_BOOTSTRAP_READY method=OfficialMicrosoftBundle host=WindowsPowerShell version={0} path={1}" -f $package.Version,$path)
    [pscustomobject]@{Confirmed=$true;Changed=$true;Ready=$true;Method='OfficialMicrosoftBundleWindowsPowerShell';Path=$path;Version=[string]$package.Version;Publisher=$publisher}
}

function Get-WingetPath {
    $cmd=Get-Command winget.exe -ErrorAction SilentlyContinue
    if($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)){
        return $cmd.Source
    }

    $aliasPath=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if(Test-Path -LiteralPath $aliasPath -PathType Leaf){return $aliasPath}

    $windowsApps=Join-Path $env:ProgramFiles 'WindowsApps'
    if(Test-Path -LiteralPath $windowsApps -PathType Container){
        $candidates=@(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        foreach($dir in $candidates){
            $candidate=Join-Path $dir.FullName 'winget.exe'
            if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
        }
    }
    throw 'Windows Package Manager (winget) is not available on this computer.'
}

function Invoke-Winget {
    param([string[]]$Arguments,[int]$MaxOutput=30000)
    $winget=Get-WingetPath
    $text=''
    $exitCode=$null
    try {
        $text=(& $winget @Arguments 2>&1 | Out-String)
        $exitCode=$LASTEXITCODE
    } catch {
        throw ("winget failed to start: {0}" -f $_.Exception.Message)
    }
    [pscustomobject]@{ExitCode=$exitCode;Output=Truncate-Text $text $MaxOutput}
}

function Assert-PackageId {
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){throw 'Package Id is required.'}
    if($Id.Length -gt 200){throw 'Package Id is too long.'}
    if($Id -ne $Id.Trim()){throw 'Package Id must not have leading or trailing whitespace.'}
    if($Id.StartsWith('-')){throw 'Package Id must not start with a dash.'}
    if($Id -match '[\x00-\x1F\x7F]'){throw 'Package Id contains control characters.'}
}

function Get-InstalledPackages {
    param([string]$Query='')
    if($Query.Length -gt 200){throw 'Query is too long.'}
    if($Query -match '[\x00-\x1F\x7F]'){throw 'Query contains control characters.'}
    $args=@('list','--accept-source-agreements','--disable-interactivity')
    if(-not [string]::IsNullOrWhiteSpace($Query)){$args += @('--query',$Query)}
    Invoke-Winget -Arguments $args
}

function Search-Package {
    param([string]$Query)
    if([string]::IsNullOrWhiteSpace($Query)){throw 'Query is required.'}
    if($Query.Length -gt 200){throw 'Query is too long.'}
    if($Query -match '[\x00-\x1F\x7F]'){throw 'Query contains control characters.'}
    Invoke-Winget -Arguments @('search','--query',$Query,'--source','winget','--accept-source-agreements','--disable-interactivity')
}

function Get-TrustedPackageCatalog {
    $path=Join-Path $PSScriptRoot 'catalog\trusted-packages.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Trusted package catalog is missing.'}
    try {$catalog=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop} catch {throw ("Trusted package catalog is invalid JSON: {0}" -f $_.Exception.Message)}
    if([int]$catalog.schemaVersion -ne 1){throw ("Unsupported trusted package catalog schema: {0}" -f $catalog.schemaVersion)}
    if($null -eq $catalog.packages){throw 'Trusted package catalog has no packages array.'}
    return $catalog
}

function Get-TrustedPackageDefinition {
    param([string]$Id)
    Assert-PackageId -Id $Id
    $catalog=Get-TrustedPackageCatalog
    $matches=@($catalog.packages | Where-Object {[string]$_.id -ieq $Id})
    if($matches.Count -ne 1){
        if($matches.Count -eq 0){throw ("Package is not present in the packaged trusted catalog: {0}" -f $Id)}
        throw ("Trusted package catalog contains duplicate PackageIdentifier: {0}" -f $Id)
    }
    $package=$matches[0]
    if([string]::IsNullOrWhiteSpace([string]$package.version)){throw 'Trusted package version is missing.'}
    if($null -eq $package.installers -or @($package.installers).Count -eq 0){throw 'Trusted package has no installers.'}
    return $package
}

function Search-TrustedPackages {
    param([string]$Query)
    if([string]::IsNullOrWhiteSpace($Query)){throw 'Query is required.'}
    if($Query.Length -gt 200){throw 'Query is too long.'}
    if($Query -match '[\x00-\x1F\x7F]'){throw 'Query contains control characters.'}
    $needle=$Query.Trim()
    $catalog=Get-TrustedPackageCatalog
    @($catalog.packages | Where-Object {
        ([string]$_.id -like ('*'+$needle+'*')) -or ([string]$_.displayName -like ('*'+$needle+'*'))
    } | Select-Object -First 50 | ForEach-Object {
        [pscustomobject]@{Id=[string]$_.id;Version=[string]$_.version;DisplayName=[string]$_.displayName;Architectures=@($_.installers|ForEach-Object{[string]$_.architecture}|Sort-Object -Unique)}
    })
}

function Get-TrustedNativeArchitecture {
    $arch=[string]$env:PROCESSOR_ARCHITECTURE
    if($arch -match '(?i)ARM64'){return 'arm64'}
    if([Environment]::Is64BitOperatingSystem){return 'x64'}
    return 'x86'
}

function Select-TrustedPackageInstaller {
    param($Package)
    $native=Get-TrustedNativeArchitecture
    $preferred=if($native -eq 'x64'){@('x64','x86')}else{@($native)}
    $selected=$null
    foreach($arch in $preferred){
        $selected=@($Package.installers | Where-Object {[string]$_.architecture -ieq $arch}) | Select-Object -First 1
        if($null -ne $selected){break}
    }
    if($null -eq $selected){throw ("Trusted catalog has no compatible installer for architecture {0}." -f $native)}
    $type=([string]$selected.installerType).ToLowerInvariant()
    if($type -notin @('msi','wix','exe')){throw ("Trusted installer type is not allowed: {0}" -f $type)}
    $url=[string]$selected.url
    if($url -notmatch '^https://'){throw 'Trusted installer URL must use HTTPS.'}
    try {$uri=[Uri]$url} catch {throw 'Trusted installer URL is invalid.'}
    if($uri.Scheme -ne 'https'){throw 'Trusted installer URL scheme is not HTTPS.'}
    $sha=([string]$selected.sha256).ToUpperInvariant()
    if($sha -notmatch '^[A-F0-9]{64}$'){throw 'Trusted installer SHA-256 is invalid.'}
    $productCode=[string]$selected.productCode
    $displayPattern=[string]$selected.displayNamePattern
    if([string]::IsNullOrWhiteSpace($productCode)-and[string]::IsNullOrWhiteSpace($displayPattern)){throw 'Trusted installer has no post-install verification metadata.'}
    $silentArgs=@()
    if($type -eq 'exe'){
        foreach($a in @($selected.silentArgs)){
            $arg=[string]$a
            if([string]::IsNullOrWhiteSpace($arg)-or$arg.Length -gt 500-or$arg -match '[\x00-\x1F\x7F]'){throw 'Trusted EXE silent argument is invalid.'}
            $silentArgs += $arg
        }
        if($silentArgs.Count -eq 0){throw 'Trusted EXE installer has no fixed silent arguments.'}
    }
    [pscustomobject]@{Architecture=[string]$selected.architecture;InstallerType=$type;Url=$url;Sha256=$sha;ProductCode=$productCode;DisplayNamePattern=$displayPattern;SilentArgs=$silentArgs}
}

function Find-TrustedInstalledPackage {
    param([string]$ProductCode,[string]$DisplayNamePattern)
    $roots=@(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach($root in $roots){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
        foreach($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
            $keyName=[string]$key.PSChildName
            $item=$null;try{$item=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop}catch{continue}
            $display=[string]$item.DisplayName
            $codeMatch=(-not[string]::IsNullOrWhiteSpace($ProductCode))-and($keyName -ieq $ProductCode)
            $nameMatch=$false
            if(-not[string]::IsNullOrWhiteSpace($DisplayNamePattern)-and-not[string]::IsNullOrWhiteSpace($display)){
                try {$nameMatch=($display -match $DisplayNamePattern)} catch {throw 'Trusted catalog displayNamePattern is invalid.'}
            }
            if($codeMatch -or $nameMatch){return [pscustomobject]@{DisplayName=$display;DisplayVersion=[string]$item.DisplayVersion;Publisher=[string]$item.Publisher;RegistryKey=$key.PSPath}}
        }
    }
    return $null
}

function Confirm-TrustedPackageInstall {
    param($Package,$Installer)
    $display=if([string]::IsNullOrWhiteSpace([string]$Package.displayName)){[string]$Package.id}else{[string]$Package.displayName}
    $message="Установить программу из упакованного доверенного каталога?`r`n`r`nНазвание: $display`r`nPackage ID: $($Package.id)`r`nВерсия: $($Package.version)`r`nАрхитектура: $($Installer.Architecture)`r`nИсточник: $($Installer.Url)`r`n`r`nDr.Swinux проверит закреплённый SHA-256 перед запуском.`r`nURL, хеш и параметры установки не принимаются от Codex.`r`nДействие будет выполнено с правами администратора."
    Write-BrokerLog ("TRUSTED_CATALOG_CONFIRM_DIALOG_SHOW id={0} version={1}" -f $Package.id,$Package.version)
    Initialize-BrokerMessageBox
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swinux',$flags)
    if($answer -eq 6){Write-BrokerLog ("TRUSTED_CATALOG_CONFIRM_USER_YES id={0}" -f $Package.id);return $true}
    Write-BrokerLog ("TRUSTED_CATALOG_CONFIRM_USER_NO id={0} result={1}" -f $Package.id,$answer)
    return $false
}

function Install-TrustedPackageCatalog {
    param([string]$Id)
    $package=Get-TrustedPackageDefinition -Id $Id
    $installerDef=Select-TrustedPackageInstaller -Package $package
    $existing=Find-TrustedInstalledPackage -ProductCode $installerDef.ProductCode -DisplayNamePattern $installerDef.DisplayNamePattern
    if($null -ne $existing){
        Write-BrokerLog ("TRUSTED_CATALOG_ALREADY_INSTALLED id={0} display={1} version={2}" -f $package.id,$existing.DisplayName,$existing.DisplayVersion)
        return [pscustomobject]@{Confirmed=$null;Changed=$false;Verified=$true;Id=[string]$package.id;Version=[string]$package.version;Method='TrustedCatalog';Installed=$existing}
    }
    if(-not(Confirm-TrustedPackageInstall -Package $package -Installer $installerDef)){
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Verified=$false;Id=[string]$package.id;Version=[string]$package.version;Method='TrustedCatalog'}
    }

    $extension=if($installerDef.InstallerType -in @('msi','wix')){'.msi'}else{'.exe'}
    $downloadPath=Join-Path $brokerRoot (('trusted-package-{0}{1}' -f ([guid]::NewGuid().ToString('N')),$extension))
    try {
        Write-BrokerLog ("TRUSTED_CATALOG_DOWNLOAD_BEGIN id={0} source={1}" -f $package.id,$installerDef.Url)
        Invoke-WebRequest -Uri $installerDef.Url -OutFile $downloadPath -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        if(-not(Test-Path -LiteralPath $downloadPath -PathType Leaf)){throw 'Trusted package download did not create a file.'}
        $length=(Get-Item -LiteralPath $downloadPath).Length
        if($length -lt 32768){throw ("Downloaded trusted package is unexpectedly small: {0} bytes." -f $length)}
        $actualHash=(Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        Write-BrokerLog ("TRUSTED_CATALOG_SHA256 id={0} expected={1} actual={2}" -f $package.id,$installerDef.Sha256,$actualHash)
        if($actualHash -ne $installerDef.Sha256){throw ("Trusted package SHA-256 mismatch. Expected {0}, got {1}." -f $installerDef.Sha256,$actualHash)}

        if($installerDef.InstallerType -in @('msi','wix')){
            $args=@('/i',('"{0}"' -f $downloadPath),'/qn','/norestart')
            Write-BrokerLog ("TRUSTED_CATALOG_INSTALL_BEGIN id={0} type={1}" -f $package.id,$installerDef.InstallerType)
            $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        } else {
            Write-BrokerLog ("TRUSTED_CATALOG_INSTALL_BEGIN id={0} type=exe" -f $package.id)
            $process=Start-Process -FilePath $downloadPath -ArgumentList $installerDef.SilentArgs -Wait -PassThru -WindowStyle Hidden
        }
        Write-BrokerLog ("TRUSTED_CATALOG_INSTALL_EXIT id={0} exitCode={1}" -f $package.id,$process.ExitCode)
        if($process.ExitCode -notin @(0,1641,3010)){throw ("Trusted package installer exited with code {0}." -f $process.ExitCode)}
    } finally {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
    $installed=Find-TrustedInstalledPackage -ProductCode $installerDef.ProductCode -DisplayNamePattern $installerDef.DisplayNamePattern
    if($null -eq $installed){throw 'Trusted package installer completed, but uninstall-registry verification did not find the package.'}
    Write-BrokerLog ("TRUSTED_CATALOG_VERIFY id={0} display={1} version={2}" -f $package.id,$installed.DisplayName,$installed.DisplayVersion)
    [pscustomobject]@{Confirmed=$true;Changed=$true;Verified=$true;Id=[string]$package.id;Version=[string]$package.version;Method='TrustedCatalog';Installed=$installed;InstallerType=$installerDef.InstallerType;Architecture=$installerDef.Architecture}
}

function Install-TrustedPackageFallback {
    param([string]$Id)
    Install-TrustedPackageCatalog -Id $Id
}
function Get-TrustedHklmInstalledMatches {
    param($Package)
    $productCodes=@($Package.installers | ForEach-Object {[string]$_.productCode} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    $displayPatterns=@($Package.installers | ForEach-Object {[string]$_.displayNamePattern} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    $publisherPatterns=@($Package.installers | ForEach-Object {[string]$_.publisherPattern} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    if($productCodes.Count -eq 0 -and $displayPatterns.Count -eq 0){throw 'Trusted package has no uninstall-registry correlation metadata.'}

    $roots=@(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    # Do not use $matches here: PowerShell's -match operator writes the automatic $Matches hashtable.
    $entries=@()
    foreach($root in $roots){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
        foreach($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
            $item=$null
            try {$item=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop} catch {continue}
            $keyName=[string]$key.PSChildName
            $display=[string]$item.DisplayName
            $publisher=[string]$item.Publisher
            $matched=$false
            foreach($code in $productCodes){if($keyName -ieq $code){$matched=$true;break}}
            if(-not $matched -and -not [string]::IsNullOrWhiteSpace($display)){
                foreach($pattern in $displayPatterns){
                    try {if($display -match $pattern){$matched=$true;break}} catch {throw 'Trusted catalog displayNamePattern is invalid.'}
                }
            }
            if(-not $matched){continue}
            if($publisherPatterns.Count -gt 0){
                $publisherMatched=$false
                foreach($pattern in $publisherPatterns){
                    try {if($publisher -match $pattern){$publisherMatched=$true;break}} catch {throw 'Trusted catalog publisherPattern is invalid.'}
                }
                if(-not $publisherMatched){continue}
            }
            $entries += [pscustomobject]@{
                RegistryKey=[string]$key.PSPath
                RegistryLeaf=$keyName
                DisplayName=$display
                DisplayVersion=[string]$item.DisplayVersion
                Publisher=$publisher
                QuietUninstallString=[string]$item.QuietUninstallString
            }
        }
    }
    return @($entries)
}

function Convert-TrustedQuietUninstallCommand {
    param([string]$Command)
    if([string]::IsNullOrWhiteSpace($Command)){throw 'Registered package has no QuietUninstallString.'}
    if($Command.Length -gt 2000 -or $Command -match '[\x00-\x1F\x7F]'){throw 'QuietUninstallString is invalid.'}
    $match=[regex]::Match($Command,'^\s*"(?<exe>[A-Za-z]:\\[^\"]+\.exe)"\s*(?<args>.*)\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $match.Success){throw 'QuietUninstallString must contain one quoted absolute EXE path.'}
    $exe=[IO.Path]::GetFullPath($match.Groups['exe'].Value)
    if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw ("Registered uninstaller executable was not found: {0}" -f $exe)}
    $leaf=[IO.Path]::GetFileName($exe).ToLowerInvariant()
    if($leaf -in @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','rundll32.exe')){throw ("Registered uninstaller executable is not allowed: {0}" -f $leaf)}

    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | ForEach-Object {([IO.Path]::GetFullPath($_).TrimEnd('\')+'\')}
    $allowed=$false
    foreach($root in $roots){if($exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){$allowed=$true;break}}
    if(-not $allowed){throw 'Registered uninstaller must be located under Program Files.'}

    $argText=$match.Groups['args'].Value.Trim()
    if([string]::IsNullOrWhiteSpace($argText)){throw 'QuietUninstallString has no silent-uninstall argument.'}
    if($argText -match '["''`;&|<>$()]'){throw 'QuietUninstallString contains unsupported shell or quoting syntax.'}
    $args=@($argText -split '\s+' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($args.Count -lt 1 -or $args.Count -gt 8){throw 'QuietUninstallString has an unsupported argument count.'}
    $allowedArgs=@('/s','/silent','/quiet','/verysilent','/suppressmsgboxes','/norestart','-s','--silent','--quiet')
    foreach($arg in $args){if(([string]$arg).ToLowerInvariant() -notin $allowedArgs){throw ("QuietUninstallString argument is not allowlisted: {0}" -f $arg)}}
    [pscustomobject]@{FilePath=$exe;Arguments=$args;Raw=$Command}
}

function Confirm-TrustedPackageUninstall {
    param($Package,$Entry,$Command)
    $display=if([string]::IsNullOrWhiteSpace($Entry.DisplayName)){[string]$Package.id}else{$Entry.DisplayName}
    $message="Удалить установленную программу через её зарегистрированный тихий деинсталлятор?`r`n`r`nНазвание: $display`r`nВерсия: $($Entry.DisplayVersion)`r`nИздатель: $($Entry.Publisher)`r`nPackage ID: $($Package.id)`r`nДеинсталлятор: $($Command.FilePath)`r`n`r`nКоманда взята только из HKLM uninstall registry после сопоставления с доверенным каталогом Dr.Swinux.`r`nCodex не может передать путь или аргументы.`r`nДействие будет выполнено с правами администратора."
    Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_DIALOG_SHOW id={0} display={1}" -f $Package.id,$display)
    Initialize-BrokerMessageBox
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swinux',$flags)
    if($answer -eq 6){Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_USER_YES id={0}" -f $Package.id);return $true}
    Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_USER_NO id={0} result={1}" -f $Package.id,$answer)
    return $false
}

function Uninstall-TrustedPackage {
    param([string]$Id)
    Assert-PackageId -Id $Id
    $package=Get-TrustedPackageDefinition -Id $Id
    $entries=@(Get-TrustedHklmInstalledMatches -Package $package)
    if($entries.Count -eq 0){return [pscustomobject]@{Confirmed=$null;Changed=$false;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';Installed=$false}}
    if($entries.Count -ne 1){throw ("Trusted uninstall registry match is ambiguous for {0}: {1} entries." -f $package.id,$entries.Count)}
    $entry=$entries[0]
    Write-BrokerLog ("TRUSTED_UNINSTALL_MATCH id={0} key={1} display={2} version={3} publisher={4}" -f $package.id,$entry.RegistryLeaf,$entry.DisplayName,$entry.DisplayVersion,$entry.Publisher)
    $command=Convert-TrustedQuietUninstallCommand -Command $entry.QuietUninstallString
    if(-not(Confirm-TrustedPackageUninstall -Package $package -Entry $entry -Command $command)){
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Verified=$false;Id=[string]$package.id;Method='RegisteredTrustedUninstall'}
    }

    $fresh=Get-ItemProperty -LiteralPath $entry.RegistryKey -ErrorAction Stop
    if([string]$fresh.DisplayName -ne $entry.DisplayName -or [string]$fresh.Publisher -ne $entry.Publisher -or [string]$fresh.QuietUninstallString -ne $entry.QuietUninstallString){throw 'Registered uninstall metadata changed after confirmation; refusing to execute.'}
    $freshCommand=Convert-TrustedQuietUninstallCommand -Command ([string]$fresh.QuietUninstallString)
    if($freshCommand.FilePath -ne $command.FilePath -or (($freshCommand.Arguments -join "`n") -ne ($command.Arguments -join "`n"))){throw 'Registered uninstall command changed after confirmation; refusing to execute.'}

    Write-BrokerLog ("TRUSTED_UNINSTALL_EXECUTE id={0} path={1} args={2}" -f $package.id,$command.FilePath,($command.Arguments -join ' '))
    $process=Start-Process -FilePath $command.FilePath -ArgumentList $command.Arguments -Wait -PassThru -WindowStyle Hidden
    Write-BrokerLog ("TRUSTED_UNINSTALL_EXIT id={0} exitCode={1}" -f $package.id,$process.ExitCode)
    if($process.ExitCode -notin @(0,1641,3010)){throw ("Trusted registered uninstaller exited with code {0}." -f $process.ExitCode)}

    $deadline=(Get-Date).AddSeconds(15)
    $remaining=@()
    do {
        $remaining=@(Get-TrustedHklmInstalledMatches -Package $package)
        if($remaining.Count -eq 0){break}
        Start-Sleep -Milliseconds 500
    } while((Get-Date) -lt $deadline)
    $verified=($remaining.Count -eq 0)
    Write-BrokerLog ("TRUSTED_UNINSTALL_VERIFY id={0} verified={1} remaining={2}" -f $package.id,$verified,$remaining.Count)
    if(-not $verified){throw 'Registered uninstaller completed, but the trusted HKLM uninstall entry is still present.'}
    [pscustomobject]@{Confirmed=$true;Changed=$true;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';DisplayName=$entry.DisplayName;DisplayVersion=$entry.DisplayVersion;Publisher=$entry.Publisher}
}
function Confirm-PackageChange {
    param([ValidateSet('Install','Uninstall')][string]$Operation,[string]$Id,[string]$DisplayName='')
    $verb=if($Operation -eq 'Install'){'Установить программу?'}else{'Удалить программу?'}
    $cleanName=([string]$DisplayName -replace '[\x00-\x1F\x7F]',' ').Trim()
    if($cleanName.Length -gt 120){$cleanName=$cleanName.Substring(0,120)}
    $nameLine=if([string]::IsNullOrWhiteSpace($cleanName)){''}else{"`r`nНазвание: $cleanName"}
    $message="$verb$nameLine`r`nPackage ID: $Id`r`nИсточник: winget`r`n`r`nДействие будет выполнено с правами администратора."
    Write-BrokerLog ("PACKAGE_CONFIRM_DIALOG_SHOW operation={0} id={1}" -f $Operation,$Id)
    try {
        Initialize-BrokerMessageBox
        # MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST.
        # The broker itself is intentionally hidden, so consent is system-modal, foreground and topmost.
        $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
        $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swintus',$flags)
    } catch {
        Write-BrokerLog ("PACKAGE_CONFIRM_DIALOG_ERROR operation={0} id={1} error={2}" -f $Operation,$Id,$_.Exception.Message)
        throw ("Could not display confirmation dialog: {0}" -f $_.Exception.Message)
    }
    if($answer -eq 6){
        Write-BrokerLog ("PACKAGE_CONFIRM_USER_YES operation={0} id={1}" -f $Operation,$Id)
        return $true
    }
    Write-BrokerLog ("PACKAGE_CONFIRM_USER_NO operation={0} id={1} result={2}" -f $Operation,$Id,$answer)
    return $false
}

function Install-Package {
    param([string]$Id,[string]$DisplayName='')
    Assert-PackageId -Id $Id
    Write-BrokerLog ("PACKAGE_INSTALL_BEGIN id={0}" -f $Id)
    if(-not (Confirm-PackageChange -Operation Install -Id $Id -DisplayName $DisplayName)){
        Write-BrokerLog ("PACKAGE_INSTALL_DECLINED id={0}" -f $Id)
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Id=$Id;ExitCode=$null;Output='User declined installation.'}
    }
    Write-BrokerLog ("PACKAGE_WINGET_START operation=Install id={0}" -f $Id)
    $started=Get-Date
    try {
        $result=Invoke-Winget -Arguments @('install','--id',$Id,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -MaxOutput 50000
    } catch {
        Write-BrokerLog ("PACKAGE_WINGET_ERROR operation=Install id={0} elapsedMs={1} error={2}" -f $Id,[int]((Get-Date)-$started).TotalMilliseconds,$_.Exception.Message)
        throw
    }
    Write-BrokerLog ("PACKAGE_WINGET_EXIT operation=Install id={0} exitCode={1} elapsedMs={2}" -f $Id,$result.ExitCode,[int]((Get-Date)-$started).TotalMilliseconds)
    [pscustomobject]@{Confirmed=$true;Changed=($result.ExitCode -eq 0);Id=$Id;ExitCode=$result.ExitCode;Output=$result.Output}
}

function Uninstall-Package {
    param([string]$Id,[string]$DisplayName='')
    Assert-PackageId -Id $Id
    Write-BrokerLog ("PACKAGE_UNINSTALL_BEGIN id={0}" -f $Id)
    if(-not (Confirm-PackageChange -Operation Uninstall -Id $Id -DisplayName $DisplayName)){
        Write-BrokerLog ("PACKAGE_UNINSTALL_DECLINED id={0}" -f $Id)
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Id=$Id;ExitCode=$null;Output='User declined uninstall.'}
    }
    Write-BrokerLog ("PACKAGE_WINGET_START operation=Uninstall id={0}" -f $Id)
    $started=Get-Date
    try {
        $result=Invoke-Winget -Arguments @('uninstall','--id',$Id,'--exact','--silent','--accept-source-agreements','--disable-interactivity') -MaxOutput 50000
    } catch {
        Write-BrokerLog ("PACKAGE_WINGET_ERROR operation=Uninstall id={0} elapsedMs={1} error={2}" -f $Id,[int]((Get-Date)-$started).TotalMilliseconds,$_.Exception.Message)
        throw
    }
    Write-BrokerLog ("PACKAGE_WINGET_EXIT operation=Uninstall id={0} exitCode={1} elapsedMs={2}" -f $Id,$result.ExitCode,[int]((Get-Date)-$started).TotalMilliseconds)
    [pscustomobject]@{Confirmed=$true;Changed=($result.ExitCode -eq 0);Id=$Id;ExitCode=$result.ExitCode;Output=$result.Output}
}

function Invoke-BrokerAction {
    param([string]$Action,[hashtable]$Parameters)

    switch($Action){
        'GetWifiDetails' { return Get-WifiDetails }
        'GetNetworkExtended' { return Get-NetworkExtended }
        'GetProcessExtended' {
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 100)
            return Get-ProcessExtended -Top $top
        }
        'GetDriverInventory' {
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 300)
            return Get-DriverInventory -Top $top
        }
        'GetDeviceInventory' {
            $problems=[bool](Get-BrokerParameter -Parameters $Parameters -Name 'ProblemsOnly' -Default $false)
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 300)
            return Get-DeviceInventory -ProblemsOnly $problems -Top $top
        }
        'GetServiceExtended' {
            $needle=[string](Get-BrokerParameter -Parameters $Parameters -Name 'NameContains' -Default '')
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 300)
            return Get-ServiceExtended -NameContains $needle -Top $top
        }
        'GetStorageExtended' { return Get-StorageExtended }
        'GetStorageReliability' { return Get-StorageReliability }
        'GetEventLogElevated' {
            $log=[string](Get-BrokerParameter -Parameters $Parameters -Name 'LogName' -Default 'System')
            $hours=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Hours' -Default 24)
            $provider=[string](Get-BrokerParameter -Parameters $Parameters -Name 'ProviderContains' -Default '')
            $ids=[int[]](Get-BrokerParameter -Parameters $Parameters -Name 'Ids' -Default @())
            $max=[int](Get-BrokerParameter -Parameters $Parameters -Name 'MaxEvents' -Default 200)
            return Get-EventLogElevated -LogName $log -Hours $hours -ProviderContains $provider -Ids $ids -MaxEvents $max
        }
        'GetUpdateHistory' {
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 100)
            return Get-UpdateHistory -Top $top
        }
        'GetFirewallSecurityStatus' { return Get-FirewallSecurityStatus }
        'GetScheduledTaskSnapshot' {
            $needle=[string](Get-BrokerParameter -Parameters $Parameters -Name 'TaskNameContains' -Default '')
            $top=[int](Get-BrokerParameter -Parameters $Parameters -Name 'Top' -Default 300)
            return Get-ScheduledTaskSnapshot -TaskNameContains $needle -Top $top
        }
        'GetRegistryRead' {
            return Get-RegistryRead -Path ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Path' -Default '')) -Name ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Name' -Default ''))
        }
        'EnsureWinget' { return Ensure-Winget }
        'GetInstalledPackages' {
            $query=[string](Get-BrokerParameter -Parameters $Parameters -Name 'Query' -Default '')
            return Get-InstalledPackages -Query $query
        }
        'SearchPackage' { return Search-Package -Query ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Query' -Default '')) }
        'SearchTrustedPackages' { return Search-TrustedPackages -Query ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Query' -Default '')) }
        'InstallTrustedPackage' { return Install-TrustedPackageCatalog -Id ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Id' -Default '')) }
        'UninstallTrustedPackage' { return Uninstall-TrustedPackage -Id ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Id' -Default '')) }
        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Id' -Default '')) }
        'InstallPackage' {
            $name=[string](Get-BrokerParameter -Parameters $Parameters -Name 'DisplayName' -Default '')
            return Install-Package -Id ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Id' -Default '')) -DisplayName $name
        }
        'UninstallPackage' {
            $name=[string](Get-BrokerParameter -Parameters $Parameters -Name 'DisplayName' -Default '')
            return Uninstall-Package -Id ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Id' -Default '')) -DisplayName $name
        }
        'RemoveRegistryValue' {
            $notify=[bool](Get-BrokerParameter -Parameters $Parameters -Name 'NotifyShell' -Default $true)
            return Remove-RegistryValueConfirmed `
                -Path ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Path' -Default '')) `
                -Name ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Name' -Default '')) `
                -NotifyShell $notify
        }
        'SetRegistryValue' {
            $type=[string](Get-BrokerParameter -Parameters $Parameters -Name 'Type' -Default 'String')
            $notify=[bool](Get-BrokerParameter -Parameters $Parameters -Name 'NotifyShell' -Default $true)
            return Set-RegistryValueConfirmed `
                -Path ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Path' -Default '')) `
                -Name ([string](Get-BrokerParameter -Parameters $Parameters -Name 'Name' -Default '')) `
                -Value (Get-BrokerParameter -Parameters $Parameters -Name 'Value' -Default $null) `
                -Type $type -NotifyShell $notify
        }
        default { throw ("Action is not allowed by the Dr.Swintus privileged broker: {0}" -f $Action) }
    }
}

$ready=[pscustomobject]@{
    Ready=$true
    Elevated=$true
    PID=$PID
    Started=(Get-Date)
    Actions=@(
        'GetWifiDetails','GetNetworkExtended','GetProcessExtended','GetDriverInventory',
        'GetDeviceInventory','GetServiceExtended','GetStorageExtended','GetStorageReliability',
        'GetEventLogElevated','GetUpdateHistory','GetFirewallSecurityStatus',
        'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget','GetInstalledPackages','SearchPackage',
        'SearchTrustedPackages','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'
    )
}
$ready | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $readyPath -Encoding UTF8
Write-BrokerLog ("READY pid={0}" -f $PID)
Write-Host 'Dr.Swintus privileged broker is running.'
Write-Host 'Administrative diagnostics, confirmed package management, and confirmed registry value changes/removals are enabled for this session.'

$idleDeadline=(Get-Date).AddMinutes(60)
while((Get-Date) -lt $idleDeadline){
    if(Test-Path -LiteralPath $stopPath){break}

    $requests=@(Get-ChildItem -LiteralPath $requestDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    if($requests.Count -eq 0){
        Start-Sleep -Milliseconds 250
        continue
    }

    foreach($file in $requests){
        $responsePath=Join-Path $responseDir $file.Name
        $action=''
        try {
            $req=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $action=[string]$req.Action
            $params=@{}
            if($req.Parameters){
                foreach($pr in $req.Parameters.PSObject.Properties){$params[$pr.Name]=$pr.Value}
            }

            Write-BrokerLog ("REQUEST {0} {1}" -f $file.Name,$action)
            $data=Invoke-BrokerAction -Action $action -Parameters $params
            $response=[pscustomobject]@{
                Ok=$true;Action=$action;Data=$data;Error=$null;Timestamp=(Get-Date)
            }
            Write-BrokerLog ("SUCCESS {0} {1}" -f $file.Name,$action)
        } catch {
            $response=[pscustomobject]@{
                Ok=$false;Action=if($action){$action}else{''};Data=$null;
                Error=$_.Exception.Message;Timestamp=(Get-Date)
            }
            Write-BrokerLog ("ERROR {0}: {1}" -f $file.Name,$_.Exception.Message)
        }

        $tmp=$responsePath+'.tmp'
        $response | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $responsePath -Force
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-BrokerLog 'STOP'
try {Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue} catch {}
