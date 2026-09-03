$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Insert-BeforeExactlyOnce([string]$Path,[string]$Marker,[string]$Insert) {
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $first=$text.IndexOf($Marker,[StringComparison]::Ordinal)
    if($first -lt 0){throw "Marker not found in $Path: $Marker"}
    $second=$text.IndexOf($Marker,$first+$Marker.Length,[StringComparison]::Ordinal)
    if($second -ge 0){throw "Marker occurs more than once in $Path: $Marker"}
    $newText=$text.Substring(0,$first)+$Insert+$text.Substring($first)
    Set-Content -LiteralPath $Path -Value $newText -Encoding UTF8 -NoNewline
}

function Replace-ExactlyOnce([string]$Path,[string]$Old,[string]$New) {
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $first=$text.IndexOf($Old,[StringComparison]::Ordinal)
    if($first -lt 0){throw "Text not found in $Path: $Old"}
    $second=$text.IndexOf($Old,$first+$Old.Length,[StringComparison]::Ordinal)
    if($second -ge 0){throw "Text occurs more than once in $Path: $Old"}
    $newText=$text.Substring(0,$first)+$New+$text.Substring($first+$Old.Length)
    Set-Content -LiteralPath $Path -Value $newText -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
$fallback=@'
function Get-TrustedPackageDefinition {
    param([string]$Id)
    Assert-PackageId -Id $Id
    switch($Id.ToLowerInvariant()){
        '7zip.7zip' {
            return [pscustomobject]@{
                Id='7zip.7zip'
                DisplayName='7-Zip 26.02 (x64)'
                Url='https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.exe'
                FileName='7z2602-x64.exe'
                SignerPattern='(?i)Igor Pavlov'
                InstallerArguments=@('/S')
                VerifyPath=(Join-Path $env:ProgramFiles '7-Zip\7z.exe')
                MinFileBytes=1000000
            }
        }
        default { throw ("Package is not in the Dr.Swinux trusted direct-install allowlist: {0}" -f $Id) }
    }
}

function Confirm-TrustedPackageInstall {
    param($Definition)
    $message="Установить программу напрямую из доверенного источника?`r`n`r`nНазвание: $($Definition.DisplayName)`r`nPackage ID: $($Definition.Id)`r`nИсточник: $($Definition.Url)`r`n`r`nDr.Swinux проверит цифровую подпись перед запуском установщика.`r`nДействие будет выполнено с правами администратора."
    Write-BrokerLog ("TRUSTED_PACKAGE_CONFIRM_DIALOG_SHOW id={0}" -f $Definition.Id)
    Initialize-BrokerMessageBox
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swinux',$flags)
    if($answer -eq 6){Write-BrokerLog ("TRUSTED_PACKAGE_CONFIRM_USER_YES id={0}" -f $Definition.Id);return $true}
    Write-BrokerLog ("TRUSTED_PACKAGE_CONFIRM_USER_NO id={0} result={1}" -f $Definition.Id,$answer)
    return $false
}

function Install-TrustedPackageFallback {
    param([string]$Id)
    $definition=Get-TrustedPackageDefinition -Id $Id
    if(-not [Environment]::Is64BitOperatingSystem){throw 'Trusted 7-Zip fallback currently supports only 64-bit Windows.'}
    if(-not (Confirm-TrustedPackageInstall -Definition $definition)){
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Verified=$false;Id=$definition.Id;Method='TrustedDirect';Path=$null}
    }

    $installer=Join-Path $brokerRoot $definition.FileName
    try {
        Write-BrokerLog ("TRUSTED_PACKAGE_DOWNLOAD_BEGIN id={0} source={1}" -f $definition.Id,$definition.Url)
        Invoke-WebRequest -Uri $definition.Url -OutFile $installer -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        if(-not (Test-Path -LiteralPath $installer -PathType Leaf)){throw 'Trusted package download did not create a file.'}
        $length=(Get-Item -LiteralPath $installer).Length
        if($length -lt [int64]$definition.MinFileBytes){throw ("Downloaded trusted package is unexpectedly small: {0} bytes." -f $length)}
        $signature=Get-AuthenticodeSignature -LiteralPath $installer -ErrorAction Stop
        $subject=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Subject}else{''}
        Write-BrokerLog ("TRUSTED_PACKAGE_SIGNATURE id={0} status={1} signer={2}" -f $definition.Id,$signature.Status,$subject)
        if($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid){throw ("Trusted package signature is not valid: {0}" -f $signature.Status)}
        if($subject -notmatch $definition.SignerPattern){throw ("Unexpected trusted package signer: {0}" -f $subject)}

        Write-BrokerLog ("TRUSTED_PACKAGE_INSTALL_BEGIN id={0}" -f $definition.Id)
        $process=Start-Process -FilePath $installer -ArgumentList $definition.InstallerArguments -Wait -PassThru -WindowStyle Hidden
        Write-BrokerLog ("TRUSTED_PACKAGE_INSTALL_EXIT id={0} exitCode={1}" -f $definition.Id,$process.ExitCode)
        if($process.ExitCode -ne 0){throw ("Trusted package installer exited with code {0}." -f $process.ExitCode)}
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }

    if(-not (Test-Path -LiteralPath $definition.VerifyPath -PathType Leaf)){throw ("Trusted package installer completed, but verification path is missing: {0}" -f $definition.VerifyPath)}
    $file=Get-Item -LiteralPath $definition.VerifyPath -ErrorAction Stop
    $version=[string]$file.VersionInfo.FileVersion
    Write-BrokerLog ("TRUSTED_PACKAGE_VERIFY id={0} path={1} version={2}" -f $definition.Id,$definition.VerifyPath,$version)
    [pscustomobject]@{Confirmed=$true;Changed=$true;Verified=$true;Id=$definition.Id;Method='TrustedDirect';Path=$definition.VerifyPath;Version=$version}
}

