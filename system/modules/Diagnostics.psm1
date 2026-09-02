function Get-SystemDiagnostic {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        WindowsCaption = $os.Caption
        Version = $os.Version
        BuildNumber = $os.BuildNumber
        LastBoot = $os.LastBootUpTime
        UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        LogicalProcessors = [int]$cs.NumberOfLogicalProcessors
        TotalRAM_GB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        FreeRAM_GB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    }
}

function Get-ProcessDiagnostic {
    param([int]$SampleMilliseconds = 1200)

    $logical = [Environment]::ProcessorCount
    if ($logical -lt 1) { $logical = 1 }

    $before = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($null -ne $_.CPU) {
            $before[[int]$_.Id] = [double]$_.CPU
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $SampleMilliseconds
    $after = @(Get-Process -ErrorAction SilentlyContinue)
    $sw.Stop()

    $interval = $sw.Elapsed.TotalSeconds
    if ($interval -le 0) { $interval = $SampleMilliseconds / 1000.0 }

    $items = foreach ($p in $after) {
        $current = $null
        if ($before.ContainsKey([int]$p.Id) -and $null -ne $p.CPU) {
            $delta = [double]$p.CPU - [double]$before[[int]$p.Id]
            if ($delta -lt 0) { $delta = 0 }
            $current = [math]::Round(($delta / $interval / $logical) * 100, 1)
            if ($current -lt 0) { $current = 0 }
            if ($current -gt 100) { $current = 100 }
        }

        [pscustomobject]@{
            Name = $p.ProcessName
            Id = $p.Id
            CPU_CurrentPct = $current
            CPU_Total_s = if ($null -ne $p.CPU) { [math]::Round($p.CPU,1) } else { $null }
            RAM_MB = [math]::Round($p.WorkingSet64/1MB,1)
        }
    }

    $items |
        Sort-Object @{Expression={ if ($null -eq $_.CPU_CurrentPct) { -1 } else { $_.CPU_CurrentPct } };Descending=$true},
                    @{Expression='RAM_MB';Descending=$true} |
        Select-Object -First 25
}

function Get-ServiceDiagnostic {
    Get-CimInstance Win32_Service |
        Where-Object {
            $_.StartMode -eq 'Auto' -and
            $_.State -ne 'Running' -and
            $_.Name -notmatch '^(edgeupdate|GoogleUpdater.*|MapsBroker|sppsvc)$'
        } |
        Select-Object Name, DisplayName, State, StartMode, ExitCode
}

function Get-StorageDiagnostic {
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue |
        Where-Object DriveLetter |
        Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
            @{N='Size_GB';E={[math]::Round($_.Size/1GB,2)}},
            @{N='Free_GB';E={[math]::Round($_.SizeRemaining/1GB,2)}},
            @{N='FreePct';E={if ($_.Size) {[math]::Round(100*$_.SizeRemaining/$_.Size,1)} else {$null}}})

    $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue |
        Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
            @{N='Size_GB';E={[math]::Round($_.Size/1GB,2)}},
            SerialNumber, BusType)

    $disks = @(Get-Disk -ErrorAction SilentlyContinue |
        Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle,
            HealthStatus, OperationalStatus, IsBoot, IsSystem, IsOffline,
            @{N='Size_GB';E={[math]::Round($_.Size/1GB,2)}})

    [pscustomobject]@{
        Volumes = $volumes
        PhysicalDisks = $physical
        Disks = $disks
    }
}

function Get-DriverDiagnostic {
    @(Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object Name, PNPDeviceID, ConfigManagerErrorCode, Status)
}

function Get-NetworkDiagnostic {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress)

    $ip = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias,
            @{N='IPv4';E={($_.IPv4Address.IPAddress -join ', ')}},
            @{N='Gateway';E={($_.IPv4DefaultGateway.NextHop -join ', ')}},
            @{N='DNS';E={($_.DNSServer.ServerAddresses -join ', ')}})

    [pscustomobject]@{ Adapters = $adapters; IPConfiguration = $ip }
}

function Get-UpdateDiagnostic {
    $hotfix = @(Get-HotFix -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 20 HotFixID, Description, InstalledOn)

    [pscustomobject]@{ RecentHotfixes = $hotfix }
}

