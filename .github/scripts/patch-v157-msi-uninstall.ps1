$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path='system/Privileged-Broker.ps1'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8

$old=@'
                Publisher=$publisher
                QuietUninstallString=(Get-RegistryStringProperty -Object $item -Name 'QuietUninstallString')
'@
$new=@'
                Publisher=$publisher
                QuietUninstallString=(Get-RegistryStringProperty -Object $item -Name 'QuietUninstallString')
                UninstallString=(Get-RegistryStringProperty -Object $item -Name 'UninstallString')
'@
if(-not $text.Contains($old)){throw 'Registry entry anchor not found.'}
$text=$text.Replace($old,$new)

$anchor='function Convert-TrustedQuietUninstallCommand {'
$helper=@'
function Get-TrustedMsiUninstallCommand {
    param($Package,$Entry,[string]$UninstallString)
    $productCodes=@($Package.installers | ForEach-Object {[string]$_.productCode} | Where-Object {$_ -match '^\{[0-9A-Fa-f-]{36}\}$'} | ForEach-Object {$_.ToUpperInvariant()} | Sort-Object -Unique)
    if($productCodes.Count -eq 0){throw 'Trusted package has no catalog-pinned MSI ProductCode.'}
    if([string]::IsNullOrWhiteSpace($UninstallString)){throw 'Registered package has neither QuietUninstallString nor a trusted MSI uninstall registration.'}
    if($UninstallString.Length -gt 500 -or $UninstallString -match '[\x00-\x1F\x7F]'){throw 'Registered MSI UninstallString is invalid.'}
    $m=[regex]::Match($UninstallString,'^\s*"?(?:[A-Za-z]:\\Windows\\System32\\)?msiexec(?:\.exe)?"?\s+/[xX]\s*(?<code>\{[0-9A-Fa-f-]{36}\})\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $m.Success){throw 'Registered package has no allowlisted quiet uninstall command and is not an exact MSI /X ProductCode registration.'}
    $code=$m.Groups['code'].Value.ToUpperInvariant()
    if($code -notin $productCodes){throw 'Registered MSI ProductCode is not pinned by the trusted catalog.'}
    $msiexec=Join-Path $env:SystemRoot 'System32\msiexec.exe'
    if(-not(Test-Path -LiteralPath $msiexec -PathType Leaf)){throw 'System msiexec.exe was not found.'}
    [pscustomobject]@{FilePath=$msiexec;Arguments=@('/x',$code,'/qn','/norestart');Raw=$UninstallString;Method='CatalogPinnedMsiProductCode';ProductCode=$code}
}

function Get-TrustedUninstallCommand {
    param($Package,$Entry)
    if(-not [string]::IsNullOrWhiteSpace([string]$Entry.QuietUninstallString)){
        $cmd=Convert-TrustedQuietUninstallCommand -Command ([string]$Entry.QuietUninstallString)
        $cmd | Add-Member -NotePropertyName Method -NotePropertyValue 'RegisteredQuietUninstall' -Force
        return $cmd
    }
    return Get-TrustedMsiUninstallCommand -Package $Package -Entry $Entry -UninstallString ([string]$Entry.UninstallString)
}

'@
if(-not $text.Contains($anchor)){throw 'Command converter anchor not found.'}
$text=$text.Replace($anchor,$helper+$anchor)

$text=$text.Replace('$command=Convert-TrustedQuietUninstallCommand -Command $entry.QuietUninstallString','$command=Get-TrustedUninstallCommand -Package $package -Entry $entry')
$oldFresh="if((Get-RegistryStringProperty -Object `$fresh -Name 'DisplayName') -ne `$entry.DisplayName -or (Get-RegistryStringProperty -Object `$fresh -Name 'Publisher') -ne `$entry.Publisher -or (Get-RegistryStringProperty -Object `$fresh -Name 'QuietUninstallString') -ne `$entry.QuietUninstallString){throw 'Registered uninstall metadata changed after confirmation; refusing to execute.'}`n    `$freshCommand=Convert-TrustedQuietUninstallCommand -Command (Get-RegistryStringProperty -Object `$fresh -Name 'QuietUninstallString')"
$newFresh="if((Get-RegistryStringProperty -Object `$fresh -Name 'DisplayName') -ne `$entry.DisplayName -or (Get-RegistryStringProperty -Object `$fresh -Name 'Publisher') -ne `$entry.Publisher -or (Get-RegistryStringProperty -Object `$fresh -Name 'QuietUninstallString') -ne `$entry.QuietUninstallString -or (Get-RegistryStringProperty -Object `$fresh -Name 'UninstallString') -ne `$entry.UninstallString){throw 'Registered uninstall metadata changed after confirmation; refusing to execute.'}`n    `$freshEntry=[pscustomobject]@{QuietUninstallString=(Get-RegistryStringProperty -Object `$fresh -Name 'QuietUninstallString');UninstallString=(Get-RegistryStringProperty -Object `$fresh -Name 'UninstallString')}`n    `$freshCommand=Get-TrustedUninstallCommand -Package `$package -Entry `$freshEntry"
if(-not $text.Contains($oldFresh)){throw 'TOCTOU anchor not found.'}
$text=$text.Replace($oldFresh,$newFresh)

$text=$text.Replace('Команда взята только из HKLM uninstall registry после сопоставления с доверенным каталогом Dr.Swinux.','Команда разрешена только после сопоставления HKLM uninstall registry с доверенным каталогом Dr.Swinux. Для MSI broker сам строит msiexec /x из catalog-pinned ProductCode; registry не может задавать исполняемый файл или дополнительные аргументы.')

Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.57-final' -Encoding UTF8 -NoNewline

$parseErrors=@();$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors);if($errors){$errors|ForEach-Object{Write-Error $_};throw 'Broker parser audit failed.'}
$check=Get-Content -LiteralPath $path -Raw
foreach($needle in @('Get-TrustedMsiUninstallCommand','CatalogPinnedMsiProductCode','Registered MSI ProductCode is not pinned by the trusted catalog.','UninstallString=(Get-RegistryStringProperty')){if(-not $check.Contains($needle)){throw "Missing MSI uninstall invariant: $needle"}}
if($check -match 'Invoke-Expression'){throw 'Unsafe Invoke-Expression detected.'}
Write-Host 'v1.5.57 MSI uninstall migration completed.'
