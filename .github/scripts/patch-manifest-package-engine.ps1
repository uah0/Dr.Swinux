$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-RegexExactlyOnce([string]$Path,[string]$Pattern,[string]$Replacement){
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $rx=[regex]::new($Pattern,[Text.RegularExpressions.RegexOptions]::Singleline)
    $matches=$rx.Matches($text)
    if($matches.Count -ne 1){throw ("Expected exactly one regex match in {0}, found {1}" -f $Path,$matches.Count)}
    $updated=$rx.Replace($text,$Replacement,1)
    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
}
function Replace-ExactlyOnce([string]$Path,[string]$Old,[string]$New){
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $first=$text.IndexOf($Old,[StringComparison]::Ordinal)
    if($first -lt 0){throw ("Text not found in {0}" -f $Path)}
    $second=$text.IndexOf($Old,$first+$Old.Length,[StringComparison]::Ordinal)
    if($second -ge 0){throw ("Text occurs more than once in {0}" -f $Path)}
    Set-Content -LiteralPath $Path -Value ($text.Substring(0,$first)+$New+$text.Substring($first+$Old.Length)) -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
$engine=@'
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
'@
Replace-RegexExactlyOnce $broker 'function Get-TrustedPackageDefinition \{.*?\r?\n\}\r?\nfunction Confirm-PackageChange \{' ($engine+"`r`nfunction Confirm-PackageChange {")

Replace-ExactlyOnce $broker "        'SearchPackage' { return Search-Package -Query ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Query' -Default '')) }`n        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }" "        'SearchPackage' { return Search-Package -Query ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Query' -Default '')) }`n        'SearchTrustedPackages' { return Search-TrustedPackages -Query ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Query' -Default '')) }`n        'InstallTrustedPackage' { return Install-TrustedPackageCatalog -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }`n        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }"

foreach($path in @($broker,'system/Broker-Request.ps1','system/Start-Agent.ps1')){
    Replace-ExactlyOnce $path "'InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'" "'SearchTrustedPackages','InstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
}

$agent='system/Start-Agent.ps1'
Replace-ExactlyOnce $agent "- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, InstallTrustedPackageFallback." "- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, SearchTrustedPackages, InstallTrustedPackage."
Replace-ExactlyOnce $agent "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available and the requested package is 7-Zip, call InstallTrustedPackageFallback with Id 7zip.7zip. This fallback is broker-owned, hard-coded to the official 7-Zip release and a pinned SHA-256, shows its own Yes/No confirmation, and does not accept a URL or command line from you. Call this fallback at most once per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action." "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available, use SearchTrustedPackages with the program name. If it returns an exact catalog Id, call InstallTrustedPackage with that Id. The trusted catalog is packaged with Dr.Swinux and contains broker-owned HTTPS URLs, SHA-256 hashes, installer types, fixed silent arguments, and verification metadata generated from WinGet manifests; Codex cannot supply or override those fields. Call InstallTrustedPackage at most once per exact Id per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action."
Replace-ExactlyOnce $agent "- InstallPackage, UninstallPackage, and InstallTrustedPackageFallback always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation." "- InstallPackage, UninstallPackage, and InstallTrustedPackage always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation."
Replace-ExactlyOnce $agent "Trusted direct installers are broker-owned fixed definitions only." "Trusted direct installers are broker-owned catalog definitions only; the catalog is read-only at runtime and package Id is the only installer-selection input accepted from Codex."

Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.47-final' -Encoding UTF8

$parseErrors=@();Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors);if($errors){$parseErrors+=$errors}}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}
$catalog=Get-Content 'system/catalog/trusted-packages.json' -Raw -Encoding UTF8|ConvertFrom-Json
if([int]$catalog.schemaVersion-ne 1-or@($catalog.packages).Count-lt 1){throw 'Trusted catalog audit failed'}
$bt=Get-Content $broker -Raw -Encoding UTF8
foreach($needle in @('Search-TrustedPackages','Install-TrustedPackageCatalog','Get-FileHash','Trusted package SHA-256 mismatch','msiexec.exe','catalog\trusted-packages.json')){if($bt-notmatch[regex]::Escape($needle)){throw "Broker engine audit missing $needle"}}
if($bt-match "switch\(\$Id\.ToLowerInvariant\(\)\)"){throw 'Hard-coded package switch remains in broker'}

$sa=Get-Content $agent -Raw -Encoding UTF8
if($sa-notmatch 'SearchTrustedPackages'-or$sa-notmatch 'package Id is the only installer-selection input'){throw 'Agent catalog instructions missing'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/Start-Agent.ps1 system/VERSION.txt system/catalog/trusted-packages.json system/tools/Build-TrustedPackageCatalog.ps1
git commit -m 'Replace package-specific fallback with trusted catalog engine'
git push
