$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$path='.github/scripts/patch-trusted-uninstall-fallback.ps1'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8

$oldField=@'
$oldField='            displayNamePattern=$displayPattern' + "`n" + '            silentArgs=$silent'
$newField='            displayNamePattern=$displayPattern' + "`n" + '            publisherPattern=$publisherPattern' + "`n" + '            silentArgs=$silent'
if(-not $generatorText.Contains($oldField)){throw 'Catalog generator output marker missing'}
$generatorText=$generatorText.Replace($oldField,$newField)
'@
$newField=@'
$oldField='            displayNamePattern=$displayPattern'
$newField='            displayNamePattern=$displayPattern' + [Environment]::NewLine + '            publisherPattern=$publisherPattern'
if(([regex]::Matches($generatorText,[regex]::Escape($oldField))).Count -ne 1){throw 'Catalog generator output marker mismatch'}
$generatorText=$generatorText.Replace($oldField,$newField)
'@
if(-not $text.Contains($oldField)){throw 'Generator field migration block not found'}
$text=$text.Replace($oldField,$newField)

$oldAudit="if(`$brokerAudit-match 'Registry::HKEY_CURRENT_USER.*Uninstall'){throw 'Trusted uninstall must not use HKCU'}"
$newAudit=@'
$trustedUninstallBlock=[regex]::Match($brokerAudit,'(?s)function Get-TrustedHklmInstalledMatches \{.*?function Convert-TrustedQuietUninstallCommand \{').Value
if([string]::IsNullOrWhiteSpace($trustedUninstallBlock)){throw 'Trusted uninstall HKLM block was not found for audit'}
if($trustedUninstallBlock -match 'HKEY_CURRENT_USER'){throw 'Trusted uninstall must not use HKCU'}
foreach($requiredRoot in @('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){if($trustedUninstallBlock-notmatch[regex]::Escape($requiredRoot)){throw "Trusted uninstall HKLM root missing: $requiredRoot"}}
'@
if(-not $text.Contains($oldAudit)){throw 'Trusted uninstall HKCU audit marker not found'}
$text=$text.Replace($oldAudit,$newAudit.TrimEnd())

Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
& $path
