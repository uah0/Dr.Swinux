$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-RegexOnce([string]$Path,[string]$Pattern,[string]$Replacement){
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $rx=[regex]::new($Pattern,[Text.RegularExpressions.RegexOptions]::Singleline)
    $m=$rx.Matches($text)
    if($m.Count -ne 1){throw "Expected one match in $Path, found $($m.Count)"}
    $updated=$rx.Replace($text,$Replacement,1)
    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
$newWinget=@'
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
'@
Replace-RegexOnce $broker 'function Confirm-WingetBootstrap \{.*?function Get-WingetPath \{' $newWinget

$client='system/Broker-Request.ps1'
$text=Get-Content $client -Raw -Encoding UTF8
$old=@'
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding UTF8
'@
$new=@'
$requestTempPath=$requestPath+'.tmp'
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestTempPath -Encoding UTF8
Move-Item -LiteralPath $requestTempPath -Destination $requestPath -Force
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Broker request publication marker mismatch'}
Set-Content $client -Value $text.Replace($old,$new) -Encoding UTF8 -NoNewline

Set-Content 'system/VERSION.txt' 'Dr.Swinux v1.5.48-final' -Encoding UTF8

$parseErrors=@(); Get-ChildItem system -Recurse -Filter '*.ps1' | ForEach-Object {$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e);if($e){$parseErrors+=$e}}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}
$bt=Get-Content $broker -Raw -Encoding UTF8
foreach($needle in @('Get-WindowsPowerShellPath','Invoke-WindowsPowerShellAppx','RegisterDesktopAppInstaller','OfficialMicrosoftBundleWindowsPowerShell')){if($bt-notmatch[regex]::Escape($needle)){throw "Missing broker fix: $needle"}}
if($bt-match '(?m)^\s*Add-AppxPackage '){throw 'Direct PowerShell 7 Add-AppxPackage call remains in broker'}
$ct=Get-Content $client -Raw -Encoding UTF8
if($ct-notmatch [regex]::Escape('$requestTempPath=$requestPath+''.tmp''')){throw 'Atomic request temp path missing'}
if($ct-notmatch 'Move-Item -LiteralPath \$requestTempPath -Destination \$requestPath -Force'){throw 'Atomic request move missing'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/VERSION.txt
git commit -m 'Fix AppX host compatibility and broker request race'
git push