function Get-EventDiagnostic {
    $since = (Get-Date).AddDays(-7)
    @(Get-WinEvent -FilterHashtable @{
        LogName = @('System','Application')
        StartTime = $since
        Level = @(1,2)
    } -ErrorAction SilentlyContinue |
        Select-Object -First 350 TimeCreated, LogName, ProviderName, Id, LevelDisplayName, Message)
}

function Test-NeedIntegrityChecks {
    param(
        [Parameter(Mandatory=$true)]$Results
    )

    $reasons = @()
    $events = @($Results.Events)

    # Strong indicators of Windows component/system-file corruption.
    $strongProviders = @(
        'Microsoft-Windows-CBS',
        'Microsoft-Windows-Servicing',
        'Microsoft-Windows-Windows Resource Protection'
    )

    foreach ($e in $events) {
        if ($strongProviders -contains [string]$e.ProviderName) {
            $reasons += "System integrity event: $($e.ProviderName) / ID $($e.Id)"
        }
    }

    # Windows Update errors only trigger deep integrity checks when the text
    # points to component-store/servicing corruption, not ordinary app-lock
    # failures such as 0x80073D02.
    foreach ($e in @($events | Where-Object {
        $_.ProviderName -eq 'Microsoft-Windows-WindowsUpdateClient' -and $_.Id -eq 20
    })) {
        $msg = [string]$e.Message
        if ($msg -match '0x800f081f|0x800f0906|0x800f0922|0x80073712|0x80070002|0x8007000d|component store|servicing stack|source files could not be found') {
            $reasons += "Windows Update error suggests servicing/component-store trouble: ID $($e.Id)"
        }
    }

    # A failed or missing core Windows service can justify a deeper check only
    # when it concerns servicing itself.
    foreach ($e in @($events | Where-Object {
        $_.ProviderName -eq 'Service Control Manager' -and $_.Id -in @(7000,7009,7011)
    })) {
        $msg = [string]$e.Message
        if ($msg -match 'Windows Modules Installer|TrustedInstaller') {
            $reasons += "Windows servicing service timeout/start failure"
        }
    }

    # De-duplicate while preserving a compact reason list.
    $reasons = @($reasons | Select-Object -Unique)

    [pscustomobject]@{
        Needed = ($reasons.Count -gt 0)
        Reasons = $reasons
    }
}

function Get-SkippedIntegrityResult {
    param(
        [string[]]$Reasons = @()
    )

    [pscustomobject]@{
        Mode = 'Skipped'
        Triggered = $false
        Reasons = @($Reasons)
        DISMExitCode = $null
        DISM = 'Skipped by quick-scan policy.'
        SFCExitCode = $null
        SFC = 'Skipped by quick-scan policy.'
    }
}

function Invoke-IntegrityChecks {
    param(
        [string[]]$Reasons = @()
    )

    $result = [ordered]@{
        Mode = 'Deep'
        Triggered = $true
        Reasons = @($Reasons)
    }

    $dism = & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1
    $result.DISMExitCode = $LASTEXITCODE
    $result.DISM = (($dism -join "`n") -replace "`0","").Trim()

    $sfc = & sfc.exe /verifyonly 2>&1
    $result.SFCExitCode = $LASTEXITCODE
    $result.SFC = (($sfc -join "`n") -replace "`0","").Trim()

    [pscustomobject]$result
}

function New-Finding {
    param(
        [string]$Severity,
        [string]$Area,
        [string]$Issue,
        [string]$Evidence = "",
        [string]$Recommendation = ""
    )

    [pscustomobject]@{
        Severity = $Severity
        Area = $Area
        Issue = $Issue
        Evidence = $Evidence
        Recommendation = $Recommendation
    }
}

