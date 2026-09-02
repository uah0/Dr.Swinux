function New-AgentStep {
    param(
        [int]$Iteration,
        [string]$ProblemId,
        [string]$ProblemType,
        [string]$Severity,
        [string]$Hypothesis,
        [string]$Action,
        [hashtable]$Parameters,
        $BrokerResult,
        [string]$Conclusion,
        [string]$ProblemState
    )

    [pscustomobject]@{
        Iteration = $Iteration
        ProblemId = $ProblemId
        ProblemType = $ProblemType
        Severity = $Severity
        Hypothesis = $Hypothesis
        Action = $Action
        Parameters = $Parameters
        Allowed = $BrokerResult.Allowed
        ExitCode = $BrokerResult.ExitCode
        Data = $BrokerResult.Data
        Error = $BrokerResult.Error
        Verification = $BrokerResult.Verification
        Conclusion = $Conclusion
        ProblemState = $ProblemState
        Timestamp = (Get-Date)
    }
}

function Get-ActionKey {
    param(
        [string]$ProblemId,
        [string]$Action,
        [hashtable]$Parameters
    )

    $parts = @($ProblemId,$Action)
    foreach ($k in @($Parameters.Keys | Sort-Object)) {
        $parts += ("{0}={1}" -f $k,$Parameters[$k])
    }
    return ($parts -join '|')
}

function Add-AgentCandidate {
    param(
        [System.Collections.ArrayList]$Queue,
        [hashtable]$Seen,
        [int]$Priority,
        [string]$ProblemId,
        [string]$ProblemType,
        [string]$Severity,
        [string]$Hypothesis,
        [string]$Action,
        [hashtable]$Parameters = @{}
    )

    $key = Get-ActionKey $ProblemId $Action $Parameters
    if ($Seen.ContainsKey($key)) { return }

    [void]$Queue.Add([pscustomobject]@{
        Priority = $Priority
        ProblemId = $ProblemId
        ProblemType = $ProblemType
        Severity = $Severity
        Hypothesis = $Hypothesis
        Action = $Action
        Parameters = $Parameters
        Key = $key
    })
}

function Convert-ToSafeId {
    param([string]$Text)

    $id = ($Text -replace '[^A-Za-z0-9_.:-]','_')
    while ($id -match '__') { $id = $id -replace '__','_' }
    return $id.Trim('_')
}

