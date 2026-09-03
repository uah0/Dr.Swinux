$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-TextAll {
    param([string]$Path,[string]$Old,[string]$New,[int]$Minimum=1)
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $count=([regex]::Matches($text,[regex]::Escape($Old))).Count
    if($count -lt $Minimum){throw ("Expected at least {0} matches in {1}, found {2}" -f $Minimum,$Path,$count)}
    Set-Content -LiteralPath $Path -Value $text.Replace($Old,$New) -Encoding UTF8 -NoNewline
}

function Insert-BeforeOnce {
    param([string]$Path,[string]$Marker,[string]$Insert)
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $count=([regex]::Matches($text,[regex]::Escape($Marker))).Count
    if($count -ne 1){throw ("Expected one marker in {0}, found {1}" -f $Path,$count)}
    Set-Content -LiteralPath $Path -Value $text.Replace($Marker,$Insert+$Marker) -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
$client='system/Broker-Request.ps1'
$agent='system/Start-Agent.ps1'
$generator='system/tools/Build-TrustedPackageCatalog.ps1'
$catalogPath='system/catalog/trusted-packages.json'

$functions=@'
function Get-TrustedHklmInstalledMatches {
    param($Package)
    $productCodes=@($Package.installers | ForEach-Object {[string]$_.productCode} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    $displayPatterns=@($Package.installers | ForEach-Object {[string]$_.displayNamePattern} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    $publisherPatterns=@($Package.installers | ForEach-Object {[string]$_.publisherPattern} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    if($productCodes.Count -eq 0 -and $displayPatterns.Count -eq 0){throw 'Trusted package has no uninstall-registry correlation metadata.'}

    $roots=@(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $matches=@()
    foreach($root in $roots){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
        foreach($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
            $item=$null
            try {$item=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop} catch {continue}
            $keyName=[string]$key.PSChildName
            $display=[string]$item.DisplayName
            $publisher=[string]$item.Publisher
            $matched=$false
            foreach($code in $productCodes){if($keyName -ieq $code){$matched=$true;break}}
            if(-not $matched -and -not [string]::IsNullOrWhiteSpace($display)){
                foreach($pattern in $displayPatterns){
                    try {if($display -match $pattern){$matched=$true;break}} catch {throw 'Trusted catalog displayNamePattern is invalid.'}
                }
            }
            if(-not $matched){continue}
            if($publisherPatterns.Count -gt 0){
                $publisherMatched=$false
                foreach($pattern in $publisherPatterns){
                    try {if($publisher -match $pattern){$publisherMatched=$true;break}} catch {throw 'Trusted catalog publisherPattern is invalid.'}
                }
                if(-not $publisherMatched){continue}
            }
            $matches += [pscustomobject]@{
                RegistryKey=[string]$key.PSPath
                RegistryLeaf=$keyName
                DisplayName=$display
                DisplayVersion=[string]$item.DisplayVersion
                Publisher=$publisher
                QuietUninstallString=[string]$item.QuietUninstallString
            }
        }
    }
    return @($matches)
}

function Convert-TrustedQuietUninstallCommand {
    param([string]$Command)
    if([string]::IsNullOrWhiteSpace($Command)){throw 'Registered package has no QuietUninstallString.'}
    if($Command.Length -gt 2000 -or $Command -match '[\x00-\x1F\x7F]'){throw 'QuietUninstallString is invalid.'}
    $match=[regex]::Match($Command,'^\s*"(?<exe>[A-Za-z]:\\[^\"]+\.exe)"\s*(?<args>.*)\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $match.Success){throw 'QuietUninstallString must contain one quoted absolute EXE path.'}
    $exe=[IO.Path]::GetFullPath($match.Groups['exe'].Value)
    if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw ("Registered uninstaller executable was not found: {0}" -f $exe)}
    $leaf=[IO.Path]::GetFileName($exe).ToLowerInvariant()
    if($leaf -in @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','rundll32.exe')){throw ("Registered uninstaller executable is not allowed: {0}" -f $leaf)}

    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | ForEach-Object {([IO.Path]::GetFullPath($_).TrimEnd('\')+'\')}
    $allowed=$false
    foreach($root in $roots){if($exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){$allowed=$true;break}}
    if(-not $allowed){throw 'Registered uninstaller must be located under Program Files.'}

    $argText=$match.Groups['args'].Value.Trim()
    if([string]::IsNullOrWhiteSpace($argText)){throw 'QuietUninstallString has no silent-uninstall argument.'}
    if($argText -match '["''`;&|<>$()]'){throw 'QuietUninstallString contains unsupported shell or quoting syntax.'}
    $args=@($argText -split '\s+' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($args.Count -lt 1 -or $args.Count -gt 8){throw 'QuietUninstallString has an unsupported argument count.'}
    $allowedArgs=@('/s','/silent','/quiet','/verysilent','/suppressmsgboxes','/norestart','-s','--silent','--quiet')
    foreach($arg in $args){if(([string]$arg).ToLowerInvariant() -notin $allowedArgs){throw ("QuietUninstallString argument is not allowlisted: {0}" -f $arg)}}
    [pscustomobject]@{FilePath=$exe;Arguments=$args;Raw=$Command}
}

function Confirm-TrustedPackageUninstall {
    param($Package,$Entry,$Command)
    $display=if([string]::IsNullOrWhiteSpace($Entry.DisplayName)){[string]$Package.id}else{$Entry.DisplayName}
    $message="Удалить установленную программу через её зарегистрированный тихий деинсталлятор?`r`n`r`nНазвание: $display`r`nВерсия: $($Entry.DisplayVersion)`r`nИздатель: $($Entry.Publisher)`r`nPackage ID: $($Package.id)`r`nДеинсталлятор: $($Command.FilePath)`r`n`r`nКоманда взята только из HKLM uninstall registry после сопоставления с доверенным каталогом Dr.Swinux.`r`nCodex не может передать путь или аргументы.`r`nДействие будет выполнено с правами администратора."
    Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_DIALOG_SHOW id={0} display={1}" -f $Package.id,$display)
    Initialize-BrokerMessageBox
    $flags=[uint32](0x00000004 -bor 0x00000020 -bor 0x00000100 -bor 0x00001000 -bor 0x00010000 -bor 0x00040000)
    $answer=[DrSwintus.NativeMessageBox]::MessageBoxW([IntPtr]::Zero,$message,'Dr.Swinux',$flags)
    if($answer -eq 6){Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_USER_YES id={0}" -f $Package.id);return $true}
    Write-BrokerLog ("TRUSTED_UNINSTALL_CONFIRM_USER_NO id={0} result={1}" -f $Package.id,$answer)
    return $false
}

function Uninstall-TrustedPackage {
    param([string]$Id)
    Assert-PackageId -Id $Id
    $package=Get-TrustedPackageDefinition -Id $Id
    $matches=@(Get-TrustedHklmInstalledMatches -Package $package)
    if($matches.Count -eq 0){return [pscustomobject]@{Confirmed=$null;Changed=$false;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';Installed=$false}}
    if($matches.Count -ne 1){throw ("Trusted uninstall registry match is ambiguous for {0}: {1} entries." -f $package.id,$matches.Count)}
    $entry=$matches[0]
    Write-BrokerLog ("TRUSTED_UNINSTALL_MATCH id={0} key={1} display={2} version={3} publisher={4}" -f $package.id,$entry.RegistryLeaf,$entry.DisplayName,$entry.DisplayVersion,$entry.Publisher)
    $command=Convert-TrustedQuietUninstallCommand -Command $entry.QuietUninstallString
    if(-not(Confirm-TrustedPackageUninstall -Package $package -Entry $entry -Command $command)){
        return [pscustomobject]@{Confirmed=$false;Changed=$false;Verified=$false;Id=[string]$package.id;Method='RegisteredTrustedUninstall'}
    }

    $fresh=Get-ItemProperty -LiteralPath $entry.RegistryKey -ErrorAction Stop
    if([string]$fresh.DisplayName -ne $entry.DisplayName -or [string]$fresh.Publisher -ne $entry.Publisher -or [string]$fresh.QuietUninstallString -ne $entry.QuietUninstallString){throw 'Registered uninstall metadata changed after confirmation; refusing to execute.'}
    $freshCommand=Convert-TrustedQuietUninstallCommand -Command ([string]$fresh.QuietUninstallString)
    if($freshCommand.FilePath -ne $command.FilePath -or (($freshCommand.Arguments -join "`n") -ne ($command.Arguments -join "`n"))){throw 'Registered uninstall command changed after confirmation; refusing to execute.'}

    Write-BrokerLog ("TRUSTED_UNINSTALL_EXECUTE id={0} path={1} args={2}" -f $package.id,$command.FilePath,($command.Arguments -join ' '))
    $process=Start-Process -FilePath $command.FilePath -ArgumentList $command.Arguments -Wait -PassThru -WindowStyle Hidden
    Write-BrokerLog ("TRUSTED_UNINSTALL_EXIT id={0} exitCode={1}" -f $package.id,$process.ExitCode)
    if($process.ExitCode -notin @(0,1641,3010)){throw ("Trusted registered uninstaller exited with code {0}." -f $process.ExitCode)}

    $deadline=(Get-Date).AddSeconds(15)
    $remaining=@()
    do {
        $remaining=@(Get-TrustedHklmInstalledMatches -Package $package)
        if($remaining.Count -eq 0){break}
        Start-Sleep -Milliseconds 500
    } while((Get-Date) -lt $deadline)
    $verified=($remaining.Count -eq 0)
    Write-BrokerLog ("TRUSTED_UNINSTALL_VERIFY id={0} verified={1} remaining={2}" -f $package.id,$verified,$remaining.Count)
    if(-not $verified){throw 'Registered uninstaller completed, but the trusted HKLM uninstall entry is still present.'}
    [pscustomobject]@{Confirmed=$true;Changed=$true;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';DisplayName=$entry.DisplayName;DisplayVersion=$entry.DisplayVersion;Publisher=$entry.Publisher}
}

'@
Insert-BeforeOnce $broker 'function Confirm-PackageChange {' $functions

$oldActions="'SearchTrustedPackages','InstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage'"
$newActions="'SearchTrustedPackages','InstallTrustedPackage','UninstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage'"
Replace-TextAll $broker $oldActions $newActions 1
Replace-TextAll $client $oldActions $newActions 1
Replace-TextAll $agent $oldActions $newActions 1

$brokerText=Get-Content -LiteralPath $broker -Raw -Encoding UTF8
$dispatchMarker="        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }"
if(([regex]::Matches($brokerText,[regex]::Escape($dispatchMarker))).Count -ne 1){throw 'Trusted uninstall dispatcher marker mismatch'}
$dispatch="        'UninstallTrustedPackage' { return Uninstall-TrustedPackage -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }`r`n"
Set-Content -LiteralPath $broker -Value $brokerText.Replace($dispatchMarker,$dispatch+$dispatchMarker) -Encoding UTF8 -NoNewline

$agentText=Get-Content -LiteralPath $agent -Raw -Encoding UTF8
$oldTyped='- Use the broker''s typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, SearchTrustedPackages, InstallTrustedPackage.'
$newTyped='- Use the broker''s typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, SearchTrustedPackages, InstallTrustedPackage, UninstallTrustedPackage.'
if(-not $agentText.Contains($oldTyped)){throw 'Agent typed package instruction marker missing'}
$agentText=$agentText.Replace($oldTyped,$newTyped)
$before='- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id.'
$after=@'
- Before InstallPackage, use SearchPackage and identify an exact package Id. Before UninstallPackage, use GetInstalledPackages and identify an exact installed package Id.
- Call EnsureWinget at most once per task. If it fails deterministically, do not retry it.
- For an uninstall task when winget is unavailable, use SearchTrustedPackages to resolve an exact trusted catalog Id, then call UninstallTrustedPackage with only that Id. UninstallTrustedPackage correlates the packaged catalog with an HKLM uninstall entry, accepts only a quoted EXE under Program Files with narrowly allowlisted silent switches, shows a broker-owned Yes/No confirmation, executes without cmd.exe or another shell, and verifies that the uninstall entry disappeared. Call it at most once per exact Id per task.
'@
if(-not $agentText.Contains($before)){throw 'Agent uninstall instruction marker missing'}
$agentText=$agentText.Replace($before,$after.TrimEnd())
Set-Content -LiteralPath $agent -Value $agentText -Encoding UTF8 -NoNewline

$generatorText=Get-Content -LiteralPath $generator -Raw -Encoding UTF8
$oldGen=@'
        $displayPattern=''
        $afe=@(Get-OptionalProperty $i 'AppsAndFeaturesEntries')
'@
$newGen=@'
        $displayPattern=''
        $publisherPattern=''
        $afe=@(Get-OptionalProperty $i 'AppsAndFeaturesEntries')
'@
if(-not $generatorText.Contains($oldGen)){throw 'Catalog generator AFE marker missing'}
$generatorText=$generatorText.Replace($oldGen,$newGen)
$oldPublisher=@'
            if(-not [string]::IsNullOrWhiteSpace($displayName)){$displayPattern='^'+[regex]::Escape($displayName)}
            if([string]::IsNullOrWhiteSpace($productCode)){$productCode=[string](Get-OptionalProperty $afe[0] 'ProductCode')}
'@
$newPublisher=@'
            if(-not [string]::IsNullOrWhiteSpace($displayName)){$displayPattern='^'+[regex]::Escape($displayName)}
            $publisher=[string](Get-OptionalProperty $afe[0] 'Publisher')
            if(-not [string]::IsNullOrWhiteSpace($publisher)){$publisherPattern='^'+[regex]::Escape($publisher)+'$'}
            if([string]::IsNullOrWhiteSpace($productCode)){$productCode=[string](Get-OptionalProperty $afe[0] 'ProductCode')}
'@
if(-not $generatorText.Contains($oldPublisher)){throw 'Catalog generator publisher marker missing'}
$generatorText=$generatorText.Replace($oldPublisher,$newPublisher)
$oldField='            displayNamePattern=$displayPattern' + "`n" + '            silentArgs=$silent'
$newField='            displayNamePattern=$displayPattern' + "`n" + '            publisherPattern=$publisherPattern' + "`n" + '            silentArgs=$silent'
if(-not $generatorText.Contains($oldField)){throw 'Catalog generator output marker missing'}
$generatorText=$generatorText.Replace($oldField,$newField)
Set-Content -LiteralPath $generator -Value $generatorText -Encoding UTF8 -NoNewline

$catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
foreach($pkg in @($catalog.packages)){
    if([string]$pkg.id -ieq '7zip.7zip'){
        foreach($installer in @($pkg.installers)){$installer | Add-Member -NotePropertyName publisherPattern -NotePropertyValue '^Igor Pavlov$' -Force}
    }
}
$catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.49-final' -Encoding UTF8

$parseErrors=@();Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e);if($e){$parseErrors+=$e}}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}
$brokerAudit=Get-Content $broker -Raw -Encoding UTF8;$clientAudit=Get-Content $client -Raw -Encoding UTF8;$agentAudit=Get-Content $agent -Raw -Encoding UTF8
foreach($needle in @('UninstallTrustedPackage','Get-TrustedHklmInstalledMatches','Convert-TrustedQuietUninstallCommand','TRUSTED_UNINSTALL_VERIFY')){if($brokerAudit-notmatch[regex]::Escape($needle)){throw "Missing trusted uninstall broker element: $needle"}}
foreach($text in @($brokerAudit,$clientAudit,$agentAudit)){if($text-notmatch 'UninstallTrustedPackage'){throw 'UninstallTrustedPackage is not fully allowlisted'}}
if($brokerAudit-match 'Registry::HKEY_CURRENT_USER.*Uninstall'){throw 'Trusted uninstall must not use HKCU'}
if($brokerAudit-notmatch 'ProgramFiles'){throw 'Trusted uninstall Program Files boundary missing'}
foreach($hostName in @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','rundll32.exe')){if($brokerAudit-notmatch[regex]::Escape($hostName)){throw "Trusted uninstall denylist missing: $hostName"}}
if($brokerAudit-match 'Invoke-Expression'){throw 'Invoke-Expression is forbidden'}
if($agentAudit-notmatch 'EnsureWinget at most once per task'){throw 'EnsureWinget retry guard missing'}
$catAudit=Get-Content $catalogPath -Raw|ConvertFrom-Json;$seven=@($catAudit.packages|Where-Object{[string]$_.id -ieq '7zip.7zip'});if($seven.Count-ne 1){throw '7-Zip catalog entry missing'};foreach($i in @($seven[0].installers)){if([string]$i.publisherPattern-ne'^Igor Pavlov$'){throw '7-Zip publisher pin missing'}}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/Start-Agent.ps1 system/tools/Build-TrustedPackageCatalog.ps1 system/catalog/trusted-packages.json system/VERSION.txt
git commit -m 'Add trusted registered-package uninstall fallback'
git push