function Get-CorrelatedFindings {
    param([Parameter(Mandatory=$true)]$Results)

    $findings = @()

    foreach ($v in @($Results.Storage.Volumes)) {
        if ($null -ne $v.FreePct -and [double]$v.FreePct -lt 10) {
            $findings += New-Finding 'ACTION' 'Storage' `
                "Low free space on $($v.DriveLetter): $($v.FreePct)% free" `
                "$($v.Free_GB) GB free of $($v.Size_GB) GB" `
                "Free disk space before large updates or repairs."
        }
    }

    foreach ($d in @($Results.Storage.PhysicalDisks)) {
        if ($d.HealthStatus -and $d.HealthStatus -ne 'Healthy') {
            $findings += New-Finding 'CRITICAL' 'Disk' `
                "$($d.FriendlyName): physical disk health is $($d.HealthStatus)" `
                "OperationalStatus=$($d.OperationalStatus)" `
                "Back up important data and run vendor/storage diagnostics."
        }
    }

    foreach ($dev in @($Results.Drivers)) {
        $findings += New-Finding 'ACTION' 'Device' `
            "$($dev.Name): PnP error code $($dev.ConfigManagerErrorCode)" `
            "$($dev.PNPDeviceID)" `
            "Inspect the device/driver before attempting changes."
    }

    foreach ($svc in @($Results.Services)) {
        $findings += New-Finding 'INFO' 'Service' `
            "Automatic service not running: $($svc.Name)" `
            "State=$($svc.State), ExitCode=$($svc.ExitCode)" `
            "Investigate only if the related Windows/app feature is failing."
    }

    $events = @($Results.Events)

    $disk7 = @($events | Where-Object { $_.ProviderName -eq 'disk' -and $_.Id -eq 7 })
    if ($disk7.Count -gt 0) {
        $diskNumbers = @()
        foreach ($e in $disk7) {
            $m = [regex]::Match([string]$e.Message, 'Harddisk(\d+)')
            if ($m.Success) { $diskNumbers += [int]$m.Groups[1].Value }
        }
        $diskNumbers = @($diskNumbers | Sort-Object -Unique)

        $mapText = ""
        foreach ($n in $diskNumbers) {
            $current = @($Results.Storage.Disks | Where-Object { [int]$_.Number -eq $n } | Select-Object -First 1)
            if ($current.Count -gt 0) {
                $mapText += " Current Disk $n = $($current[0].FriendlyName), $($current[0].Size_GB) GB, $($current[0].BusType)."
            } else {
                $mapText += " Disk $n is not currently mapped."
            }
        }

        $findings += New-Finding 'CRITICAL' 'Disk' `
            "$($disk7.Count)x disk bad-block event (Event ID 7)" `
            "$($disk7[0].Message)$mapText" `
            "Identify the exact device by serial/current connection and back up important data before any repair. Disk numbers can change between sessions."
    }

    $volsnap36 = @($events | Where-Object { $_.ProviderName -eq 'Volsnap' -and $_.Id -eq 36 })
    if ($volsnap36.Count -gt 0) {
        $findings += New-Finding 'WARNING' 'Storage' `
            "$($volsnap36.Count)x shadow-copy storage limit event" `
            "$($volsnap36[0].Message)" `
            "Check the affected volume and VSS storage limits if restore points/backups are failing."
    }

    $kp41 = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 })
    $ev6008 = @($events | Where-Object { $_.ProviderName -eq 'EventLog' -and $_.Id -eq 6008 })
    if ($kp41.Count -gt 0 -or $ev6008.Count -gt 0) {
        $count = [math]::Max($kp41.Count, $ev6008.Count)
        $latest = @($kp41 + $ev6008 | Sort-Object TimeCreated -Descending | Select-Object -First 1)
        $latestText = if ($latest.Count) { "Latest: $($latest[0].TimeCreated)" } else { "" }

        $findings += New-Finding 'ACTION' 'Power/Stability' `
            "$count unexpected shutdown/reboot incident(s) detected" `
            "Kernel-Power 41=$($kp41.Count), EventLog 6008=$($ev6008.Count). $latestText" `
            "Correlate the times with freezes, power loss, forced shutdowns, driver resets, or crashes."
    }

    $wifi5010 = @($events | Where-Object { $_.ProviderName -eq 'Netwtw10' -and $_.Id -eq 5010 })
    $ndis10317 = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-NDIS' -and $_.Id -eq 10317 })
    if ($wifi5010.Count -gt 0 -or $ndis10317.Count -gt 0) {
        $sev = if (($wifi5010.Count + $ndis10317.Count) -ge 3) { 'WARNING' } else { 'INFO' }
        $findings += New-Finding $sev 'Network' `
            "Intel/Wi-Fi driver or power-transition errors detected" `
            "Netwtw10/5010=$($wifi5010.Count), NDIS/10317=$($ndis10317.Count)" `
            "If Wi-Fi disconnects or wake/resume is unstable, inspect the Intel Wi-Fi driver and power-management path."
    }

    $vbox = @($events | Where-Object { $_.ProviderName -eq 'VBoxNetLwf' -and $_.Id -eq 12 })
    if ($vbox.Count -gt 0) {
        $findings += New-Finding 'WARNING' 'VirtualBox' `
            "$($vbox.Count)x VirtualBox network filter driver internal error" `
            "$($vbox[0].Message)" `
            "Check VirtualBox version/network filter installation if VM networking or host networking is unstable."
    }

    $appErrors = @($events | Where-Object { $_.ProviderName -eq 'Application Error' -and $_.Id -eq 1000 })
    if ($appErrors.Count -gt 0) {
        $apps = @{}
        foreach ($e in $appErrors) {
            $name = "unknown application"
            $m = [regex]::Match([string]$e.Message, '([A-Za-z0-9_.-]+\.exe)', 'IgnoreCase')
            if ($m.Success) { $name = $m.Groups[1].Value }
            if (-not $apps.ContainsKey($name)) { $apps[$name] = @() }
            $apps[$name] += $e
        }

        foreach ($name in ($apps.Keys | Sort-Object)) {
            $arr = @($apps[$name])
            $evidence = ($arr[0].Message -replace "`r|`n",' ')
            if ($evidence.Length -gt 260) { $evidence = $evidence.Substring(0,260) + '...' }

            $findings += New-Finding 'WARNING' 'Application' `
                "$($arr.Count)x crash: $name" `
                $evidence `
                "Investigate the app/driver only if the crash is reproducible or related to the reported symptom."
        }
    }

    $hangs = @($events | Where-Object { $_.ProviderName -eq 'Application Hang' -and $_.Id -eq 1002 })
    if ($hangs.Count -gt 0) {
        $evidence = ($hangs[0].Message -replace "`r|`n",' ')
        if ($evidence.Length -gt 220) { $evidence = $evidence.Substring(0,220) + '...' }

        $findings += New-Finding 'INFO' 'Application' `
            "$($hangs.Count)x application hang event" `
            $evidence `
            "Treat as relevant only if the same application is currently freezing."
    }

    $scm = @($events | Where-Object {
        $_.ProviderName -eq 'Service Control Manager' -and $_.Id -in @(7000,7009,7011)
    })

    $coreSvc = @($scm | Where-Object {
        $_.Message -match 'Windows Modules Installer|TrustedInstaller|Microsoft Account Sign-in Assistant'
    })
    if ($coreSvc.Count -gt 0) {
        $evidence = ($coreSvc[0].Message -replace "`r|`n",' ')
        if ($evidence.Length -gt 230) { $evidence = $evidence.Substring(0,230) + '...' }

        $findings += New-Finding 'WARNING' 'Service' `
            "$($coreSvc.Count)x core Windows service timeout/start failure" `
            $evidence `
            "Check recurrence and correlate with update/sign-in/startup problems before changing service configuration."
    }

    $googleSvc = @($scm | Where-Object { $_.Message -match 'GoogleUpdater' })
    if ($googleSvc.Count -gt 0) {
        $evidence = ($googleSvc[0].Message -replace "`r|`n",' ')
        if ($evidence.Length -gt 200) { $evidence = $evidence.Substring(0,200) + '...' }

        $findings += New-Finding 'INFO' 'Updater' `
            "$($googleSvc.Count)x Google Updater service timeout/start failure" `
            $evidence `
            "Usually low priority unless Chrome/Google software fails to update."
    }

    $wu20 = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WindowsUpdateClient' -and $_.Id -eq 20 })
    if ($wu20.Count -gt 0) {
        $evidence = ($wu20[0].Message -replace "`r|`n",' ')
        if ($evidence.Length -gt 220) { $evidence = $evidence.Substring(0,220) + '...' }

        $findings += New-Finding 'WARNING' 'Windows Update' `
            "$($wu20.Count)x update installation failure" `
            $evidence `
            "Retry after apps are closed; investigate further only if failures continue."
    }

    $tpm1801 = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-TPM-WMI' -and $_.Id -eq 1801 })
    if ($tpm1801.Count -gt 0) {
        $evidence = ($tpm1801[0].Message -replace "`r|`n",' ')
        if ($evidence.Length -gt 240) { $evidence = $evidence.Substring(0,240) + '...' }

        $findings += New-Finding 'WARNING' 'Secure Boot' `
            "$($tpm1801.Count)x Secure Boot CA/keys update notice" `
            $evidence `
            "Check Windows/firmware updates. Do not modify Secure Boot keys automatically."
    }

    $dcom = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-DistributedCOM' -and $_.Id -in @(10005,10010) })
    if ($dcom.Count -gt 0) {
        $findings += New-Finding 'NOISE' 'DCOM' `
            "$($dcom.Count)x DCOM timeout/start event(s)" `
            "Grouped because these are frequently secondary symptoms of another service/app timeout." `
            "Use only when correlated with a specific failing service or application."
    }

    $mt = @($events | Where-Object { $_.ProviderName -eq 'MTConfig' -and $_.Id -eq 1 })
    if ($mt.Count -gt 0) {
        $findings += New-Finding 'NOISE' 'Input' `
            "$($mt.Count)x multitouch input-mode configuration event" `
            "$($mt[0].Message)" `
            "Ignore unless touch/trackpad input is actually malfunctioning."
    }

    $vssShutdown = @($events | Where-Object {
        $_.ProviderName -eq 'VSS' -and $_.Message -match 'shutdown is in progress'
    })
    if ($vssShutdown.Count -gt 0) {
        $findings += New-Finding 'NOISE' 'VSS' `
            "$($vssShutdown.Count)x VSS event during system shutdown" `
            "The message explicitly says a system shutdown was in progress." `
            "Usually secondary to shutdown, not a standalone VSS fault."
    }

    if ($Results.Integrity.Mode -eq 'Skipped') {
        $findings += New-Finding 'INFO' 'Integrity' `
            "Deep Windows integrity scan skipped" `
            "Quick-scan policy found no strong component-store/system-file corruption indicators." `
            "Run DISM/SFC later only if symptoms or new evidence justify it."
    } else {
        if ($Results.Integrity.DISMExitCode -eq 0) {
            $findings += New-Finding 'INFO' 'Integrity' `
                "DISM ScanHealth completed successfully" `
                "ExitCode=0" `
                "No DISM repair is indicated by this check."
        } else {
            $evidence = ($Results.Integrity.DISM -replace "`r|`n",' ')
            if ($evidence.Length -gt 240) { $evidence = $evidence.Substring(0,240) + '...' }
            $findings += New-Finding 'ACTION' 'Integrity' `
                "DISM ScanHealth returned exit code $($Results.Integrity.DISMExitCode)" `
                $evidence `
                "Review DISM output before attempting repair."
        }

        if ($Results.Integrity.SFCExitCode -eq 0) {
            $findings += New-Finding 'INFO' 'Integrity' `
                "SFC verify-only completed successfully" `
                "ExitCode=0" `
                "No automatic SFC repair is indicated by the exit code."
        } else {
            $evidence = ($Results.Integrity.SFC -replace "`r|`n",' ')
            if ($evidence.Length -gt 240) { $evidence = $evidence.Substring(0,240) + '...' }
            $findings += New-Finding 'ACTION' 'Integrity' `
                "SFC verify-only returned exit code $($Results.Integrity.SFCExitCode)" `
                $evidence `
                "Review SFC output before attempting repair."
        }
    }

    $rank = @{
        'CRITICAL' = 0
        'ACTION' = 1
        'WARNING' = 2
        'INFO' = 3
        'NOISE' = 4
    }

    @($findings | Sort-Object @{Expression={ $rank[$_.Severity] };Ascending=$true}, Area, Issue)
}

Export-ModuleMember -Function *