function Get-InitialAgentCandidates {
    param(
        [Parameter(Mandatory=$true)]$Findings
    )

    $queue = New-Object System.Collections.ArrayList
    $seen = @{}
    $severityRank = @{ 'CRITICAL'=0; 'ACTION'=1; 'WARNING'=2; 'INFO'=3; 'NOISE'=4 }

    $orderedFindings = @($Findings | Sort-Object @{Expression={
        if ($severityRank.ContainsKey([string]$_.Severity)) { $severityRank[[string]$_.Severity] } else { 9 }
    };Ascending=$true}, Area, Issue)

    foreach ($f in $orderedFindings) {
        $issue = [string]$f.Issue
        $area = [string]$f.Area
        $severity = [string]$f.Severity
        $priority = if ($severityRank.ContainsKey($severity)) { $severityRank[$severity] } else { 9 }

        if ($area -eq 'Disk' -or $issue -match 'bad-block|bad block') {
            $pid = 'Storage:HistoricalBadBlock'
            Add-AgentCandidate $queue $seen $priority $pid 'Storage' $severity `
                "A historical disk bad-block event may indicate a failing or disconnected storage device." `
                'GetDiskIdentity' @{}
            Add-AgentCandidate $queue $seen ($priority + 1) $pid 'Storage' $severity `
                "Storage reliability counters may show current media/controller errors." `
                'GetStorageReliability' @{}
        }

        if ($area -eq 'Power/Stability') {
            $pid = 'Power:UnexpectedShutdown'
            Add-AgentCandidate $queue $seen $priority $pid 'Power' $severity `
                "Unexpected shutdowns may have BugCheck, WHEA, or minidump evidence." `
                'GetUnexpectedShutdownContext' @{}
        }

        if ($area -eq 'Network' -and $issue -match 'Wi-Fi|Intel|Netwtw') {
            $pid = 'Network:IntelAX201'
            Add-AgentCandidate $queue $seen $priority $pid 'Network' $severity `
                "Intel Wi-Fi errors may correlate with a specific driver version or adapter state." `
                'GetWifiDriver' @{}
            Add-AgentCandidate $queue $seen ($priority + 1) $pid 'Network' $severity `
                "Current Wi-Fi adapter state may show whether the historical driver fault is active now." `
                'GetWifiAdapterState' @{}
        }

        if ($area -eq 'VirtualBox') {
            $pid = 'Network:VirtualBox'
            Add-AgentCandidate $queue $seen $priority $pid 'Network' $severity `
                "VBoxNetLwf errors may correlate with the installed VirtualBox filter driver/network adapter state." `
                'GetVirtualBoxNetworkState' @{}
        }

        if ($area -eq 'Application' -and $issue -match 'crash:\s*([A-Za-z0-9_.-]+\.exe)') {
            $proc = $Matches[1]
            $pid = "Application:$proc"
            Add-AgentCandidate $queue $seen $priority $pid 'Application' $severity `
                "This specific application crash may be tied to the executable/module version or may no longer be active." `
                'GetCrashContext' @{ ProcessName = $proc }
        }

        if ($area -eq 'Service' -and $issue -match 'Automatic service not running:\s*([A-Za-z0-9_.-]+)') {
            $svc = $Matches[1]
            $pid = "Service:$svc"
            Add-AgentCandidate $queue $seen $priority $pid 'Service' $severity `
                "This specific stopped automatic service should be checked before deciding whether it is faulty." `
                'GetServiceState' @{ Name = $svc }
        }

        if ($area -eq 'Windows Update') {
            $pid = 'Update:RecentFailures'
            Add-AgentCandidate $queue $seen $priority $pid 'Update' $severity `
                "Update failures should be inspected for recurring package/error patterns before any repair." `
                'GetUpdateFailureContext' @{}
        }

        if ($area -eq 'Secure Boot') {
            $pid = 'Firmware:SecureBootKeys'
            Add-AgentCandidate $queue $seen $priority $pid 'Firmware' $severity `
                "Secure Boot key notices should be correlated with current firmware and Secure Boot state." `
                'GetSecureBootContext' @{}
        }
    }

    # v2.8: evidence-first follow-up is part of the MAIN agent queue.
    # These are not a second pass; they participate in the same per-problem state machine.
    $hasStorage = @($Findings | Where-Object {
        ([string]$_.Area -eq 'Disk') -or
        ([string]$_.Issue -match 'bad-block|bad block') -or
        ([string]$_.Evidence -match 'bad block|Harddisk[0-9]+')
    }).Count -gt 0
    if ($hasStorage) {
        Add-AgentCandidate $queue $seen 0 'Storage:HistoricalBadBlock' 'Storage' 'CRITICAL' `
            'Correlate historical bad-block evidence with recent storage events and CURRENT disk identity without assuming HarddiskN mapping.' `
            'GetDiskEventContext' @{}
    }

    $hasPower = @($Findings | Where-Object {
        ([string]$_.Area -eq 'Power/Stability') -or
        ([string]$_.Issue -match 'unexpected shutdown|reboot') -or
        ([string]$_.Evidence -match 'Kernel-Power|6008')
    }).Count -gt 0
    if ($hasPower) {
        Add-AgentCandidate $queue $seen 1 'Power:UnexpectedShutdown' 'Power' 'ACTION' `
            'Build a recent power/shutdown timeline before considering any repair.' `
            'GetPowerEventTimeline' @{}
    }

    $hasWifi = @($Findings | Where-Object {
        ([string]$_.Area -eq 'Network') -and
        (([string]$_.Issue -match 'Wi-Fi|Intel|Netwtw') -or ([string]$_.Evidence -match 'Netwtw|AX201'))
    }).Count -gt 0
    if ($hasWifi) {
        Add-AgentCandidate $queue $seen 2 'Network:IntelAX201' 'Network' 'WARNING' `
            'Compare historical Intel Wi-Fi faults with the recent Netwtw/WLAN/NDIS timeline and current adapter state.' `
            'GetWifiErrorTimeline' @{}
    }

    $hasWbf = @($Findings | Where-Object {
        ([string]$_.Area -eq 'Service') -and
        (([string]$_.Issue -match 'WbfPolicyService110') -or ([string]$_.Evidence -match 'WbfPolicyService110'))
    }).Count -gt 0
    if ($hasWbf) {
        Add-AgentCandidate $queue $seen 3 'Service:WbfPolicyService110' 'Service' 'INFO' `
            'The service previously failed a safe start attempt; inspect trigger/dependency/configuration evidence before any retry.' `
            'GetServiceConfigurationContext' @{Name='WbfPolicyService110'}
    }

    # v2.9: temporal correlation follows evidence collection in the same main queue.
    if ($hasStorage) {
        Add-AgentCandidate $queue $seen 4 'Storage:HistoricalBadBlock' 'Storage' 'CRITICAL' `
            'Group Disk/Ntfs/storage events into short time windows to identify repeated incident patterns.' `
            'GetEventCorrelationWindow' @{Kind='Storage';Days=30}
    }
    if ($hasPower) {
        Add-AgentCandidate $queue $seen 5 'Power:UnexpectedShutdown' 'Power' 'ACTION' `
            'Inspect the minutes around unexpected shutdown markers for storage, network, WHEA or planned-shutdown context.' `
            'GetEventCorrelationWindow' @{Kind='Power';Days=14}
    }
    if ($hasWifi) {
        Add-AgentCandidate $queue $seen 6 'Network:IntelAX201' 'Network' 'WARNING' `
            'Group Netwtw 6062/5010 with nearby WLAN/NDIS events to identify repeated Wi-Fi reset sequences.' `
            'GetEventCorrelationWindow' @{Kind='WiFi';Days=14}
    }

    @($queue | Sort-Object Priority,ProblemId,Action)
}

function Get-AgentConclusion {
    param(
        [string]$Action,
        $BrokerResult
    )

    if (-not $BrokerResult.Allowed) {
        return "Broker denied the requested action."
    }

    if ($BrokerResult.ExitCode -ne 0) {
        return "The targeted check failed. Keep the problem unresolved."
    }

    switch ($Action) {
        'GetDiskIdentity' {
            return "Current disk inventory captured. Historical HarddiskN must not be assumed to match the same current disk number."
        }
        'GetStorageReliability' {
            $bad = @($BrokerResult.Data | Where-Object {
                ($null -ne $_.ReadErrorsTotal -and [double]$_.ReadErrorsTotal -gt 0) -or
                ($null -ne $_.WriteErrorsTotal -and [double]$_.WriteErrorsTotal -gt 0) -or
                ($_.HealthStatus -and $_.HealthStatus -ne 'Healthy')
            })
            if ($bad.Count -gt 0) {
                return "Current storage reliability data contains health/error indicators."
            }
            return "No obvious current reliability-counter fault was returned, but the historical bad-block event is not explained."
        }
        'GetUnexpectedShutdownContext' {
            $bc = @($BrokerResult.Data.BugCheckEvents).Count
            $wh = @($BrokerResult.Data.WHEAEvents).Count
            $dp = @($BrokerResult.Data.Minidumps).Count
            return "Shutdown context captured: BugCheck events=$bc, WHEA events=$wh, minidumps=$dp."
        }
        'GetWifiDriver' {
            return "Wi-Fi driver inventory captured."
        }
        'GetWifiAdapterState' {
            return "Current Wi-Fi adapter state captured."
        }
        'GetVirtualBoxNetworkState' {
            $d = @($BrokerResult.Data.Drivers).Count
            $a = @($BrokerResult.Data.Adapters).Count
            return "VirtualBox network state captured: drivers=$d, adapters=$a."
        }
        'GetCrashContext' {
            $running = @($BrokerResult.Data.Running).Count
            $crashes = @($BrokerResult.Data.RecentCrashes).Count
            return "Application context captured: running instances=$running, recent matching crashes=$crashes."
        }
        'GetServiceState' {
            return "Current service state captured; no service configuration was changed."
        }
        'GetDiskEventContext' {
            $events = @($BrokerResult.Data.Events).Count
            return "Storage event context captured: recent warning/error events=$events; current disk identity/reliability captured separately."
        }
        'GetPowerEventTimeline' {
            $events = @($BrokerResult.Data).Count
            return "Power/shutdown timeline captured: relevant events=$events."
        }
        'GetWifiErrorTimeline' {
            $events = @($BrokerResult.Data.Events).Count
            return "Wi-Fi error timeline captured: recent warning/error events=$events."
        }
        'GetServiceConfigurationContext' {
            return "Service configuration, dependencies and trigger context captured read-only; no service start was attempted."
        }
        'GetEventCorrelationWindow' {
            $kind = [string]$BrokerResult.Data.Kind
            $count = [int]$BrokerResult.Data.IncidentCount
            return "Temporal correlation completed for ${kind}: incidents=$count. Time proximity is evidence, not proof of causation."
        }
        'GetUpdateFailureContext' {
            return "Recent Windows Update failure context captured for pattern analysis."
        }
        'GetSecureBootContext' {
            return "Current BIOS and Secure Boot state captured; no firmware or key changes were attempted."
        }
        default {
            return "Targeted read-only check completed."
        }
    }
}

