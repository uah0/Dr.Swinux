
function Get-AgentToolDefinitions {
    return @(
        @{
            type='function'; name='get_system_snapshot'
            description='Inspect OS, hardware model, boot time, memory and CPU summary.'
            strict=$true
            parameters=@{type='object';properties=@{};additionalProperties=$false}
        },
        @{
            type='function'; name='get_volumes'
            description='Inspect local fixed-volume capacity, used space and free space.'
            strict=$true
            parameters=@{type='object';properties=@{};additionalProperties=$false}
        },
        @{
            type='function'; name='inspect_path'
            description='Inspect one filesystem path. For directories, returns largest immediate children by recursively measured size. Use this iteratively to drill into suspicious locations.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{
                    path=@{type='string';description='Absolute local Windows path, for example C:\Users.'}
                    top=@{type='integer';minimum=1;maximum=100}
                }
                required=@('path','top')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='find_large_files'
            description='Find the largest files under a local path. Use only after narrowing the search area when possible.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{
                    path=@{type='string'}
                    top=@{type='integer';minimum=1;maximum=100}
                    min_size_mb=@{type='integer';minimum=1;maximum=1048576}
                }
                required=@('path','top','min_size_mb')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='get_file_metadata'
            description='Inspect metadata and version information for one existing file or directory. Does not read file contents.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{path=@{type='string'}}
                required=@('path')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='get_process_snapshot'
            description='Inspect running processes, memory usage and accumulated CPU time.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{
                    top=@{type='integer';minimum=1;maximum=100}
                    sort_by=@{type='string';enum=@('WorkingSet','CPU')}
                }
                required=@('top','sort_by')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='get_services'
            description='Inspect Windows services. Optionally narrow by a case-insensitive substring in service or display name.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{
                    name_contains=@{type='string'}
                    top=@{type='integer';minimum=1;maximum=200}
                }
                required=@('name_contains','top')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='get_pnp_problems'
            description='Inspect devices currently reporting a Windows Plug and Play configuration error.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{top=@{type='integer';minimum=1;maximum=200}}
                required=@('top')
                additionalProperties=$false
            }
        },
        @{
            type='function'; name='get_network_snapshot'
            description='Inspect current network adapters, link state, driver information and IP configuration.'
            strict=$true
            parameters=@{type='object';properties=@{};additionalProperties=$false}
        },
        @{
            type='function'; name='query_event_log'
            description='Read a bounded slice of the Windows System or Application event log. Use hypotheses to choose provider text, IDs and time window instead of dumping the whole log.'
            strict=$true
            parameters=@{
                type='object'
                properties=@{
                    log_name=@{type='string';enum=@('System','Application')}
                    days=@{type='integer';minimum=1;maximum=30}
                    provider_contains=@{type='string'}
                    ids=@{type='array';items=@{type='integer'};maxItems=12}
                    max_events=@{type='integer';minimum=1;maximum=200}
                }
                required=@('log_name','days','provider_contains','ids','max_events')
                additionalProperties=$false
            }
        }
    )
}

function Invoke-AgentTool {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)]$Arguments
    )

    switch($Name){
        'get_system_snapshot' {
            return Invoke-DiagnosticBroker -Action 'GetSystemSnapshot' -Parameters @{}
        }
        'get_volumes' {
            return Invoke-DiagnosticBroker -Action 'GetVolumeUsage' -Parameters @{}
        }
        'inspect_path' {
            return Invoke-DiagnosticBroker -Action 'GetPathSummary' -Parameters @{
                Path=[string]$Arguments.path
                Top=[int]$Arguments.top
            }
        }
        'find_large_files' {
            return Invoke-DiagnosticBroker -Action 'GetLargestFiles' -Parameters @{
                Path=[string]$Arguments.path
                Top=[int]$Arguments.top
                MinSizeMB=[int]$Arguments.min_size_mb
            }
        }
        'get_file_metadata' {
            return Invoke-DiagnosticBroker -Action 'GetFileMetadata' -Parameters @{
                Path=[string]$Arguments.path
            }
        }
        'get_process_snapshot' {
            return Invoke-DiagnosticBroker -Action 'GetProcessSnapshot' -Parameters @{
                Top=[int]$Arguments.top
                SortBy=[string]$Arguments.sort_by
            }
        }
        'get_services' {
            return Invoke-DiagnosticBroker -Action 'GetServiceSnapshot' -Parameters @{
                NameContains=[string]$Arguments.name_contains
                Top=[int]$Arguments.top
            }
        }
        'get_pnp_problems' {
            return Invoke-DiagnosticBroker -Action 'GetPnPProblems' -Parameters @{
                Top=[int]$Arguments.top
            }
        }
        'get_network_snapshot' {
            return Invoke-DiagnosticBroker -Action 'GetNetworkSnapshot' -Parameters @{}
        }
        'query_event_log' {
            return Invoke-DiagnosticBroker -Action 'GetEventLogSlice' -Parameters @{
                LogName=[string]$Arguments.log_name
                Days=[int]$Arguments.days
                ProviderContains=[string]$Arguments.provider_contains
                Ids=[int[]]$Arguments.ids
                MaxEvents=[int]$Arguments.max_events
            }
        }
        default {
            return New-BrokerResult -Allowed $false -Action $Name -ExitCode 126 -Data $null `
                -ErrorText 'Unknown model tool.' -Verification 'Denied before execution.'
        }
    }
}

Export-ModuleMember -Function Get-AgentToolDefinitions,Invoke-AgentTool
