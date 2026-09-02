function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ==="
}

function Invoke-Safely {
    param(
        [scriptblock]$Script,
        [string]$Name
    )
    try {
        $data = & $Script
        [pscustomobject]@{
            Name = $Name
            Ok = $true
            Data = $data
            Error = $null
        }
    } catch {
        [pscustomobject]@{
            Name = $Name
            Ok = $false
            Data = $null
            Error = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function Test-IsAdmin,Write-Section,Invoke-Safely