function Get-ProblemState {
    param(
        [string]$ProblemId,
        [string]$Action,
        $BrokerResult
    )

    if (-not $BrokerResult.Allowed -or $BrokerResult.ExitCode -ne 0) {
        return 'NeedsMoreEvidence'
    }

    switch ($Action) {
        'GetDiskIdentity' {
            return 'NeedsMoreEvidence'
        }

        'GetStorageReliability' {
            $bad = @($BrokerResult.Data | Where-Object {
                ($null -ne $_.ReadErrorsTotal -and [double]$_.ReadErrorsTotal -gt 0) -or
                ($null -ne $_.WriteErrorsTotal -and [double]$_.WriteErrorsTotal -gt 0) -or
                ($_.HealthStatus -and $_.HealthStatus -ne 'Healthy')
            })
            if ($bad.Count -gt 0) { return 'ActionCandidate' }
            return 'Monitor'
        }

        'GetUnexpectedShutdownContext' {
            $signals = @($BrokerResult.Data.BugCheckEvents).Count +
                       @($BrokerResult.Data.WHEAEvents).Count +
                       @($BrokerResult.Data.Minidumps).Count
            if ($signals -gt 0) { return 'ActionCandidate' }
            return 'NeedsMoreEvidence'
        }

        'GetWifiDriver' {
            return 'NeedsMoreEvidence'
        }

        'GetWifiAdapterState' {
            $up = @($BrokerResult.Data | Where-Object { $_.Status -eq 'Up' }).Count
            if ($up -gt 0) { return 'Monitor' }
            return 'ActionCandidate'
        }

        'GetVirtualBoxNetworkState' {
            $badSystemDrivers = @($BrokerResult.Data.Drivers | Where-Object {
                $_.StartMode -eq 'System' -and $_.State -ne 'Running'
            })
            if ($badSystemDrivers.Count -gt 0) { return 'ActionCandidate' }
            return 'Monitor'
        }

        'GetCrashContext' {
            $running = @($BrokerResult.Data.Running).Count
            $recent = @($BrokerResult.Data.RecentCrashes).Count
            if ($recent -gt 0 -and $running -gt 0) { return 'Monitor' }
            if ($recent -gt 0 -and $running -eq 0) { return 'ActionCandidate' }
            return 'HealthyNow'
        }

        'GetServiceState' {
            $svc = @($BrokerResult.Data)
            if ($svc.Count -eq 0) { return 'NeedsMoreEvidence' }

            # v2.8: Automatic + Stopped is NOT proof of failure.
            # Trigger-start/on-demand behavior is common and must be supported by
            # service-specific failure evidence before a repair is considered.
            if ($svc[0].State -eq 'Stopped') { return 'Monitor' }
            if ($svc[0].State -eq 'Running') { return 'HealthyNow' }
            return 'NeedsMoreEvidence'
        }

        'GetDiskEventContext' {
            $events = @($BrokerResult.Data.Events)
            $currentBad = @($BrokerResult.Data.Reliability | Where-Object {
                ($_.HealthStatus -and $_.HealthStatus -ne 'Healthy') -or
                ($null -ne $_.ReadErrorsTotal -and [double]$_.ReadErrorsTotal -gt 0) -or
                ($null -ne $_.WriteErrorsTotal -and [double]$_.WriteErrorsTotal -gt 0)
            })
            if ($currentBad.Count -gt 0) { return 'ActionCandidate' }
            if ($events.Count -gt 0) { return 'Monitor' }
            return 'Monitor'
        }

        'GetPowerEventTimeline' {
            $events = @($BrokerResult.Data)
            $whea = @($events | Where-Object { [string]$_.ProviderName -match 'WHEA' })
            if ($whea.Count -gt 0) { return 'NeedsMoreEvidence' }
            if ($events.Count -gt 0) { return 'Monitor' }
            return 'Monitor'
        }

        'GetWifiErrorTimeline' {
            $events = @($BrokerResult.Data.Events)
            $up = @($BrokerResult.Data.CurrentAdapters | Where-Object { $_.Status -eq 'Up' }).Count
            if ($events.Count -gt 0 -and $up -eq 0) { return 'NeedsMoreEvidence' }
            return 'Monitor'
        }

        'GetServiceConfigurationContext' {
            # Read-only evidence collection only. A stopped trigger-start service is
            # not actionable without SCM/binary/dependency failure evidence.
            return 'Monitor'
        }

        'GetEventCorrelationWindow' {
            $count = [int]$BrokerResult.Data.IncidentCount
            if ($count -gt 0) { return 'Monitor' }
            return 'Monitor'
        }

        'GetUpdateFailureContext' {
            $events = @($BrokerResult.Data)
            if ($events.Count -eq 0) { return 'HealthyNow' }

            $onlyAppLock = $true
            foreach ($e in $events) {
                if ([string]$e.Message -notmatch '0x80073D02') {
                    $onlyAppLock = $false
                }
            }

            if ($onlyAppLock) { return 'Monitor' }
            return 'ActionCandidate'
        }

        'GetSecureBootContext' {
            if ($BrokerResult.Data.SecureBootEnabled -eq $true) {
                return 'Monitor'
            }
            return 'ActionCandidate'
        }

        default {
            return 'NeedsMoreEvidence'
        }
    }
}