'@
Insert-BeforeExactlyOnce $broker 'function Confirm-PackageChange {' $fallback

$dispatcherOld="        'InstallPackage' {"
$dispatcherNew="        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }`n        'InstallPackage' {"
Replace-ExactlyOnce $broker $dispatcherOld $dispatcherNew

foreach($path in @($broker,'system/Broker-Request.ps1','system/Start-Agent.ps1')){
    $old="'InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
    $new="'InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
    Replace-ExactlyOnce $path $old $new
}

$agent='system/Start-Agent.ps1'
Replace-ExactlyOnce $agent "- Use the broker's typed winget actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage." "- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, InstallTrustedPackageFallback."
Replace-ExactlyOnce $agent "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget. EnsureWinget shows its own broker-owned Yes/No confirmation before any repair/download/install and only uses the official Microsoft App Installer source." "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available and the requested package is 7-Zip, call InstallTrustedPackageFallback with Id 7zip.7zip. This fallback is broker-owned, hard-coded to the official 7-Zip release, verifies Authenticode signer/status, shows its own Yes/No confirmation, and does not accept a URL or command line from you."
Replace-ExactlyOnce $agent "- InstallPackage and UninstallPackage always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation." "- InstallPackage, UninstallPackage, and InstallTrustedPackageFallback always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation."
Replace-ExactlyOnce $agent "- The elevated broker remains typed and allowlist-only. It does not accept arbitrary elevated command text, scripts, installer paths, or free-form command-line arguments." "- The elevated broker remains typed and allowlist-only. It does not accept arbitrary elevated command text, scripts, installer paths, URLs, or free-form command-line arguments. Trusted direct installers are broker-owned fixed definitions only."

Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.45-final' -Encoding UTF8

$parseErrors=@()
Get-ChildItem system -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){$parseErrors += $errors}
}
if($parseErrors){$parseErrors | ForEach-Object {Write-Error $_};throw 'PowerShell parser audit failed'}

$brokerText=Get-Content $broker -Raw
if($brokerText -notmatch "'7zip\.7zip'"){throw 'Trusted 7-Zip allowlist definition missing'}
if($brokerText -notmatch 'Get-AuthenticodeSignature'){throw 'Trusted package signature verification missing'}
if($brokerText -notmatch 'Package is not in the Dr\.Swinux trusted direct-install allowlist'){throw 'Trusted package default-deny missing'}
if($brokerText -notmatch 'https://github\.com/ip7z/7zip/releases/download/26\.02/7z2602-x64\.exe'){throw 'Pinned official 7-Zip source missing'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/Start-Agent.ps1 system/VERSION.txt
git commit -m 'Add trusted 7-Zip install fallback'
git push
