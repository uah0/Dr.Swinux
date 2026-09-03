$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Replace-ExactlyOnce([string]$Path,[string]$Old,[string]$New) {
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $count=([regex]::Matches($text,[regex]::Escape($Old))).Count
    if($count -ne 1){throw "Expected exactly one match in $Path, found $count"}
    Set-Content -LiteralPath $Path -Value ($text.Replace($Old,$New)) -Encoding UTF8 -NoNewline
}
$broker='system/Privileged-Broker.ps1'
$marker="function Get-WingetPath {"
$bootstrap=@'
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
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Write-BrokerLog 'WINGET_BOOTSTRAP_REGISTER_BY_FAMILY_OK'
    } catch {
        Write-BrokerLog ("WINGET_BOOTSTRAP_REGISTER_BY_FAMILY_SKIPPED error={0}" -f $_.Exception.Message)
    }
    if(Test-WingetReady){
        $path=Get-WingetPath
        Write-BrokerLog ("WINGET_BOOTSTRAP_READY method=RegisterByFamilyName path={0}" -f $path)
        return [pscustomobject]@{Confirmed=$true;Changed=$true;Ready=$true;Method='RegisterByFamilyName';Path=$path}
    }
    $bundle=Join-Path $brokerRoot 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    try {
        Write-BrokerLog 'WINGET_BOOTSTRAP_DOWNLOAD_BEGIN source=https://aka.ms/getwinget'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        if(-not (Test-Path -LiteralPath $bundle -PathType Leaf)){throw 'App Installer download did not create a file.'}
        $length=(Get-Item -LiteralPath $bundle).Length
        if($length -lt 1MB){throw ("Downloaded App Installer bundle is unexpectedly small: {0} bytes." -f $length)}
        Write-BrokerLog ("WINGET_BOOTSTRAP_DOWNLOAD_OK bytes={0}" -f $length)
        Add-AppxPackage -Path $bundle -ForceApplicationShutdown -ErrorAction Stop
        Write-BrokerLog 'WINGET_BOOTSTRAP_ADD_APPX_OK'
    } finally {
        Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
    }
    try {Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction SilentlyContinue} catch {}
    if(-not (Test-WingetReady)){throw 'Microsoft App Installer was installed/registered, but winget is still unavailable.'}
    $package=Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if($null -eq $package){throw 'winget became available but Microsoft.DesktopAppInstaller package verification failed.'}
    $publisher=[string]$package.Publisher
    if($publisher -notmatch '(?i)Microsoft Corporation'){throw ("Unexpected App Installer publisher: {0}" -f $publisher)}
    $path=Get-WingetPath
    Write-BrokerLog ("WINGET_BOOTSTRAP_READY method=OfficialMicrosoftBundle version={0} path={1}" -f $package.Version,$path)
    [pscustomobject]@{Confirmed=$true;Changed=$true;Ready=$true;Method='OfficialMicrosoftBundle';Path=$path;Version=[string]$package.Version;Publisher=$publisher}
}

function Get-WingetPath {
'@
Replace-ExactlyOnce $broker $marker $bootstrap
$old="        'GetInstalledPackages' {"
$new="        'EnsureWinget' { return Ensure-Winget }`n        'GetInstalledPackages' {"
Replace-ExactlyOnce $broker $old $new
$old="        'GetScheduledTaskSnapshot','GetRegistryRead','GetInstalledPackages','SearchPackage',"
$new="        'GetScheduledTaskSnapshot','GetRegistryRead','EnsureWinget','GetInstalledPackages','SearchPackage',"
Replace-ExactlyOnce $broker $old $new
$client='system/Broker-Request.ps1'
Replace-ExactlyOnce $client $old $new
$agent='system/Start-Agent.ps1'
Replace-ExactlyOnce $agent $old $new
$old="- Use the broker's typed winget actions instead of arbitrary installer commands: GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage."
$new="- Use the broker's typed winget actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage."
Replace-ExactlyOnce $agent $old $new
$old="- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id."
$new="- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget. EnsureWinget shows its own broker-owned Yes/No confirmation before any repair/download/install and only uses the official Microsoft App Installer source.`n- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id."
Replace-ExactlyOnce $agent $old $new
Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.44-final' -Encoding UTF8
$parseErrors=@()
Get-ChildItem system -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){$parseErrors += $errors}
}
if($parseErrors){$parseErrors | ForEach-Object {Write-Error $_};throw 'PowerShell parser audit failed'}
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/Start-Agent.ps1 system/VERSION.txt
git commit -m 'Add confirmed WinGet bootstrap capability'
git push
