function New-BrokerResult {
    param(
        [bool]$Allowed,
        [string]$Action,
        [int]$ExitCode = 0,
        $Data = $null,
        [string]$ErrorText = "",
        [string]$Verification = ""
    )

    [pscustomobject]@{
        Allowed = $Allowed
        Action = $Action
        ExitCode = $ExitCode
        Data = $Data
        Error = $ErrorText
        Verification = $Verification
        Timestamp = (Get-Date)
    }
}


function Get-VolumeUsageBroker {
    $result = @()
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")) {
        $size=[double]$v.Size
        $free=[double]$v.FreeSpace
        $used=$size-$free
        $result += [pscustomobject]@{
            DeviceID=$v.DeviceID
            VolumeName=$v.VolumeName
            FileSystem=$v.FileSystem
            SizeGB=[math]::Round($size/1GB,2)
            UsedGB=[math]::Round($used/1GB,2)
            FreeGB=[math]::Round($free/1GB,2)
            FreePercent=if($size -gt 0){[math]::Round(($free/$size)*100,1)}else{$null}
        }
    }
    return $result
}

function Get-LargestDirectoriesBroker {
    param([string]$Path='C:\',[int]$Depth=2,[int]$Top=25)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
    if ($Depth -lt 1) { $Depth=1 }
    if ($Depth -gt 2) { $Depth=2 }
    if ($Top -lt 1) { $Top=1 }
    if ($Top -gt 100) { $Top=100 }

    $base=(Resolve-Path -LiteralPath $Path).Path
    $work=New-Object System.Collections.Generic.List[object]
    $first=@(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)
    foreach($d in $first){$work.Add($d)|Out-Null}

    if($Depth -ge 2){
        foreach($d in $first){
            foreach($c in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue)){
                $work.Add($c)|Out-Null
            }
        }
    }

    $rows=foreach($d in $work){
        try{
            $m=Get-ChildItem -LiteralPath $d.FullName -File -Force -Recurse -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            [pscustomobject]@{
                Path=$d.FullName
                SizeGB=[math]::Round(([double]$m.Sum)/1GB,3)
                FileCount=[int]$m.Count
            }
        }catch{
            [pscustomobject]@{
                Path=$d.FullName
                SizeGB=$null
                FileCount=$null
                Error=$_.Exception.Message
            }
        }
    }

    return @($rows | Sort-Object SizeGB -Descending | Select-Object -First $Top)
}