function Get-ProblemRank {
    param([string]$State)

    switch ($State) {
        'ActionCandidate' { return 0 }
        'NeedsMoreEvidence' { return 1 }
        'Monitor' { return 2 }
        'HealthyNow' { return 3 }
        'Explained' { return 4 }
        default { return 9 }
    }
}


function New-RepairCandidate {
    param(
        [string]$ProblemId,
        [string]$Action,
        [hashtable]$Parameters,
        [string]$Reason,
        [string]$Risk = 'SafeRepair',
        [bool]$RequiresConfirmation = $true,
        [string]$VerificationAction = '',
        [hashtable]$VerificationParameters = @{}
    )

    [pscustomobject]@{
        ProblemId = $ProblemId
        Action = $Action
        Parameters = $Parameters
        Reason = $Reason
        Risk = $Risk
        RequiresConfirmation = $RequiresConfirmation
        VerificationAction = $VerificationAction
        VerificationParameters = $VerificationParameters
        AutoExecute = $false
    }
}

function Get-RepairCandidates {
    param(
        [Parameter(Mandatory=$true)]$Problems
    )

    $repairs = @()

    foreach ($problem in @($Problems)) {
        if ($problem.State -ne 'ActionCandidate') { continue }

        if ($problem.ProblemId -match '^Service:(.+)$') {
            $serviceName = $Matches[1]

            # Development allowlist: do not assume every Auto+Stopped Windows
            # service should be started. Core/on-demand services such as gpsvc
            # require stronger evidence than StartMode alone.
            $safeStartAllowlist = @() # v2.8: evidence-first; no state-only service starts

            if ($safeStartAllowlist -contains $serviceName) {
                $repairs += New-RepairCandidate `
                    -ProblemId $problem.ProblemId `
                    -Action 'StartServiceSafe' `
                    -Parameters @{ Name = $serviceName; Confirmed = $false } `
                    -Reason "The service is stopped and is on the development safe-start allowlist." `
                    -Risk 'SafeRepair' `
                    -RequiresConfirmation $true `
                    -VerificationAction 'VerifyServiceRunning' `
                    -VerificationParameters @{ Name = $serviceName }
            }
        }
    }

    return @($repairs)
}


function Get-ServiceFailureDiagnosis {
    param(
        [string]$ProblemId,
        $BrokerResult
    )

    if (-not $BrokerResult.Allowed -or $BrokerResult.ExitCode -ne 0) {
        return [pscustomobject]@{
            ProblemId = $ProblemId
            State = 'RepairFailedNeedsDiagnosis'
            Diagnosis = 'Failed-service diagnostic query could not complete.'
            Evidence = @()
        }
    }

    $data = $BrokerResult.Data
    $evidence = @()
    $diagnosis = 'The service failed to start, but the current read-only checks did not isolate one cause.'

    if (@($data.Service).Count -eq 0) {
        $diagnosis = 'The service is no longer present.'
        $evidence += 'Service not found'
    } else {
        $svc = $data.Service[0]
        $evidence += ("State={0}" -f $svc.State)
        $evidence += ("StartMode={0}" -f $svc.StartMode)
        $evidence += ("ExitCode={0}" -f $svc.ExitCode)
    }

    $stoppedDeps = @($data.Dependencies | Where-Object { $_.Status -ne 'Running' })
    if ($stoppedDeps.Count -gt 0) {
        $diagnosis = 'One or more required service dependencies are not running.'
        $evidence += ("StoppedDependencies={0}" -f (($stoppedDeps | ForEach-Object {$_.Name}) -join ','))
    }

    if ($data.Binary) {
        if ($data.Binary.Exists -eq $false) {
            $diagnosis = 'The configured service executable was not found.'
            $evidence += ("MissingBinary={0}" -f $data.Binary.Path)
        } else {
            $evidence += ("Binary={0}" -f $data.Binary.Path)
            if ($data.Binary.SignatureStatus) {
                $evidence += ("Signature={0}" -f $data.Binary.SignatureStatus)
            }
        }
    }

    $events = @($data.ScmEvents)
    if ($events.Count -gt 0) {
        $evidence += ("SCMEvents={0}" -f $events.Count)
        $ids = (($events | Select-Object -ExpandProperty Id -Unique) -join ',')
        $evidence += ("SCMEventIds={0}" -f $ids)
        $diagnosis = 'Service Control Manager recorded failure events; inspect the captured event text for the next action.'
    }

    return [pscustomobject]@{
        ProblemId = $ProblemId
        State = 'RepairFailedNeedsDiagnosis'
        Diagnosis = $diagnosis
        Evidence = $evidence
    }
}


