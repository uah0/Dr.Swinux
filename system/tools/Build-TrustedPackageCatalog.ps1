param(
    [Parameter(Mandatory=$true)][string]$WingetManifestRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if(-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)){
    throw 'ConvertFrom-Yaml is required to build the catalog. Install the powershell-yaml module in the catalog-generation environment.'
}

function Get-OptionalProperty {
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $null}
    return $property.Value
}

function Get-NaturalVersionKey {
    param([string]$Version)
    if([string]::IsNullOrWhiteSpace($Version)){return ''}
    $parts=[regex]::Matches($Version,'\d+|\D+')
    $builder=[Text.StringBuilder]::new()
    foreach($part in $parts){
        $value=$part.Value
        if($value -match '^\d+$'){
            [void]$builder.Append($value.PadLeft(24,'0'))
        } else {
            [void]$builder.Append($value.ToLowerInvariant())
        }
        [void]$builder.Append('|')
    }
    return $builder.ToString()
}

$root=[IO.Path]::GetFullPath($WingetManifestRoot)
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Manifest root not found: $root"}

$rows=@()
Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.installer.yaml' | ForEach-Object {
    try {$m=Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Yaml} catch {return}
    $id=[string](Get-OptionalProperty $m 'PackageIdentifier')
    $version=[string](Get-OptionalProperty $m 'PackageVersion')
    if([string]::IsNullOrWhiteSpace($id)-or[string]::IsNullOrWhiteSpace($version)){return}

    $rootType=([string](Get-OptionalProperty $m 'InstallerType')).ToLowerInvariant()
    $rootSwitches=Get-OptionalProperty $m 'InstallerSwitches'
    $rootAfe=@(Get-OptionalProperty $m 'AppsAndFeaturesEntries')
    $installers=@()

    foreach($i in @(Get-OptionalProperty $m 'Installers')){
        if($null -eq $i){continue}
        $arch=([string](Get-OptionalProperty $i 'Architecture')).ToLowerInvariant()
        $type=([string](Get-OptionalProperty $i 'InstallerType')).ToLowerInvariant()
        if([string]::IsNullOrWhiteSpace($type)){$type=$rootType}
        $url=[string](Get-OptionalProperty $i 'InstallerUrl')
        $sha=([string](Get-OptionalProperty $i 'InstallerSha256')).ToUpperInvariant()
        $productCode=[string](Get-OptionalProperty $i 'ProductCode')

        if($arch -notin @('x64','x86','arm64')){continue}
        if($type -notin @('msi','wix','exe')){continue}
        if($url -notmatch '^https://'){continue}
        try {$uri=[Uri]$url}catch{continue}
        if($uri.Scheme -ne 'https'){continue}
        if($sha -notmatch '^[A-F0-9]{64}$'){continue}

        $silent=@()
        if($type -eq 'exe'){
            $switches=Get-OptionalProperty $i 'InstallerSwitches'
            if($null -eq $switches){$switches=$rootSwitches}
            $silentValue=[string](Get-OptionalProperty $switches 'Silent')
            if([string]::IsNullOrWhiteSpace($silentValue)){continue}
            if($silentValue.Length -gt 500 -or $silentValue -match '[\x00-\x1F\x7F]'){continue}
            $silent=@($silentValue)
        }

        $displayPattern=''
        $afe=@(Get-OptionalProperty $i 'AppsAndFeaturesEntries')
        if($afe.Count -eq 0){$afe=$rootAfe}
        if($afe.Count -gt 0 -and $null -ne $afe[0]){
            $displayName=[string](Get-OptionalProperty $afe[0] 'DisplayName')
            if(-not [string]::IsNullOrWhiteSpace($displayName)){$displayPattern='^'+[regex]::Escape($displayName)}
            if([string]::IsNullOrWhiteSpace($productCode)){$productCode=[string](Get-OptionalProperty $afe[0] 'ProductCode')}
        }
        if([string]::IsNullOrWhiteSpace($productCode)-and[string]::IsNullOrWhiteSpace($displayPattern)){continue}

        $installers += [ordered]@{
            architecture=$arch
            installerType=$type
            url=$url
            sha256=$sha
            productCode=$productCode
            displayNamePattern=$displayPattern
            silentArgs=$silent
        }
    }

    if($installers.Count -gt 0){
        $rows += [pscustomobject]@{
            id=$id
            version=$version
            versionKey=(Get-NaturalVersionKey $version)
            displayName=$id
            installers=$installers
        }
    }
}

# Keep one deterministic newest-looking version snapshot per PackageIdentifier.
# WinGet version strings are not uniformly SemVer, so a natural numeric/text sort key is used.
$packages=@()
foreach($g in ($rows | Group-Object id | Sort-Object Name)){
    $chosen=$g.Group | Sort-Object versionKey -Descending | Select-Object -First 1
    $packages += [ordered]@{
        id=$chosen.id
        version=$chosen.version
        displayName=$chosen.displayName
        installers=@($chosen.installers)
    }
}

$out=[ordered]@{
    schemaVersion=1
    source=[ordered]@{
        name='microsoft/winget-pkgs'
        repository='https://github.com/microsoft/winget-pkgs'
        generatedAt=(Get-Date).ToUniversalTime().ToString('o')
    }
    packages=$packages
}
$dir=Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ("Generated trusted package catalog: {0} packages" -f $packages.Count)
