$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path='.github/workflows/release.yml'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old='# Triggered for the audited v1.5.48 AppX host compatibility and broker request race fix.'
$new='# Triggered for the audited v1.5.49 trusted registered-package uninstall fallback.'
if(-not $text.Contains($old)){throw 'Release comment marker missing'}
$text=$text.Replace($old,$new)
$oldActions="foreach(`$needle in @('SearchTrustedPackages','InstallTrustedPackage'))"
$newActions="foreach(`$needle in @('SearchTrustedPackages','InstallTrustedPackage','UninstallTrustedPackage'))"
if(-not $text.Contains($oldActions)){throw 'Trusted action audit marker missing'}
$text=$text.Replace($oldActions,$newActions)

$insertBefore="          `$catalog=Get-Content 'system/catalog/trusted-packages.json' -Raw | ConvertFrom-Json -ErrorAction Stop"
if(-not $text.Contains($insertBefore)){throw 'Catalog audit marker missing'}
$uninstallAudit=@'
          $trustedUninstallBlock=[regex]::Match($broker,'(?s)function Get-TrustedHklmInstalledMatches \{.*?function Confirm-PackageChange \{').Value;if([string]::IsNullOrWhiteSpace($trustedUninstallBlock)){throw 'Trusted uninstall broker block missing'};if($trustedUninstallBlock-match'HKEY_CURRENT_USER'){throw 'Trusted uninstall must remain HKLM-only'};foreach($root in @('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){if($trustedUninstallBlock-notmatch[regex]::Escape($root)){throw "Trusted uninstall root missing: $root"}};if($trustedUninstallBlock-notmatch'QuietUninstallString'){throw 'Trusted uninstall QuietUninstallString gate missing'};if($trustedUninstallBlock-notmatch'ProgramFiles'){throw 'Trusted uninstall Program Files boundary missing'};foreach($hostName in @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','rundll32.exe')){if($trustedUninstallBlock-notmatch[regex]::Escape($hostName)){throw "Trusted uninstall shell denylist missing: $hostName"}};if($trustedUninstallBlock-notmatch'TRUSTED_UNINSTALL_VERIFY'){throw 'Trusted uninstall post-change verification missing'};if($broker-match'Invoke-Expression'){throw 'Invoke-Expression is forbidden in broker'};if($agent-notmatch'EnsureWinget at most once per task'){throw 'Agent deterministic EnsureWinget retry guard missing'};if($agent-notmatch'UninstallTrustedPackage correlates the packaged catalog with an HKLM uninstall entry'){throw 'Agent trusted uninstall boundary missing'}
'@
$text=$text.Replace($insertBefore,$uninstallAudit.TrimEnd()+[Environment]::NewLine+$insertBefore)

$catalogEnd="          `$up=Get-Content 'system/Update-DrSwintus.ps1' -Raw"
if(-not $text.Contains($catalogEnd)){throw 'Catalog end marker missing'}
$publisherAudit=@'
          foreach($pkg in $packages){foreach($i in @($pkg.installers)){$publisherPattern=[string]$i.publisherPattern;if(-not[string]::IsNullOrWhiteSpace($publisherPattern)){try{[void][regex]::new($publisherPattern)}catch{throw "Invalid catalog publisherPattern: $($pkg.id)"}}}};$seven=@($packages|Where-Object{[string]$_.id-ieq'7zip.7zip'});if($seven.Count-ne1){throw '7-Zip trusted catalog entry missing'};foreach($i in @($seven[0].installers)){if([string]$i.publisherPattern-ne'^Igor Pavlov$'){throw '7-Zip trusted publisher pin missing'}}
'@
$text=$text.Replace($catalogEnd,$publisherAudit.TrimEnd()+[Environment]::NewLine+$catalogEnd)
Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add .github/workflows/release.yml
git commit -m 'Harden release audit for trusted uninstall'
git push