function Get-PnPProblemId {
    param($Finding)
    $id = $null
    if ($Finding.PSObject.Properties.Name -contains 'InstanceId') {
        $id = [string]$Finding.InstanceId
    }
    if ([string]::IsNullOrWhiteSpace($id)) {
        foreach ($propName in @('Details','Message','Evidence','Title')) {
            if ($Finding.PSObject.Properties.Name -contains $propName) {
                $text = [string]$Finding.$propName
                $m = [regex]::Match($text, '(ACPI\\[^\s,;]+|PCI\\[^\s,;]+|USB\\[^\s,;]+)')
                if ($m.Success) { $id = $m.Groups[1].Value; break }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return ('PnP:' + $id)
}

function Get-PnPInstanceIdFromProblemId {
    param([string]$ProblemId)
    if ($ProblemId -like 'PnP:*') { return $ProblemId.Substring(4) }
    return $null
}

function Get-PnPConclusion {
    param($Context)
    if (-not $Context -or -not $Context.Device) {
        return [pscustomobject]@{ State='NeedsMoreEvidence'; Conclusion='PnP device context could not identify the current device object.' }
    }

    $code = $Context.Device.ConfigManagerErrorCode
    $hasHardwareIds = @($Context.HardwareIds).Count -gt 0
    $hasInf = -not [string]::IsNullOrWhiteSpace([string]$Context.DriverInfPath)

    if ($code -eq 28) {
        if ($hasHardwareIds -and -not $hasInf) {
            return [pscustomobject]@{
                State='NeedsMoreEvidence'
                Conclusion='Device has Code 28. Hardware IDs were captured and no installed INF is bound; inspect related driver evidence before any repair.'
            }
        }
        return [pscustomobject]@{
            State='NeedsMoreEvidence'
            Conclusion='Device has Code 28; collect exact identifiers and driver binding evidence before considering repair.'
        }
    }

    if ($code -eq 0 -or [string]$Context.Device.Status -eq 'OK') {
        return [pscustomobject]@{ State='HealthyNow'; Conclusion='PnP device currently reports no active configuration error.' }
    }

    return [pscustomobject]@{
        State='NeedsMoreEvidence'
        Conclusion=('PnP device reports configuration error code {0}; more evidence is required.' -f $code)
    }
}


function Get-PnPInvestigationCandidates {
    param($Findings)

    $out = @()
    $pnpFindings = @($Findings | Where-Object {
        ($_.ProblemType -eq 'PnP') -or
        ($_.Category -eq 'PnP') -or
        ([string]$_.Details -match 'ConfigManagerErrorCode\s*[:=]?\s*28') -or
        ([string]$_.Details -match 'Code\s*28') -or
        ([string]$_.Details -match 'ACPI\\LEN0068')
    })

    foreach ($f in $pnpFindings) {
        $pid = Get-PnPProblemId -Finding $f
        if (-not $pid) { continue }
        $iid = Get-PnPInstanceIdFromProblemId -ProblemId $pid
        $sev = if ($f.Severity) { [string]$f.Severity } else { 'ACTION' }

        $out += [pscustomobject]@{
            ProblemId=$pid; ProblemType='PnP'; Severity=$sev
            Hypothesis='An active device configuration error may be caused by a missing or mismatched driver.'
            Action='GetPnPProblemContext'; Parameters=@{InstanceId=$iid}; Priority=5
        }
        $out += [pscustomobject]@{
            ProblemId=$pid; ProblemType='PnP'; Severity=$sev
            Hypothesis='Hardware IDs should be correlated with installed signed drivers before any repair is proposed.'
            Action='GetPnPRelatedDriverContext'; Parameters=@{InstanceId=$iid}; Priority=6
        }
    }
    return $out
}


function Get-HPFocusedInvestigationCandidates {
    param($Findings)

    $out = @()

    $hasPower = @($Findings | Where-Object {
        ([string]$_.ProblemId -eq 'Power:UnexpectedShutdown') -or
        ([string]$_.Title -match 'shutdown|Kernel-Power') -or
        ([string]$_.Details -match 'Kernel-Power|6008|unexpected shutdown')
    }).Count -gt 0
    if ($hasPower) {
        $out += [pscustomobject]@{
            ProblemId='Power:UnexpectedShutdown'; ProblemType='Power'; Severity='ACTION'
            Hypothesis='Unexpected shutdowns should be reconstructed as a timeline before any repair is considered.'
            Action='GetPowerEventTimeline'; Parameters=@{}; Priority=10
        }
    }

    $hasDisk = @($Findings | Where-Object {
        ([string]$_.ProblemId -eq 'Storage:HistoricalBadBlock') -or
        ([string]$_.Title -match 'bad.block|disk') -or
        ([string]$_.Details -match 'bad block|Harddisk[0-9]+')
    }).Count -gt 0
    if ($hasDisk) {
        $out += [pscustomobject]@{
            ProblemId='Storage:HistoricalBadBlock'; ProblemType='Storage'; Severity='CRITICAL'
            Hypothesis='Historical storage errors should be correlated with recent storage events and current disk identity without assuming HarddiskN mapping.'
            Action='GetDiskEventContext'; Parameters=@{}; Priority=5
        }
    }

    $hasWifi = @($Findings | Where-Object {
        ([string]$_.ProblemId -eq 'Network:IntelAX201') -or
        ([string]$_.Title -match 'Wi-Fi|Netwtw') -or
        ([string]$_.Details -match 'Netwtw|AX201')
    }).Count -gt 0
    if ($hasWifi) {
        $out += [pscustomobject]@{
            ProblemId='Network:IntelAX201'; ProblemType='Network'; Severity='WARNING'
            Hypothesis='Historical Intel Wi-Fi faults should be compared with the recent Netwtw/NDIS timeline and current adapter state.'
            Action='GetWifiErrorTimeline'; Parameters=@{}; Priority=20
        }
    }

    $hasWbf = @($Findings | Where-Object {
        ([string]$_.ProblemId -eq 'Service:WbfPolicyService110') -or
        ([string]$_.Details -match 'WbfPolicyService110') -or
        ([string]$_.Title -match 'WbfPolicyService110')
    }).Count -gt 0
    if ($hasWbf) {
        $out += [pscustomobject]@{
            ProblemId='Service:WbfPolicyService110'; ProblemType='Service'; Severity='INFO'
            Hypothesis='The biometric policy service failed a previous safe start attempt; inspect trigger/dependency/configuration evidence before any retry.'
            Action='GetServiceConfigurationContext'; Parameters=@{Name='WbfPolicyService110'}; Priority=30
        }
    }

    return $out
}


function Get-IncidentSubsystemScores {
    param($Events)

    $scores = [ordered]@{
        Storage = 0
        Network = 0
        Hardware = 0
        Power = 0
        PlannedShutdown = 0
    }

    foreach ($e in @($Events)) {
        $provider = [string]$e.ProviderName
        $id = [int]$e.Id

        if ($provider -match 'Disk|Ntfs|StorPort|stornvme|storahci') {
            $scores.Storage += 2
            if ($id -in 7,50,51,55,153) { $scores.Storage += 2 }
        }
        if ($provider -match 'Netwtw|WLAN|NDIS') {
            $scores.Network += 1
            if ($id -in 5010,6062,7021,7025,7026) { $scores.Network += 1 }
        }
        if ($provider -match 'WHEA') {
            $scores.Hardware += 5
        }
        if ($provider -eq 'Microsoft-Windows-Kernel-Power' -and $id -eq 41) {
            $scores.Power += 3
        }
        if ($provider -eq 'EventLog' -and $id -eq 6008) {
            $scores.Power += 2
        }
        if ($provider -eq 'USER32' -and $id -eq 1074) {
            $scores.PlannedShutdown += 6
        }
    }

    return [pscustomobject]$scores
}

function Get-IncidentReasoning {
    param($AgentSteps)

    $out = @()
    $corrSteps = @($AgentSteps | Where-Object { $_.Action -eq 'GetEventCorrelationWindow' })

    foreach ($step in $corrSteps) {
        $kind = [string]$step.Data.Kind
        foreach ($incident in @($step.Data.Incidents)) {
            $anchorTime = [datetime]$incident.AnchorTime
            $related = @($incident.Related | Sort-Object TimeCreated)

            $before = @()
            $trigger = @()
            $after = @()

            if ($kind -eq 'Power') {
                # Power incidents: strict phase separation prevents boot-time driver
                # initialization from being mistaken for pre-crash evidence.
                $before = @($related | Where-Object {
                    ([datetime]$_.TimeCreated) -lt $anchorTime -and
                    ($anchorTime - ([datetime]$_.TimeCreated)).TotalMinutes -le 5
                })
                $trigger = @($related | Where-Object {
                    [math]::Abs((([datetime]$_.TimeCreated) - $anchorTime).TotalSeconds) -le 3
                })
                $after = @($related | Where-Object {
                    ([datetime]$_.TimeCreated) -gt $anchorTime -and
                    ((([datetime]$_.TimeCreated) - $anchorTime).TotalMinutes) -le 2
                })
            } else {
                $windowSeconds = if ($kind -eq 'WiFi') { 30 } else { 20 }
                $before = @($related | Where-Object {
                    ([datetime]$_.TimeCreated) -lt $anchorTime -and
                    ($anchorTime - ([datetime]$_.TimeCreated)).TotalSeconds -le $windowSeconds
                })
                $trigger = @($related | Where-Object {
                    [math]::Abs((([datetime]$_.TimeCreated) - $anchorTime).TotalSeconds) -le 1
                })
                $after = @($related | Where-Object {
                    ([datetime]$_.TimeCreated) -gt $anchorTime -and
                    ((([datetime]$_.TimeCreated) - $anchorTime).TotalSeconds) -le $windowSeconds
                })
            }

            $scores = Get-IncidentSubsystemScores -Events $before

            $pairs = @(
                [pscustomobject]@{Name='Storage';Score=[int]$scores.Storage},
                [pscustomobject]@{Name='Network';Score=[int]$scores.Network},
                [pscustomobject]@{Name='Hardware';Score=[int]$scores.Hardware},
                [pscustomobject]@{Name='Power';Score=[int]$scores.Power},
                [pscustomobject]@{Name='PlannedShutdown';Score=[int]$scores.PlannedShutdown}
            ) | Sort-Object Score -Descending

            $top = $pairs[0]
            $likely = 'Unknown'
            $confidence = 'Low'
            $reason = 'No strong pre-trigger subsystem evidence.'

            if ($kind -eq 'Power') {
                if ([int]$scores.PlannedShutdown -ge 6) {
                    $likely='PlannedShutdown'; $confidence='High'
                    $reason='A planned USER32 shutdown event exists before the restart marker.'
                } elseif ([int]$scores.Hardware -ge 5) {
                    $likely='Hardware'; $confidence='High'
                    $reason='WHEA evidence exists before the restart marker.'
                } elseif ([int]$top.Score -ge 6) {
                    $likely=$top.Name; $confidence='Medium'
                    $reason='Multiple pre-trigger events point to the same subsystem.'
                } elseif ([int]$top.Score -ge 3) {
                    $likely=$top.Name; $confidence='Low'
                    $reason='Some pre-trigger evidence exists, but it is not sufficient to claim causation.'
                }
            } elseif ($kind -eq 'Storage') {
                if ([int]$scores.Storage -ge 4) {
                    $likely='Storage'; $confidence='Medium'
                    $reason='Multiple storage events occur in the same short incident window.'
                }
            } elseif ($kind -eq 'WiFi') {
                if ([int]$scores.Network -ge 2) {
                    $likely='Network'; $confidence='Medium'
                    $reason='Repeated Intel/WLAN/NDIS events occur in the same short incident window.'
                }
            }

            $out += [pscustomobject]@{
                IncidentType=$kind
                AnchorTime=$anchorTime
                AnchorProvider=$incident.AnchorProvider
                AnchorId=$incident.AnchorId
                EvidenceBefore=@($before)
                Trigger=@($trigger)
                EvidenceAfter=@($after)
                LikelySubsystem=$likely
                Confidence=$confidence
                Reason=$reason
                Scores=$scores
                CausationProven=$false
                Note='Confidence is heuristic. Temporal proximity and subsystem scoring do not prove root cause.'
            }
        }
    }

    return $out
}


function Get-HypothesisRank {
    param($Incident)

    $hypotheses = @()
    $scores = $Incident.Scores
    $before = @($Incident.EvidenceBefore)

    if ($Incident.IncidentType -eq 'Power') {
        $planned = @($before | Where-Object { $_.ProviderName -eq 'USER32' -and [int]$_.Id -eq 1074 })
        $whea = @($before | Where-Object { [string]$_.ProviderName -match 'WHEA' })
        $storage = @($before | Where-Object {
            [string]$_.ProviderName -match 'Disk|Ntfs|StorPort|stornvme|storahci'
        })
        $network = @($before | Where-Object {
            [string]$_.ProviderName -match 'Netwtw|WLAN|NDIS'
        })

        if ($planned.Count -gt 0) {
            $hypotheses += [pscustomobject]@{
                Rank=0; Hypothesis='PlannedShutdown'; Score=100; Confidence='High'
                SupportingEvidence=@($planned)
                ContradictingEvidence=@()
                NextDiagnosticAction='NoneRequired'
                Reason='USER32 event 1074 exists before the restart marker.'
            }
        }
        if ($whea.Count -gt 0) {
            $hypotheses += [pscustomobject]@{
                Rank=0; Hypothesis='Hardware'; Score=90; Confidence='High'
                SupportingEvidence=@($whea)
                ContradictingEvidence=@()
                NextDiagnosticAction='InspectWheaDetails'
                Reason='WHEA evidence exists before the restart marker.'
            }
        }
        if ($storage.Count -gt 0) {
            $hypotheses += [pscustomobject]@{
                Rank=0; Hypothesis='Storage'; Score=(40 + [math]::Min(30,$storage.Count*5)); Confidence='Medium'
                SupportingEvidence=@($storage)
                ContradictingEvidence=@()
                NextDiagnosticAction='MapStorageEventsToPhysicalDevice'
                Reason='Storage warnings/errors exist in the pre-restart window.'
            }
        }
        if ($network.Count -gt 0) {
            $hypotheses += [pscustomobject]@{
                Rank=0; Hypothesis='Network'; Score=(20 + [math]::Min(20,$network.Count*3)); Confidence='Low'
                SupportingEvidence=@($network)
                ContradictingEvidence=@()
                NextDiagnosticAction='CompareNetworkEventsAcrossStableBoots'
                Reason='Network events exist before restart, but temporal proximity alone is weak causal evidence.'
            }
        }
        if ($hypotheses.Count -eq 0) {
            $hypotheses += [pscustomobject]@{
                Rank=0; Hypothesis='Unknown'; Score=10; Confidence='Low'
                SupportingEvidence=@()
                ContradictingEvidence=@()
                NextDiagnosticAction='CollectPreCrashContext'
                Reason='No strong subsystem evidence exists before the restart marker.'
            }
        }
    }
    elseif ($Incident.IncidentType -eq 'WiFi') {
        $ev = @($Incident.EvidenceBefore + $Incident.Trigger + $Incident.EvidenceAfter | Where-Object {
            [string]$_.ProviderName -match 'Netwtw|WLAN|NDIS'
        })
        $hypotheses += [pscustomobject]@{
            Rank=0; Hypothesis='IntelWifiDriverReset'; Score=(50 + [math]::Min(30,$ev.Count*2)); Confidence='Medium'
            SupportingEvidence=@($ev)
            ContradictingEvidence=@()
            NextDiagnosticAction='CompareWifiIncidentSignatures'
            Reason='Repeated Netwtw/WLAN/NDIS events form a short reset/error sequence.'
        }
    }
    elseif ($Incident.IncidentType -eq 'Storage') {
        $ev = @($Incident.EvidenceBefore + $Incident.Trigger + $Incident.EvidenceAfter | Where-Object {
            [string]$_.ProviderName -match 'Disk|Ntfs|StorPort|stornvme|storahci'
        })
        $hypotheses += [pscustomobject]@{
            Rank=0; Hypothesis='StorageIoIncident'; Score=(45 + [math]::Min(35,$ev.Count*3)); Confidence='Medium'
            SupportingEvidence=@($ev)
            ContradictingEvidence=@()
            NextDiagnosticAction='MapStorageEventsToPhysicalDevice'
            Reason='Disk/NTFS/storage events occur in the same short incident window.'
        }
    }

    $sorted = @($hypotheses | Sort-Object Score -Descending)
    for ($i=0; $i -lt $sorted.Count; $i++) {
        $sorted[$i].Rank = $i + 1
    }
    return $sorted
}

function Get-CanonicalIncidentKey {
    param($Incident)

    $t = [datetime]$Incident.AnchorTime
    if ($Incident.IncidentType -eq 'Power') {
        # Kernel-Power 41 and EventLog 6008 from the same restart episode may
        # be separated by startup processing. Bucket conservatively by 10 min.
        $ticks = [math]::Floor($t.Ticks / [timespan]::FromMinutes(10).Ticks)
        return "Power|$ticks"
    }

    if ($Incident.IncidentType -eq 'WiFi') {
        $ticks = [math]::Floor($t.Ticks / [timespan]::FromSeconds(45).Ticks)
        return "WiFi|$ticks"
    }

    if ($Incident.IncidentType -eq 'Storage') {
        $ticks = [math]::Floor($t.Ticks / [timespan]::FromSeconds(30).Ticks)
        return "Storage|$ticks"
    }

    return "$($Incident.IncidentType)|$($t.ToString('o'))"
}

function Get-CanonicalIncidents {
    param($ReasonedIncidents)

    $canonical = @()
    $groups = @($ReasonedIncidents | Group-Object { Get-CanonicalIncidentKey $_ })

    foreach ($g in $groups) {
        $members = @($g.Group | Sort-Object AnchorTime)
        if ($members.Count -eq 0) { continue }

        $type = [string]$members[0].IncidentType
        $before = @($members | ForEach-Object { $_.EvidenceBefore } | Sort-Object TimeCreated -Unique)
        $trigger = @($members | ForEach-Object { $_.Trigger } | Sort-Object TimeCreated -Unique)
        $after = @($members | ForEach-Object { $_.EvidenceAfter } | Sort-Object TimeCreated -Unique)

        $merged = [pscustomobject]@{
            CanonicalId=("{0}:{1}" -f $type,([datetime]$members[0].AnchorTime).ToString('yyyyMMddTHHmmss'))
            IncidentType=$type
            StartTime=[datetime]$members[0].AnchorTime
            EndTime=[datetime]$members[-1].AnchorTime
            MarkerCount=$members.Count
            SourceMarkers=@($members | ForEach-Object {
                [pscustomobject]@{
                    AnchorTime=$_.AnchorTime
                    Provider=$_.AnchorProvider
                    Id=$_.AnchorId
                }
            })
            EvidenceBefore=$before
            Trigger=$trigger
            EvidenceAfter=$after
            CausationProven=$false
        }

        # Reuse the same hypothesis ranker by exposing the expected shape.
        $rankInput = [pscustomobject]@{
            IncidentType=$merged.IncidentType
            AnchorTime=$merged.StartTime
            EvidenceBefore=$merged.EvidenceBefore
            Trigger=$merged.Trigger
            EvidenceAfter=$merged.EvidenceAfter
            Scores=$null
        }
        $ranked = @(Get-HypothesisRank -Incident $rankInput)
        $top = if ($ranked.Count -gt 0) { $ranked[0] } else { $null }

        $canonical += [pscustomobject]@{
            CanonicalId=$merged.CanonicalId
            IncidentType=$merged.IncidentType
            StartTime=$merged.StartTime
            EndTime=$merged.EndTime
            MarkerCount=$merged.MarkerCount
            SourceMarkers=$merged.SourceMarkers
            EvidenceBefore=$merged.EvidenceBefore
            Trigger=$merged.Trigger
            EvidenceAfter=$merged.EvidenceAfter
            RankedHypotheses=$ranked
            TopHypothesis=if($top){$top.Hypothesis}else{'Unknown'}
            Confidence=if($top){$top.Confidence}else{'Low'}
            RecommendedNextDiagnosticAction=if($top){$top.NextDiagnosticAction}else{'CollectMoreEvidence'}
            CausationProven=$false
            Note='Canonical incident is deduplicated by time bucket. Ranking is heuristic and does not prove root cause.'
        }
    }

    return @($canonical | Sort-Object StartTime)
}

function Invoke-AgentLoop {
    param(
        [Parameter(Mandatory=$true)]$Findings,
        [int]$MaxIterations = 20
    )

    $steps = @()
    $candidates = @(Get-InitialAgentCandidates -Findings $Findings)

    $candidates += @(Get-PnPInvestigationCandidates -Findings $Findings)
    $seen = @{}
    $iteration = 0
    $problemStates = @{}

    foreach ($candidate in $candidates) {
        if ($iteration -ge $MaxIterations) { break }

        # Normalize candidates from every generator (including legacy PnP generator).
        if (-not ($candidate.PSObject.Properties.Name -contains 'Key') -or [string]::IsNullOrWhiteSpace([string]$candidate.Key)) {
            $candidate | Add-Member -NotePropertyName Key -NotePropertyValue (Get-ActionKey $candidate.ProblemId $candidate.Action $candidate.Parameters) -Force
        }

        if ($seen.ContainsKey($candidate.Key)) { continue }

        $seen[$candidate.Key] = $true
        $iteration++

        Write-Host ""
        Write-Host ("[Agent {0}/{1}] [{2}] {3}" -f $iteration,$MaxIterations,$candidate.ProblemId,$candidate.Hypothesis)
        Write-Host ("Broker action: {0}" -f $candidate.Action)

        $brokerResult = Invoke-DiagnosticBroker -Action $candidate.Action -Parameters $candidate.Parameters
        $conclusion = Get-AgentConclusion -Action $candidate.Action -BrokerResult $brokerResult
        $state = Get-ProblemState -ProblemId $candidate.ProblemId -Action $candidate.Action -BrokerResult $brokerResult

        # Combine sequential evidence for the same problem.
        # NeedsMoreEvidence is provisional: a later targeted check may refine
        # it to Monitor/HealthyNow/Explained. ActionCandidate is sticky unless
        # a repair+verification cycle explicitly changes it later.
        if ($problemStates.ContainsKey($candidate.ProblemId)) {
            $old = [string]$problemStates[$candidate.ProblemId].State

            if ($old -eq 'ActionCandidate') {
                # Keep actionable state until an explicit verified repair.
            }
            elseif ($state -eq 'ActionCandidate') {
                $problemStates[$candidate.ProblemId].State = $state
            }
            elseif ($old -eq 'NeedsMoreEvidence' -and $state -ne 'NeedsMoreEvidence') {
                $problemStates[$candidate.ProblemId].State = $state
            }
            elseif ($old -eq 'HealthyNow' -and $state -eq 'Monitor') {
                $problemStates[$candidate.ProblemId].State = 'Monitor'
            }
            elseif ($state -eq 'Explained') {
                $problemStates[$candidate.ProblemId].State = 'Explained'
            }
        } else {
            $problemStates[$candidate.ProblemId] = [pscustomobject]@{
                ProblemId = $candidate.ProblemId
                ProblemType = $candidate.ProblemType
                Severity = $candidate.Severity
                State = $state
                EvidenceActions = @()
                LastConclusion = ""
            }
        }

        $problemStates[$candidate.ProblemId].EvidenceActions += $candidate.Action
        $problemStates[$candidate.ProblemId].LastConclusion = $conclusion

        Write-Host ("Result: {0}" -f $conclusion)
        Write-Host ("Problem state: {0}" -f $problemStates[$candidate.ProblemId].State)

        $steps += New-AgentStep `
            -Iteration $iteration `
            -ProblemId $candidate.ProblemId `
            -ProblemType $candidate.ProblemType `
            -Severity $candidate.Severity `
            -Hypothesis $candidate.Hypothesis `
            -Action $candidate.Action `
            -Parameters $candidate.Parameters `
            -BrokerResult $brokerResult `
            -Conclusion $conclusion `
            -ProblemState $problemStates[$candidate.ProblemId].State
    }

    $problems = @($problemStates.Values | Sort-Object `
        @{Expression={Get-ProblemRank $_.State};Ascending=$true},
        @{Expression={
            switch ($_.Severity) {
                'CRITICAL' { 0 }
                'ACTION' { 1 }
                'WARNING' { 2 }
                'INFO' { 3 }
                'NOISE' { 4 }
                default { 9 }
            }
        };Ascending=$true},
        ProblemId)

    $repairCandidates = @(Get-RepairCandidates -Problems $problems)

    [pscustomobject]@{
        Mode = 'RootCauseRankingAgent'
        ArbitraryShell = $false
        MaxIterations = $MaxIterations
        CompletedIterations = $steps.Count
        CandidateCount = $candidates.Count
        ProblemCount = $problems.Count
        RepairCandidateCount = $repairCandidates.Count
        Problems = $problems
        RepairCandidates = $repairCandidates
        Steps = $steps
    }
}

Export-ModuleMember -Function *