function Get-LargestFilesBroker {
    param([string]$Path='C:\',[int]$Top=40,[int]$MinSizeMB=100)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
    if ($Top -lt 1) { $Top=1 }
    if ($Top -gt 200) { $Top=200 }
    if ($MinSizeMB -lt 1) { $MinSizeMB=1 }

    $min=[int64]$MinSizeMB*1MB
    return @(
        Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $min } |
        Sort-Object Length -Descending |
        Select-Object -First $Top `
            @{n='Path';e={$_.FullName}},
            @{n='SizeGB';e={[math]::Round($_.Length/1GB,3)}},
            @{n='LastWriteTime';e={$_.LastWriteTime}}
    )
}

function Get-DirectorySizeSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $m=Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
        return [int64]$m.Sum
    } catch { return 0 }
}

function Get-CommonSpaceConsumersBroker {
    param([string]$Drive='C:')

    $root="$Drive\"
    $windows=Join-Path $root 'Windows'
    $paths=[ordered]@{
        WindowsTemp=(Join-Path $windows 'Temp')
        WindowsLogs=(Join-Path $windows 'Logs')
        SoftwareDistributionDownload=(Join-Path $windows 'SoftwareDistribution\Download')
        Minidump=(Join-Path $windows 'Minidump')
        Users=(Join-Path $root 'Users')
        ProgramData=(Join-Path $root 'ProgramData')
    }

    $out=[ordered]@{}
    foreach($k in $paths.Keys){
        $p=[string]$paths[$k]
        $sz=Get-DirectorySizeSafe -Path $p
        $out[$k]=[pscustomobject]@{Path=$p;SizeGB=[math]::Round($sz/1GB,3)}
    }

    foreach($leaf in @('MEMORY.DMP','hiberfil.sys','pagefile.sys')){
        $p=if($leaf -eq 'MEMORY.DMP'){Join-Path $windows $leaf}else{Join-Path $root $leaf}
        if(Test-Path -LiteralPath $p){
            try{
                $i=Get-Item -LiteralPath $p -Force
                $out[$leaf]=[pscustomobject]@{Path=$p;SizeGB=[math]::Round($i.Length/1GB,3)}
            }catch{}
        }
    }

    return [pscustomobject]$out
}



function Get-SystemSnapshotBroker {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
        Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)

    return [pscustomobject]@{
        ComputerName=$env:COMPUTERNAME
        Manufacturer=$cs.Manufacturer
        Model=$cs.Model
        TotalMemoryGB=if($cs.TotalPhysicalMemory){[math]::Round(([double]$cs.TotalPhysicalMemory)/1GB,2)}else{$null}
        OS=$os.Caption
        OSVersion=$os.Version
        BuildNumber=$os.BuildNumber
        LastBootUpTime=$os.LastBootUpTime
        FreePhysicalMemoryMB=if($os.FreePhysicalMemory){[math]::Round(([double]$os.FreePhysicalMemory)/1KB,0)}else{$null}
        BIOSVersion=($bios.SMBIOSBIOSVersion -join ',')
        CPU=$cpu
    }
}

function Get-ProcessSnapshotBroker {
    param([int]$Top=30,[string]$SortBy='WorkingSet')

    if($Top -lt 1){$Top=1}
    if($Top -gt 100){$Top=100}
    if($SortBy -notin @('WorkingSet','CPU')){$SortBy='WorkingSet'}

    $rows=@(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $procPath=$null
        $procStart=$null
        try { $procPath=$_.Path } catch {}
        try { $procStart=$_.StartTime } catch {}

        [pscustomobject]@{
            Name=$_.ProcessName
            Id=$_.Id
            CPUSeconds=if($_.CPU -ne $null){[math]::Round([double]$_.CPU,2)}else{$null}
            WorkingSetMB=[math]::Round(([double]$_.WorkingSet64)/1MB,1)
            PrivateMemoryMB=[math]::Round(([double]$_.PrivateMemorySize64)/1MB,1)
            Path=$procPath
            StartTime=$procStart
        }
    })

    if($SortBy -eq 'CPU'){
        return @($rows | Sort-Object CPUSeconds -Descending | Select-Object -First $Top)
    }
    return @($rows | Sort-Object WorkingSetMB -Descending | Select-Object -First $Top)
}

function Get-ServiceSnapshotBroker {
    param([string]$NameContains='',[int]$Top=100)

    if($Top -lt 1){$Top=1}
    if($Top -gt 200){$Top=200}
    $rows=@(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Select-Object Name,DisplayName,State,StartMode,ProcessId,ExitCode,PathName,StartName)

    if(-not [string]::IsNullOrWhiteSpace($NameContains)){
        $needle=$NameContains.ToLowerInvariant()
        $rows=@($rows | Where-Object {
            ([string]$_.Name).ToLowerInvariant().Contains($needle) -or
            ([string]$_.DisplayName).ToLowerInvariant().Contains($needle)
        })
    }
    return @($rows | Select-Object -First $Top)
}

function Get-PnPProblemsBroker {
    param([int]$Top=100)

    if($Top -lt 1){$Top=1}
    if($Top -gt 200){$Top=200}

    return @(
        Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object -First $Top Name,PNPDeviceID,Manufacturer,Service,Status,ConfigManagerErrorCode,ClassGuid
    )
}

function Get-NetworkSnapshotBroker {
    $adapters=@()
    try {
        $adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue |
            Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress,DriverInformation,DriverVersion)
    } catch {}

    $ip=@()
    try {
        $ip=@(Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                InterfaceAlias=$_.InterfaceAlias
                InterfaceDescription=$_.InterfaceDescription
                IPv4Address=(@($_.IPv4Address | ForEach-Object {$_.IPAddress}) -join ',')
                IPv4DefaultGateway=(@($_.IPv4DefaultGateway | ForEach-Object {$_.NextHop}) -join ',')
                DNSServer=(@($_.DNSServer.ServerAddresses) -join ',')
            }
        })
    } catch {}

    return [pscustomobject]@{Adapters=$adapters;IPConfiguration=$ip}
}

function Get-EventLogSliceBroker {
    param(
        [string]$LogName='System',
        [int]$Days=3,
        [string]$ProviderContains='',
        [int[]]$Ids=@(),
        [int]$MaxEvents=100
    )

    if($LogName -notin @('System','Application')){
        throw 'Only System and Application logs are allowed.'
    }
    if($Days -lt 1){$Days=1}
    if($Days -gt 30){$Days=30}
    if($MaxEvents -lt 1){$MaxEvents=1}
    if($MaxEvents -gt 200){$MaxEvents=200}
    if(@($Ids).Count -gt 12){throw 'At most 12 event IDs are allowed.'}

    $start=(Get-Date).AddDays(-$Days)
    $events=@(Get-WinEvent -FilterHashtable @{LogName=$LogName;StartTime=$start} -ErrorAction SilentlyContinue)

    if(-not [string]::IsNullOrWhiteSpace($ProviderContains)){
        $needle=$ProviderContains.ToLowerInvariant()
        $events=@($events | Where-Object {
            ([string]$_.ProviderName).ToLowerInvariant().Contains($needle)
        })
    }
    if(@($Ids).Count -gt 0){
        $events=@($events | Where-Object { @($Ids) -contains [int]$_.Id })
    }

    return @($events |
        Sort-Object TimeCreated -Descending |
        Select-Object -First $MaxEvents TimeCreated,ProviderName,Id,LevelDisplayName,LogName,
            @{N='Message';E={
                $m=[string]$_.Message
                if($m.Length -gt 1200){$m.Substring(0,1200)}else{$m}
            }})
}

function Get-PathSummaryBroker {
    param([string]$Path,[int]$Top=40)

    if([string]::IsNullOrWhiteSpace($Path)){throw 'Path is required.'}
    if(-not (Test-Path -LiteralPath $Path)){throw "Path not found: $Path"}
    if($Top -lt 1){$Top=1}
    if($Top -gt 100){$Top=100}

    $resolved=(Resolve-Path -LiteralPath $Path).Path
    $item=Get-Item -LiteralPath $resolved -Force -ErrorAction Stop

    if(-not $item.PSIsContainer){
        return [pscustomobject]@{
            Path=$item.FullName
            Type='File'
            SizeMB=[math]::Round(([double]$item.Length)/1MB,2)
            LastWriteTime=$item.LastWriteTime
            Attributes=[string]$item.Attributes
        }
    }

    $children=@(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue)
    $rows=@()

    foreach($c in $children){
        if($c.PSIsContainer){
            try{
                $m=Get-ChildItem -LiteralPath $c.FullName -File -Force -Recurse -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum
                $rows += [pscustomobject]@{
                    Name=$c.Name
                    Path=$c.FullName
                    Type='Directory'
                    SizeMB=[math]::Round(([double]$m.Sum)/1MB,2)
                    ItemCount=[int]$m.Count
                    LastWriteTime=$c.LastWriteTime
                }
            } catch {}
        } else {
            $rows += [pscustomobject]@{
                Name=$c.Name
                Path=$c.FullName
                Type='File'
                SizeMB=[math]::Round(([double]$c.Length)/1MB,2)
                ItemCount=1
                LastWriteTime=$c.LastWriteTime
            }
        }
    }

    return [pscustomobject]@{
        Path=$resolved
        Type='Directory'
        Children=@($rows | Sort-Object SizeMB -Descending | Select-Object -First $Top)
    }
}

function Get-FileMetadataBroker {
    param([string]$Path)

    if([string]::IsNullOrWhiteSpace($Path)){throw 'Path is required.'}
    if(-not (Test-Path -LiteralPath $Path)){throw "Path not found: $Path"}
    $i=Get-Item -LiteralPath $Path -Force -ErrorAction Stop

    return [pscustomobject]@{
        Path=$i.FullName
        Name=$i.Name
        IsDirectory=[bool]$i.PSIsContainer
        LengthMB=if(-not $i.PSIsContainer){[math]::Round(([double]$i.Length)/1MB,3)}else{$null}
        CreationTime=$i.CreationTime
        LastWriteTime=$i.LastWriteTime
        LastAccessTime=$i.LastAccessTime
        Attributes=[string]$i.Attributes
        VersionInfo=if(-not $i.PSIsContainer){try{$i.VersionInfo | Select-Object FileVersion,ProductVersion,CompanyName,ProductName}catch{$null}}else{$null}
    }
}


function Invoke-DiagnosticBroker {
    param(
        [Parameter(Mandatory=$true)][string]$Action,
        [hashtable]$Parameters = @{}
    )

    # v2-dev broker is intentionally allowlist-only.
    # No arbitrary shell command or script text is accepted.
    $allowed = @(
        'GetSystemSnapshot',
        'GetProcessSnapshot',
        'GetServiceSnapshot',
        'GetPnPProblems',
        'GetNetworkSnapshot',
        'GetEventLogSlice',
        'GetPathSummary',
        'GetFileMetadata',
        'GetDiskIdentity',
        'GetStorageReliability',
        'GetWifiDriver',
        'GetWifiAdapterState',
        'GetVirtualBoxNetworkState',
        'GetUnexpectedShutdownContext',
        'GetCrashContext',
        'GetServiceState',
        'GetUpdateFailureContext',
        'GetSecureBootContext',
        'StartServiceSafe',
        'VerifyServiceRunning',
        'GetServiceFailureContext',
        'GetPnPProblemContext',
        'GetPnPRelatedDriverContext',
        'GetPowerEventTimeline',
        'GetDiskEventContext',
        'GetWifiErrorTimeline',
        'GetServiceConfigurationContext',
        'GetVolumeUsage',
        'GetLargestDirectories',
        'GetLargestFiles',
        'GetCommonSpaceConsumers',
        'GetEventCorrelationWindow'
    )

    if ($allowed -notcontains $Action) {
        return New-BrokerResult -Allowed $false -Action $Action -ExitCode 126 `
            -ErrorText "Action is not on the v2-dev broker allowlist." `
            -Verification "Denied before execution."
    }

    try {
        switch ($Action) {


            'GetSystemSnapshot' {
                $data=Get-SystemSnapshotBroker
                return New-BrokerResult $true $Action 0 $data "" "Read-only system snapshot completed."
            }

            'GetProcessSnapshot' {
                $top=if($Parameters.Top){[int]$Parameters.Top}else{30}
                $sort=if($Parameters.SortBy){[string]$Parameters.SortBy}else{'WorkingSet'}
                $data=Get-ProcessSnapshotBroker -Top $top -SortBy $sort
                return New-BrokerResult $true $Action 0 $data "" "Read-only process snapshot completed."
            }

            'GetServiceSnapshot' {
                $needle=if($Parameters.NameContains){[string]$Parameters.NameContains}else{''}
                $top=if($Parameters.Top){[int]$Parameters.Top}else{100}
                $data=Get-ServiceSnapshotBroker -NameContains $needle -Top $top
                return New-BrokerResult $true $Action 0 $data "" "Read-only service snapshot completed."
            }

            'GetPnPProblems' {
                $top=if($Parameters.Top){[int]$Parameters.Top}else{100}
                $data=Get-PnPProblemsBroker -Top $top
                return New-BrokerResult $true $Action 0 $data "" "Read-only PnP problem query completed."
            }

            'GetNetworkSnapshot' {
                $data=Get-NetworkSnapshotBroker
                return New-BrokerResult $true $Action 0 $data "" "Read-only network snapshot completed."
            }

            'GetEventLogSlice' {
                $log=if($Parameters.LogName){[string]$Parameters.LogName}else{'System'}
                $days=if($Parameters.Days){[int]$Parameters.Days}else{3}
                $provider=if($Parameters.ProviderContains){[string]$Parameters.ProviderContains}else{''}
                $ids=if($Parameters.Ids){[int[]]$Parameters.Ids}else{@()}
                $max=if($Parameters.MaxEvents){[int]$Parameters.MaxEvents}else{100}
                $data=Get-EventLogSliceBroker -LogName $log -Days $days -ProviderContains $provider -Ids $ids -MaxEvents $max
                return New-BrokerResult $true $Action 0 $data "" "Read-only event-log query completed."
            }

            'GetPathSummary' {
                $path=[string]$Parameters.Path
                $top=if($Parameters.Top){[int]$Parameters.Top}else{40}
                $data=Get-PathSummaryBroker -Path $path -Top $top
                return New-BrokerResult $true $Action 0 $data "" "Read-only path summary completed."
            }

            'GetFileMetadata' {
                $path=[string]$Parameters.Path
                $data=Get-FileMetadataBroker -Path $path
                return New-BrokerResult $true $Action 0 $data "" "Read-only file metadata query completed."
            }

            'GetVolumeUsage' {
                $data=Get-VolumeUsageBroker
                return New-BrokerResult $true $Action 0 $data "" "Read-only volume usage query completed."
            }

            'GetLargestDirectories' {
                $path=if($Parameters.Path){[string]$Parameters.Path}else{'C:\'}
                $depth=if($Parameters.Depth){[int]$Parameters.Depth}else{2}
                $top=if($Parameters.Top){[int]$Parameters.Top}else{25}
                $data=Get-LargestDirectoriesBroker -Path $path -Depth $depth -Top $top
                return New-BrokerResult $true $Action 0 $data "" "Read-only directory size scan completed."
            }

            'GetLargestFiles' {
                $path=if($Parameters.Path){[string]$Parameters.Path}else{'C:\'}
                $top=if($Parameters.Top){[int]$Parameters.Top}else{40}
                $min=if($Parameters.MinSizeMB){[int]$Parameters.MinSizeMB}else{100}
                $data=Get-LargestFilesBroker -Path $path -Top $top -MinSizeMB $min
                return New-BrokerResult $true $Action 0 $data "" "Read-only large-file scan completed."
            }

            'GetCommonSpaceConsumers' {
                $drive=if($Parameters.Drive){[string]$Parameters.Drive}else{'C:'}
                if($drive -notmatch '^[A-Za-z]:$'){
                    return New-BrokerResult $false $Action 2 $null "Drive must be a local drive letter like C:." "No execution."
                }
                $data=Get-CommonSpaceConsumersBroker -Drive $drive
                return New-BrokerResult $true $Action 0 $data "" "Read-only common space-consumer query completed."
            }

            'GetDiskIdentity' {
                $data = @(Get-Disk -ErrorAction Stop |
                    Select-Object Number,FriendlyName,SerialNumber,BusType,PartitionStyle,
                        HealthStatus,OperationalStatus,IsBoot,IsSystem,IsOffline,
                        @{N='Size_GB';E={[math]::Round($_.Size/1GB,2)}})

                return New-BrokerResult $true $Action 0 $data "" "Read-only Get-Disk completed."
            }

            'GetStorageReliability' {
                $out = @()
                $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)

                foreach ($pd in $physical) {
                    $counter = $null
                    try {
                        $counter = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                    } catch {}

                    $out += [pscustomobject]@{
                        FriendlyName = $pd.FriendlyName
                        SerialNumber = $pd.SerialNumber
                        HealthStatus = $pd.HealthStatus
                        OperationalStatus = ($pd.OperationalStatus -join ',')
                        Temperature = if ($counter) { $counter.Temperature } else { $null }
                        Wear = if ($counter) { $counter.Wear } else { $null }
                        ReadErrorsTotal = if ($counter) { $counter.ReadErrorsTotal } else { $null }
                        WriteErrorsTotal = if ($counter) { $counter.WriteErrorsTotal } else { $null }
                        PowerOnHours = if ($counter) { $counter.PowerOnHours } else { $null }
                    }
                }

                return New-BrokerResult $true $Action 0 $out "" "Read-only storage reliability query completed."
            }

            'GetWifiDriver' {
                $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
                    Where-Object {
                        $_.DeviceName -match 'Intel.*Wi-Fi|AX201|Wireless'
                    } |
                    Select-Object DeviceName,DriverVersion,DriverDate,Manufacturer,InfName,IsSigned)

                return New-BrokerResult $true $Action 0 $drivers "" "Read-only Wi-Fi driver query completed."
            }

            'GetWifiAdapterState' {
                $adapters = @(Get-NetAdapter -ErrorAction Stop |
                    Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|AX201' } |
                    Select-Object Name,InterfaceDescription,Status,LinkSpeed,MediaConnectionState,
                        DriverInformation,DriverFileName,DriverVersion)

                return New-BrokerResult $true $Action 0 $adapters "" "Read-only adapter state query completed."
            }

            'GetVirtualBoxNetworkState' {
                $drivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'VBox|VirtualBox' -or $_.DisplayName -match 'VirtualBox' } |
                    Select-Object Name,DisplayName,State,StartMode,PathName)

                $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceDescription -match 'VirtualBox' } |
                    Select-Object Name,InterfaceDescription,Status,LinkSpeed,DriverInformation,DriverVersion)

                $data = [pscustomobject]@{
                    Drivers = $drivers
                    Adapters = $adapters
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only VirtualBox network query completed."
            }

            'GetUnexpectedShutdownContext' {
                $since = (Get-Date).AddDays(-7)

                $bugcheck = @(Get-WinEvent -FilterHashtable @{
                    LogName='System'
                    StartTime=$since
                    Id=1001
                } -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProviderName -match 'BugCheck|WER-SystemErrorReporting' } |
                    Select-Object TimeCreated,ProviderName,Id,Message)

                $whea = @(Get-WinEvent -FilterHashtable @{
                    LogName='System'
                    StartTime=$since
                } -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and
                        $_.LevelDisplayName -in @('Critical','Error','Warning')
                    } |
                    Select-Object -First 30 TimeCreated,ProviderName,Id,LevelDisplayName,Message)

                $dumps = @()
                $dumpDir = Join-Path $env:SystemRoot 'Minidump'
                if (Test-Path $dumpDir) {
                    $dumps = @(Get-ChildItem $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 10 Name,Length,LastWriteTime,FullName)
                }

                $data = [pscustomobject]@{
                    BugCheckEvents = $bugcheck
                    WHEAEvents = $whea
                    Minidumps = $dumps
                }

                return New-BrokerResult $true $Action 0 $data "" "Crash/power context queried without opening dump contents."
            }

            'GetCrashContext' {
                $processName = [string]$Parameters.ProcessName
                if ([string]::IsNullOrWhiteSpace($processName)) {
                    return New-BrokerResult $false $Action 2 $null "ProcessName is required." "No execution."
                }

                $base = [System.IO.Path]::GetFileNameWithoutExtension($processName)
                $procs = @(Get-Process -Name $base -ErrorAction SilentlyContinue |
                    Select-Object ProcessName,Id,Path,StartTime,
                        @{N='FileVersion';E={try {$_.MainModule.FileVersionInfo.FileVersion} catch {$null}}})

                $events = @(Get-WinEvent -FilterHashtable @{
                    LogName='Application'
                    StartTime=(Get-Date).AddDays(-7)
                    Id=1000
                } -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.ProviderName -eq 'Application Error' -and
                        $_.Message -match [regex]::Escape($processName)
                    } |
                    Select-Object -First 10 TimeCreated,ProviderName,Id,Message)

                $data = [pscustomobject]@{
                    ProcessName = $processName
                    Running = $procs
                    RecentCrashes = $events
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only crash context query completed."
            }

            'GetServiceState' {
                $name = [string]$Parameters.Name
                if ([string]::IsNullOrWhiteSpace($name)) {
                    return New-BrokerResult $false $Action 2 $null "Name is required." "No execution."
                }

                $svc = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'","''")) -ErrorAction SilentlyContinue |
                    Select-Object Name,DisplayName,State,StartMode,ExitCode,ProcessId,PathName,StartName)

                return New-BrokerResult $true $Action 0 $svc "" "Read-only service query completed."
            }

            'GetUpdateFailureContext' {
                $events = @(Get-WinEvent -FilterHashtable @{
                    LogName='System'
                    ProviderName='Microsoft-Windows-WindowsUpdateClient'
                    StartTime=(Get-Date).AddDays(-7)
                    Id=20
                } -ErrorAction SilentlyContinue |
                    Select-Object -First 30 TimeCreated,Id,Message)

                return New-BrokerResult $true $Action 0 $events "" "Read-only Windows Update failure query completed."
            }

            'GetSecureBootContext' {
                $bios = @(Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue |
                    Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate,SerialNumber)

                $secureBoot = $null
                try {
                    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
                } catch {
                    $secureBoot = "Unavailable: $($_.Exception.Message)"
                }

                $data = [pscustomobject]@{
                    BIOS = $bios
                    SecureBootEnabled = $secureBoot
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only firmware/Secure Boot state query completed."
            }




            'GetPnPProblemContext' {
                $instanceId = [string]$Parameters.InstanceId
                if ([string]::IsNullOrWhiteSpace($instanceId)) {
                    return New-BrokerResult $false $Action 2 $null "InstanceId is required." "No execution."
                }

                $device = $null
                try { $device = Get-PnpDevice -InstanceId $instanceId -ErrorAction Stop } catch {}

                $properties = @()
                try {
                    $properties = @(Get-PnpDeviceProperty -InstanceId $instanceId -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.KeyName -in @(
                                'DEVPKEY_Device_HardwareIds',
                                'DEVPKEY_Device_CompatibleIds',
                                'DEVPKEY_Device_Class',
                                'DEVPKEY_Device_ClassGuid',
                                'DEVPKEY_Device_Manufacturer',
                                'DEVPKEY_Device_FriendlyName',
                                'DEVPKEY_Device_DeviceDesc',
                                'DEVPKEY_Device_Parent',
                                'DEVPKEY_Device_ProblemCode',
                                'DEVPKEY_Device_Service',
                                'DEVPKEY_Device_DriverInfPath',
                                'DEVPKEY_Device_DriverVersion',
                                'DEVPKEY_Device_DriverDate',
                                'DEVPKEY_Device_DriverProvider'
                            )
                        } | Select-Object KeyName,Type,Data)
                } catch {}

                function Read-PnpProp([string]$key) {
                    $p = @($properties | Where-Object { $_.KeyName -eq $key } | Select-Object -First 1)
                    if ($p.Count -gt 0) { return $p[0].Data }
                    return $null
                }

                $hardwareIds = @(Read-PnpProp 'DEVPKEY_Device_HardwareIds')
                $compatibleIds = @(Read-PnpProp 'DEVPKEY_Device_CompatibleIds')
                $parentId = [string](Read-PnpProp 'DEVPKEY_Device_Parent')

                $parent = $null
                if (-not [string]::IsNullOrWhiteSpace($parentId)) {
                    try {
                        $parent = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue |
                            Select-Object Status,Class,FriendlyName,InstanceId,Problem,ConfigManagerErrorCode
                    } catch {}
                }

                $data = [pscustomobject]@{
                    InstanceId = $instanceId
                    Device = if ($device) {
                        [pscustomobject]@{
                            Status = $device.Status
                            Class = $device.Class
                            FriendlyName = $device.FriendlyName
                            InstanceId = $device.InstanceId
                            Problem = $device.Problem
                            ConfigManagerErrorCode = $device.ConfigManagerErrorCode
                        }
                    } else { $null }
                    HardwareIds = $hardwareIds
                    CompatibleIds = $compatibleIds
                    Class = [string](Read-PnpProp 'DEVPKEY_Device_Class')
                    ClassGuid = [string](Read-PnpProp 'DEVPKEY_Device_ClassGuid')
                    Manufacturer = [string](Read-PnpProp 'DEVPKEY_Device_Manufacturer')
                    Service = [string](Read-PnpProp 'DEVPKEY_Device_Service')
                    DriverInfPath = [string](Read-PnpProp 'DEVPKEY_Device_DriverInfPath')
                    DriverVersion = [string](Read-PnpProp 'DEVPKEY_Device_DriverVersion')
                    DriverDate = Read-PnpProp 'DEVPKEY_Device_DriverDate'
                    DriverProvider = [string](Read-PnpProp 'DEVPKEY_Device_DriverProvider')
                    ParentInstanceId = $parentId
                    Parent = $parent
                    RawProperties = $properties
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only PnP problem context query completed."
            }

            'GetPnPRelatedDriverContext' {
                $instanceId = [string]$Parameters.InstanceId
                if ([string]::IsNullOrWhiteSpace($instanceId)) {
                    return New-BrokerResult $false $Action 2 $null "InstanceId is required." "No execution."
                }

                $hardwareIds = @()
                try {
                    $p = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue
                    if ($p) { $hardwareIds = @($p.Data) }
                } catch {}

                $signed = @()
                try {
                    $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                        Select-Object DeviceName,DeviceID,DriverVersion,DriverDate,Manufacturer,DriverProviderName,InfName,IsSigned,Signer)
                } catch {}

                $related = @()
                foreach ($d in $signed) {
                    $did = [string]$d.DeviceID
                    foreach ($h in $hardwareIds) {
                        $hs = [string]$h
                        if (-not [string]::IsNullOrWhiteSpace($hs)) {
                            $prefix = ($hs -split '&')[0]
                            if ($prefix -and $did -like ("*" + $prefix + "*")) {
                                $related += $d
                                break
                            }
                        }
                    }
                }

                $data = [pscustomobject]@{
                    InstanceId = $instanceId
                    HardwareIds = $hardwareIds
                    RelatedSignedDrivers = @($related | Sort-Object DeviceName,DriverVersion -Unique)
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only related-driver context query completed."
            }


            'GetPowerEventTimeline' {
                $since = (Get-Date).AddDays(-14)
                $events = @()
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction SilentlyContinue |
                        Where-Object {
                            ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -in 41,42,107,109,131) -or
                            ($_.ProviderName -eq 'EventLog' -and $_.Id -in 6005,6006,6008) -or
                            ($_.ProviderName -eq 'USER32' -and $_.Id -eq 1074) -or
                            ($_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1) -or
                            ($_.ProviderName -like '*WHEA*')
                        } |
                        Sort-Object TimeCreated -Descending |
                        Select-Object -First 80 TimeCreated,ProviderName,Id,LevelDisplayName,Message)
                } catch {}

                return New-BrokerResult $true $Action 0 $events "" "Read-only power/shutdown timeline query completed."
            }

            'GetDiskEventContext' {
                $since = (Get-Date).AddDays(-30)
                $events = @()
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction SilentlyContinue |
                        Where-Object {
                            ($_.ProviderName -in @('Disk','Ntfs','stornvme','storahci','volmgr','Microsoft-Windows-StorPort')) -and
                            ($_.Level -le 3)
                        } |
                        Sort-Object TimeCreated -Descending |
                        Select-Object -First 100 TimeCreated,ProviderName,Id,LevelDisplayName,Message)
                } catch {}

                $disks = @()
                try {
                    $disks = @(Get-Disk -ErrorAction SilentlyContinue |
                        Select-Object Number,FriendlyName,SerialNumber,BusType,HealthStatus,OperationalStatus,IsBoot,IsSystem,Size)
                } catch {}

                $physical = @()
                try {
                    $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
                        $pd = $_
                        $rel = $null
                        try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue } catch {}
                        [pscustomobject]@{
                            FriendlyName=$pd.FriendlyName
                            SerialNumber=$pd.SerialNumber
                            HealthStatus=$pd.HealthStatus
                            OperationalStatus=$pd.OperationalStatus
                            MediaType=$pd.MediaType
                            Temperature=if($rel){$rel.Temperature}else{$null}
                            Wear=if($rel){$rel.Wear}else{$null}
                            ReadErrorsTotal=if($rel){$rel.ReadErrorsTotal}else{$null}
                            WriteErrorsTotal=if($rel){$rel.WriteErrorsTotal}else{$null}
                        }
                    })
                } catch {}

                $data = [pscustomobject]@{
                    Events=$events
                    CurrentDisks=$disks
                    Reliability=$physical
                    MappingWarning='Historical HarddiskN identifiers are not assumed to map to current disk numbers.'
                }
                return New-BrokerResult $true $Action 0 $data "" "Read-only storage event correlation query completed."
            }

            'GetWifiErrorTimeline' {
                $since = (Get-Date).AddDays(-14)
                $events = @()
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.ProviderName -match 'Netwtw|WLAN|NDIS' -and $_.Level -le 3
                        } |
                        Sort-Object TimeCreated -Descending |
                        Select-Object -First 100 TimeCreated,ProviderName,Id,LevelDisplayName,Message)
                } catch {}

                $adapters = @()
                try {
                    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                        Where-Object { $_.InterfaceDescription -match 'Intel.*Wi-Fi|Wireless|AX201' } |
                        Select-Object Name,InterfaceDescription,Status,LinkSpeed,MediaConnectionState,DriverInformation,DriverFileName,DriverVersion)
                } catch {}

                $data = [pscustomobject]@{
                    Events=$events
                    CurrentAdapters=$adapters
                }
                return New-BrokerResult $true $Action 0 $data "" "Read-only Wi-Fi error timeline query completed."
            }

            'GetServiceConfigurationContext' {
                $name = [string]$Parameters.Name
                if ([string]::IsNullOrWhiteSpace($name)) {
                    return New-BrokerResult $false $Action 2 $null "Name is required." "No execution."
                }

                $escaped = $name.Replace("'","''")
                $svc = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $escaped) -ErrorAction SilentlyContinue |
                    Select-Object Name,DisplayName,State,StartMode,ExitCode,ProcessId,PathName,StartName,ServiceType)

                $deps = @()
                $dependents = @()
                try {
                    $sc = Get-Service -Name $name -ErrorAction Stop
                    $deps = @($sc.ServicesDependedOn | Select-Object Name,DisplayName,Status)
                    $dependents = @($sc.DependentServices | Select-Object Name,DisplayName,Status)
                } catch {}

                $reg = $null
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
                if (Test-Path $regPath) {
                    try {
                        $rp = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
                        $reg = [pscustomobject]@{
                            Start=$rp.Start
                            Type=$rp.Type
                            ErrorControl=$rp.ErrorControl
                            ImagePath=$rp.ImagePath
                            ObjectName=$rp.ObjectName
                            DependOnService=$rp.DependOnService
                        }
                    } catch {}
                }

                $triggers = @()
                try {
                    $raw = & sc.exe qtriggerinfo $name 2>&1
                    $triggers = @($raw | ForEach-Object { [string]$_ })
                } catch {}

                $data = [pscustomobject]@{
                    Service=$svc
                    Dependencies=$deps
                    Dependents=$dependents
                    RegistryReadOnly=$reg
                    TriggerInfo=$triggers
                }
                return New-BrokerResult $true $Action 0 $data "" "Read-only service configuration/trigger query completed."
            }


            'GetEventCorrelationWindow' {
                $kind = [string]$Parameters.Kind
                $days = 14
                if ($Parameters.ContainsKey('Days')) {
                    try { $days = [int]$Parameters.Days } catch {}
                }
                if ($days -lt 1) { $days = 1 }
                if ($days -gt 30) { $days = 30 }
                $since = (Get-Date).AddDays(-$days)

                $raw = @()
                try {
                    $raw = @(Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction SilentlyContinue |
                        Where-Object {
                            if ($kind -eq 'WiFi') {
                                ($_.ProviderName -match 'Netwtw|WLAN|NDIS') -and ($_.Level -le 4)
                            } elseif ($kind -eq 'Storage') {
                                ($_.ProviderName -in @('Disk','Ntfs','stornvme','storahci','volmgr','Microsoft-Windows-StorPort','Kernel-PnP')) -and ($_.Level -le 4)
                            } elseif ($kind -eq 'Power') {
                                (($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -in 41,42,107,109,131) -or
                                 ($_.ProviderName -eq 'EventLog' -and $_.Id -in 6005,6006,6008) -or
                                 ($_.ProviderName -eq 'USER32' -and $_.Id -eq 1074) -or
                                 ($_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1) -or
                                 ($_.ProviderName -match 'WHEA|Disk|Ntfs|Netwtw|NDIS'))
                            } else {
                                $false
                            }
                        } |
                        Sort-Object TimeCreated)
                } catch {}

                $events = @($raw | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message)
                $incidents = @()

                if ($kind -eq 'WiFi') {
                    $anchors = @($events | Where-Object { $_.ProviderName -match 'Netwtw' -and $_.Id -in 6062,5010 })
                    foreach ($anchor in $anchors) {
                        $near = @($events | Where-Object {
                            [math]::Abs(($_.TimeCreated - $anchor.TimeCreated).TotalSeconds) -le 30
                        })
                        $incidents += [pscustomobject]@{
                            AnchorTime=$anchor.TimeCreated
                            AnchorProvider=$anchor.ProviderName
                            AnchorId=$anchor.Id
                            WindowSeconds=30
                            Related=@($near)
                            Signature=(@($near | ForEach-Object { "$($_.ProviderName):$($_.Id)" }) -join ' -> ')
                        }
                    }
                } elseif ($kind -eq 'Storage') {
                    $anchors = @($events | Where-Object {
                        ($_.ProviderName -eq 'Disk' -and $_.Id -in 7,51,153) -or
                        ($_.ProviderName -eq 'Ntfs' -and $_.Id -in 50,55,98,140)
                    })
                    foreach ($anchor in $anchors) {
                        $near = @($events | Where-Object {
                            [math]::Abs(($_.TimeCreated - $anchor.TimeCreated).TotalSeconds) -le 20
                        })
                        $incidents += [pscustomobject]@{
                            AnchorTime=$anchor.TimeCreated
                            AnchorProvider=$anchor.ProviderName
                            AnchorId=$anchor.Id
                            WindowSeconds=20
                            Related=@($near)
                            Signature=(@($near | ForEach-Object { "$($_.ProviderName):$($_.Id)" }) -join ' -> ')
                        }
                    }
                } elseif ($kind -eq 'Power') {
                    $anchors = @($events | Where-Object {
                        ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or
                        ($_.ProviderName -eq 'EventLog' -and $_.Id -eq 6008)
                    })
                    foreach ($anchor in $anchors) {
                        $near = @($events | Where-Object {
                            $delta = ($_.TimeCreated - $anchor.TimeCreated).TotalMinutes
                            $delta -ge -5 -and $delta -le 2
                        })
                        $incidents += [pscustomobject]@{
                            AnchorTime=$anchor.TimeCreated
                            AnchorProvider=$anchor.ProviderName
                            AnchorId=$anchor.Id
                            WindowMinutesBefore=5
                            WindowMinutesAfter=2
                            Related=@($near)
                            Signature=(@($near | ForEach-Object { "$($_.ProviderName):$($_.Id)" }) -join ' -> ')
                        }
                    }
                }

                # Deduplicate incident signatures/timestamps conservatively.
                $dedup = @($incidents | Group-Object { "$($_.AnchorTime.ToString('o'))|$($_.Signature)" } | ForEach-Object { $_.Group[0] })
                $data = [pscustomobject]@{
                    Kind=$kind
                    Days=$days
                    EventCount=$events.Count
                    IncidentCount=$dedup.Count
                    Incidents=$dedup
                    Note='Correlation is temporal evidence only; it does not prove causation.'
                }
                return New-BrokerResult $true $Action 0 $data "" "Read-only temporal event correlation completed."
            }

            'GetServiceFailureContext' {
                $name = [string]$Parameters.Name
                if ([string]::IsNullOrWhiteSpace($name)) {
                    return New-BrokerResult $false $Action 2 $null "Name is required." "No execution."
                }

                $escaped = $name.Replace("'","''")
                $svc = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $escaped) -ErrorAction SilentlyContinue |
                    Select-Object Name,DisplayName,State,StartMode,ExitCode,ProcessId,PathName,StartName,ServiceType)

                if ($svc.Count -eq 0) {
                    return New-BrokerResult $true $Action 0 `
                        ([pscustomobject]@{ Service=@(); Dependencies=@(); Dependents=@(); ScmEvents=@(); Binary=$null }) `
                        "" "Service failure context query completed; service was not found."
                }

                $dependencies = @()
                $dependents = @()
                try {
                    $serviceController = Get-Service -Name $name -ErrorAction Stop
                    $dependencies = @($serviceController.ServicesDependedOn | Select-Object Name,DisplayName,Status)
                    $dependents = @($serviceController.DependentServices | Select-Object Name,DisplayName,Status)
                } catch {}

                $binary = $null
                $path = [string]$svc[0].PathName
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $exe = $null
                    if ($path.StartsWith('"')) {
                        $m = [regex]::Match($path, '^"([^"]+)"')
                        if ($m.Success) { $exe = $m.Groups[1].Value }
                    } else {
                        $m = [regex]::Match($path, '^([^\s]+\.exe)')
                        if ($m.Success) { $exe = $m.Groups[1].Value }
                    }

                    if ($exe -and (Test-Path $exe)) {
                        $item = Get-Item $exe -ErrorAction SilentlyContinue
                        $sig = Get-AuthenticodeSignature -FilePath $exe -ErrorAction SilentlyContinue
                        $binary = [pscustomobject]@{
                            Path = $exe
                            Exists = $true
                            FileVersion = $item.VersionInfo.FileVersion
                            ProductVersion = $item.VersionInfo.ProductVersion
                            SignatureStatus = if ($sig) { [string]$sig.Status } else { $null }
                            Signer = if ($sig -and $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
                        }
                    } elseif ($exe) {
                        $binary = [pscustomobject]@{
                            Path = $exe
                            Exists = $false
                            FileVersion = $null
                            ProductVersion = $null
                            SignatureStatus = $null
                            Signer = $null
                        }
                    }
                }

                $since = (Get-Date).AddDays(-7)
                $scmEvents = @()
                try {
                    $scmEvents = @(Get-WinEvent -FilterHashtable @{
                        LogName='System'
                        ProviderName='Service Control Manager'
                        StartTime=$since
                    } -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Id -in 7000,7001,7009,7011,7023,7024,7031,7034,7040 -and
                        ([string]$_.Message -match [regex]::Escape($name) -or
                         [string]$_.Message -match [regex]::Escape([string]$svc[0].DisplayName))
                    } |
                    Select-Object -First 20 TimeCreated,Id,LevelDisplayName,Message)
                } catch {}

                $data = [pscustomobject]@{
                    Service = $svc
                    Dependencies = $dependencies
                    Dependents = $dependents
                    ScmEvents = $scmEvents
                    Binary = $binary
                }

                return New-BrokerResult $true $Action 0 $data "" "Read-only failed-service context query completed."
            }

            'StartServiceSafe' {
                $name = [string]$Parameters.Name
                $confirmed = [bool]$Parameters.Confirmed

                if ([string]::IsNullOrWhiteSpace($name)) {
                    return New-BrokerResult $false $Action 2 $null "Name is required." "No execution."
                }

                if (-not $confirmed) {
                    return New-BrokerResult $false $Action 125 $null `
                        "Safe repair requires explicit confirmation." `
                        "Denied before service start."
                }

                $safeStartAllowlist = @() # v2.8 evidence-first
                if ($safeStartAllowlist -notcontains $name) {
                    return New-BrokerResult $false $Action 126 $null `
                        "Service is not on the safe-start allowlist." `
                        "Denied by broker service policy."
                }

                # Scope safety: only start an existing service. No configuration,
                # startup type, binary path, account, registry, or ACL changes.
                $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'","''")) -ErrorAction SilentlyContinue
                if (-not $svc) {
                    return New-BrokerResult $false $Action 3 $null "Service not found." "No execution."
                }

                if ($svc.State -eq 'Running') {
                    return New-BrokerResult $true $Action 0 `
                        ([pscustomobject]@{Name=$svc.Name;State=$svc.State;StartMode=$svc.StartMode}) `
                        "" "Service already running; no change needed."
                }

                Start-Service -Name $name -ErrorAction Stop
                Start-Sleep -Milliseconds 700

                $after = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'","''")) -ErrorAction SilentlyContinue |
                    Select-Object Name,DisplayName,State,StartMode,ExitCode,ProcessId

                return New-BrokerResult $true $Action 0 $after "" "Start-Service completed; verify with VerifyServiceRunning."
            }

            'VerifyServiceRunning' {
                $name = [string]$Parameters.Name
                if ([string]::IsNullOrWhiteSpace($name)) {
                    return New-BrokerResult $false $Action 2 $null "Name is required." "No execution."
                }

                $svc = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'","''")) -ErrorAction SilentlyContinue |
                    Select-Object Name,DisplayName,State,StartMode,ExitCode,ProcessId)

                $ok = ($svc.Count -gt 0 -and $svc[0].State -eq 'Running')
                $verification = if ($ok) { "Verified: service is running." } else { "Verification failed: service is not running." }

                return New-BrokerResult $true $Action (if ($ok) {0} else {1}) $svc "" $verification
            }
        }
    }
    catch {
        return New-BrokerResult $true $Action 1 $null $_.Exception.Message "Action failed; no repair attempted."
    }
}

Export-ModuleMember -Function *
