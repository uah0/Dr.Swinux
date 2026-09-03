param(
    [Parameter(Mandatory=$true)][string]$WingetManifestRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if(-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)){
    throw 'ConvertFrom-Yaml is required to build the catalog. Install the powershell-yaml module in the catalog-generation environment.'
}
$root=[IO.Path]::GetFullPath($WingetManifestRoot)
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Manifest root not found: $root"}

$rows=@()
Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.installer.yaml' | ForEach-Object {
    try {$m=Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Yaml} catch {return}
    $id=[string]$m.PackageIdentifier; $version=[string]$m.PackageVersion
    if([string]::IsNullOrWhiteSpace($id)-or[string]::IsNullOrWhiteSpace($version)){return}
    $installers=@()
    foreach($i in @($m.Installers)){
        $arch=([string]$i.Architecture).ToLowerInvariant(); $type=([string]$i.InstallerType).ToLowerInvariant()
        $url=[string]$i.InstallerUrl; $sha=([string]$i.InstallerSha256).ToUpperInvariant(); $productCode=[string]$i.ProductCode
        if($arch -notin @('x64','x86','arm64')){continue}
        if($type -notin @('msi','wix','exe')){continue}
        if($url -notmatch '^https://'){continue}
        if($sha -notmatch '^[A-F0-9]{64}$'){continue}
        $silent=@()
        if($type -eq 'exe'){
            $s=[string]$i.InstallerSwitches.Silent
            if([string]::IsNullOrWhiteSpace($s)){continue}
            $silent=@($s)
        }
        $displayPattern=''
        $afe=@($i.AppsAndFeaturesEntries)
        if($afe.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$afe[0].DisplayName)){
            $displayPattern='^'+[regex]::Escape([string]$afe[0].DisplayName)
            if([string]::IsNullOrWhiteSpace($productCode)){$productCode=[string]$afe[0].ProductCode}
        }
        if([string]::IsNullOrWhiteSpace($productCode)-and[string]::IsNullOrWhiteSpace($displayPattern)){continue}
        $installers += [ordered]@{architecture=$arch;installerType=$type;url=$url;sha256=$sha;productCode=$productCode;displayNamePattern=$displayPattern;silentArgs=$silent}
    }
    if($installers.Count -gt 0){$rows += [pscustomobject]@{id=$id;version=$version;displayName=$id;installers=$installers}}
}

# Keep one deterministic version snapshot per PackageIdentifier. Catalog generation is independent of the release runtime.
$packages=@()
foreach($g in ($rows | Group-Object id | Sort-Object Name)){
    $chosen=$g.Group | Sort-Object version -Descending | Select-Object -First 1
    $packages += [ordered]@{id=$chosen.id;version=$chosen.version;displayName=$chosen.displayName;installers=@($chosen.installers)}
}
$out=[ordered]@{schemaVersion=1;source=[ordered]@{name='microsoft/winget-pkgs';repository='https://github.com/microsoft/winget-pkgs';generatedAt=(Get-Date).ToUniversalTime().ToString('o')};packages=$packages}
$dir=Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath));if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ("Generated trusted package catalog: {0} packages" -f $packages.Count)
