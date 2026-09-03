$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$utf8=[Text.UTF8Encoding]::new($false)

foreach($path in @('system/Privileged-Broker.ps1','system/Broker-Request.ps1','system/Start-Agent.ps1')){
    $resolved=(Resolve-Path $path).Path
    $text=[IO.File]::ReadAllText($resolved) -replace "`r`n","`n"
    [IO.File]::WriteAllText($resolved,$text,$utf8)
}

$patch=(Resolve-Path '.github/scripts/patch-manifest-package-engine.ps1').Path
$text=[IO.File]::ReadAllText($patch)
$auditOld='if($bt-match "switch\(\$Id\.ToLowerInvariant\(\)\)"){throw ''Hard-coded package switch remains in broker''}'
$auditNew='if($bt-match ''switch\(\$Id\.ToLowerInvariant\(\)\)''){throw ''Hard-coded package switch remains in broker''}'
if(-not $text.Contains($auditOld)){throw 'Migration audit fix marker not found.'}
$text=$text.Replace($auditOld,$auditNew)

$oldBlock=@'
foreach($path in @($broker,'system/Broker-Request.ps1','system/Start-Agent.ps1')){
    Replace-ExactlyOnce $path "'InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'" "'SearchTrustedPackages','InstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
}
'@
$newBlock=@'
$allowOld="'InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
$allowNew="'SearchTrustedPackages','InstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
$brokerAllowText=Get-Content -LiteralPath $broker -Raw -Encoding UTF8
$brokerAllowCount=([regex]::Matches($brokerAllowText,[regex]::Escape($allowOld))).Count
if($brokerAllowCount -ne 2){throw ("Expected two broker allowlist tails, found {0}" -f $brokerAllowCount)}
Set-Content -LiteralPath $broker -Value $brokerAllowText.Replace($allowOld,$allowNew) -Encoding UTF8 -NoNewline
foreach($path in @('system/Broker-Request.ps1','system/Start-Agent.ps1')){
    Replace-ExactlyOnce $path $allowOld $allowNew
}
'@
if(-not $text.Contains($oldBlock)){throw 'Migration allowlist block marker not found.'}
$text=$text.Replace($oldBlock,$newBlock)
[IO.File]::WriteAllText($patch,$text,$utf8)
& $patch
