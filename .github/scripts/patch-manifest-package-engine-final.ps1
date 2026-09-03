$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$utf8=[Text.UTF8Encoding]::new($false)

function Read-Normalized([string]$Path){return ([IO.File]::ReadAllText((Resolve-Path $Path).Path)-replace "`r`n","`n")}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText((Resolve-Path $Path).Path,$Text,$utf8)}
function Replace-One([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $first=$Text.IndexOf($Old,[StringComparison]::Ordinal)
    if($first-lt 0){throw "Missing marker: $Label"}
    if($Text.IndexOf($Old,$first+$Old.Length,[StringComparison]::Ordinal)-ge 0){throw "Duplicate marker: $Label"}
    return $Text.Substring(0,$first)+$New+$Text.Substring($first+$Old.Length)
}

$broker='system/Privileged-Broker.ps1';$client='system/Broker-Request.ps1';$agent='system/Start-Agent.ps1'
$brokerText=Read-Normalized $broker;$clientText=Read-Normalized $client;$agentText=Read-Normalized $agent

# Reuse the reviewed engine body from the staged migration source, but apply it structurally here.
$staged=Read-Normalized '.github/scripts/patch-manifest-package-engine.ps1'
$engineStartMarker='$engine=@'''
$engineStart=$staged.IndexOf($engineStartMarker,[StringComparison]::Ordinal)
if($engineStart-lt 0){throw 'Engine body start marker missing.'}
$engineStart += $engineStartMarker.Length+1
$engineEnd=$staged.IndexOf("`n'@",$engineStart,[StringComparison]::Ordinal)
if($engineEnd-lt 0){throw 'Engine body end marker missing.'}
$engine=$staged.Substring($engineStart,$engineEnd-$engineStart)
if($engine-notmatch 'function Install-TrustedPackageCatalog'-or$engine-notmatch 'TRUSTED_CATALOG_SHA256'){throw 'Extracted engine body audit failed.'}

$oldStart=$brokerText.IndexOf('function Get-TrustedPackageDefinition {',[StringComparison]::Ordinal)
$oldEnd=$brokerText.IndexOf('function Confirm-PackageChange {',$oldStart,[StringComparison]::Ordinal)
if($oldStart-lt 0-or$oldEnd-lt 0-or$oldEnd-le$oldStart){throw 'Old trusted package block boundaries not found.'}
$brokerText=$brokerText.Substring(0,$oldStart)+$engine+"`n"+$brokerText.Substring($oldEnd)

# Insert new typed cases only inside Invoke-BrokerAction, immediately before the compatibility alias.
$invokeStart=$brokerText.IndexOf('function Invoke-BrokerAction {',[StringComparison]::Ordinal)
if($invokeStart-lt 0){throw 'Invoke-BrokerAction not found.'}
$fallbackCase="        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }"
$fallbackIndex=$brokerText.IndexOf($fallbackCase,$invokeStart,[StringComparison]::Ordinal)
if($fallbackIndex-lt 0){throw 'Fallback dispatcher case not found in Invoke-BrokerAction.'}
$insert=@"
        'SearchTrustedPackages' { return Search-TrustedPackages -Query ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Query' -Default '')) }
        'InstallTrustedPackage' { return Install-TrustedPackageCatalog -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }
"@
$brokerText=$brokerText.Substring(0,$fallbackIndex)+$insert+$brokerText.Substring($fallbackIndex)

$allowOld="'InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
$allowNew="'SearchTrustedPackages','InstallTrustedPackage','InstallTrustedPackageFallback','InstallPackage','UninstallPackage','SetRegistryValue','RemoveRegistryValue'"
$brokerCount=([regex]::Matches($brokerText,[regex]::Escape($allowOld))).Count
if($brokerCount-ne 2){throw "Expected two broker allowlist tails, found $brokerCount"}
$brokerText=$brokerText.Replace($allowOld,$allowNew)
$clientText=Replace-One $clientText $allowOld $allowNew 'Broker-Request allowlist'
$agentText=Replace-One $agentText $allowOld $allowNew 'session broker-tool allowlist'

$agentText=Replace-One $agentText "- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, InstallTrustedPackageFallback." "- Use the broker's typed package actions instead of arbitrary installer commands: EnsureWinget, GetInstalledPackages, SearchPackage, InstallPackage, UninstallPackage, SearchTrustedPackages, InstallTrustedPackage." 'agent package actions'
$agentText=Replace-One $agentText "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available and the requested package is 7-Zip, call InstallTrustedPackageFallback with Id 7zip.7zip. This fallback is broker-owned, hard-coded to the official 7-Zip release and a pinned SHA-256, shows its own Yes/No confirmation, and does not accept a URL or command line from you. Call this fallback at most once per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action." "- If GetInstalledPackages or SearchPackage reports that winget is unavailable, call EnsureWinget first. If EnsureWinget cannot make winget available, use SearchTrustedPackages with the program name. If it returns an exact catalog Id, call InstallTrustedPackage with that Id. The trusted catalog is packaged with Dr.Swinux and contains broker-owned HTTPS URLs, SHA-256 hashes, installer types, fixed silent arguments, and verification metadata generated from WinGet manifests; Codex cannot supply or override those fields. Call InstallTrustedPackage at most once per exact Id per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action." 'agent trusted catalog flow'
$agentText=Replace-One $agentText "- InstallPackage, UninstallPackage, and InstallTrustedPackageFallback always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation." "- InstallPackage, UninstallPackage, and InstallTrustedPackage always show a broker-owned Yes/No confirmation dialog to the user. You cannot bypass this confirmation." 'agent confirmation policy'
$agentText=Replace-One $agentText 'Trusted direct installers are broker-owned fixed definitions only.' 'Trusted direct installers are broker-owned catalog definitions only; the catalog is read-only at runtime and package Id is the only installer-selection input accepted from Codex.' 'agent strict boundary'

Write-Utf8 $broker $brokerText;Write-Utf8 $client $clientText;Write-Utf8 $agent $agentText
Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.47-final' -Encoding UTF8

$parseErrors=@();Get-ChildItem system -Recurse -Filter '*.ps1'|ForEach-Object{$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e);if($e){$parseErrors+=$e}}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}
$catalog=Get-Content 'system/catalog/trusted-packages.json' -Raw -Encoding UTF8|ConvertFrom-Json
if([int]$catalog.schemaVersion-ne 1-or@($catalog.packages).Count-lt 1){throw 'Trusted catalog audit failed'}
$finalBroker=Get-Content $broker -Raw -Encoding UTF8
foreach($needle in @('Search-TrustedPackages','Install-TrustedPackageCatalog','Get-FileHash','Trusted package SHA-256 mismatch','msiexec.exe','catalog\trusted-packages.json')){if($finalBroker-notmatch[regex]::Escape($needle)){throw "Broker engine audit missing $needle"}}
if($finalBroker-match 'switch\(\$Id\.ToLowerInvariant\(\)\)'){throw 'Hard-coded package switch remains in broker'}
if(([regex]::Matches($finalBroker,[regex]::Escape("'SearchTrustedPackages'"))).Count-lt 2){throw 'SearchTrustedPackages not fully allowlisted'}
$finalAgent=Get-Content $agent -Raw -Encoding UTF8
if($finalAgent-notmatch 'SearchTrustedPackages'-or$finalAgent-notmatch 'package Id is the only installer-selection input'){throw 'Agent catalog instructions missing'}

git config user.name 'github-actions[bot]';git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Broker-Request.ps1 system/Start-Agent.ps1 system/VERSION.txt system/catalog/trusted-packages.json system/tools/Build-TrustedPackageCatalog.ps1
git commit -m 'Replace package-specific fallback with trusted catalog engine'
git push
