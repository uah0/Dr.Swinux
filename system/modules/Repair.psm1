function Invoke-SafeRepairs {
    Write-Host ""
    Write-Host "Safe repair menu:"
    Write-Host "  [1] Start Print Spooler if it is stopped"
    Write-Host "  [2] Delete user TEMP items older than 7 days"
    Write-Host "  [0] Do nothing"

    $choice = Read-Host "Select action"

    switch ($choice) {
        '1' {
            $svc = Get-Service Spooler -ErrorAction SilentlyContinue
            if (-not $svc) {
                Write-Host "Spooler service was not found."
                return
            }
            if ($svc.Status -eq 'Running') {
                Write-Host "Spooler is already running."
                return
            }

            $confirm = Read-Host "Start Spooler? (yes/no)"
            if ($confirm -eq 'yes') {
                try {
                    Start-Service Spooler -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $after = Get-Service Spooler
                    Write-Host "Current status: $($after.Status)"
                } catch {
                    Write-Host "Error: $($_.Exception.Message)"
                }
            }
        }

        '2' {
            $confirm = Read-Host "Delete TEMP items older than 7 days from $env:TEMP ? (yes/no)"
            if ($confirm -eq 'yes') {
                $cutoff = (Get-Date).AddDays(-7)
                $items = Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff }

                $count = 0
                foreach ($item in $items) {
                    try {
                        Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                        $count++
                    } catch {}
                }

                Write-Host "Deleted objects: $count"
            }
        }

        default {
            Write-Host "No repairs were performed."
        }
    }
}

Export-ModuleMember -Function Invoke-SafeRepairs
