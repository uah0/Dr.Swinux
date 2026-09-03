$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path='system/Privileged-Broker.ps1'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old="        'InstallTrustedPackage' { return Install-TrustedPackageCatalog -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }"
$new="        'InstallTrustedPackage' { return Install-TrustedPackageCatalog -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }`r`n        'InstallTrustedPackageFallback' { return Install-TrustedPackageFallback -Id ([string](Get-BrokerParameter -Parameters `$Parameters -Name 'Id' -Default '')) }"
$count=([regex]::Matches($text,[regex]::Escape($old))).Count
if($count-ne 1){throw "Expected one joined dispatcher marker, found $count"}
Set-Content -LiteralPath $path -Value $text.Replace($old,$new) -Encoding UTF8 -NoNewline
$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$t,[ref]$e)
if($e){$e|ForEach-Object{Write-Error $_};throw 'Broker parser audit failed'}
$check=Get-Content -LiteralPath $path -Raw -Encoding UTF8
if($check -notmatch "'SearchTrustedPackages'" -or $check -notmatch "'InstallTrustedPackage'" -or $check -notmatch "'InstallTrustedPackageFallback'"){throw 'Catalog dispatcher audit failed'}
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add $path
git commit -m 'Normalize trusted catalog dispatcher cases'
git push
