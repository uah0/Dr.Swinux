param(
    [Parameter(Mandatory=$true)][string]$WingetManifestRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$AutomaticSafeSubset,
    [string]$SourceCommit=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if(-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)){
    throw 'ConvertFrom-Yaml is required to build the catalog. Install the powershell-yaml module in the catalog-generation environment.'
}

function Get-OptionalProperty {
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
        return $null
    }
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
        if($value -match '^\d+$'){[void]$builder.Append($value.PadLeft(24,'0'))}
        else {[void]$builder.Append($value.ToLowerInvariant())}
        [void]$builder.Append('|')
    }
    return $builder.ToString()
}

$root=[IO.Path]::GetFullPath($WingetManifestRoot)
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Manifest root not found: $root"}
$allowedTypes=if($AutomaticSafeSubset){@('msi','wix')}else{@('msi','wix','exe')}

$fileRows=@(
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.installer.yaml' | ForEach-Object {
        $versionDir=$_.Directory
        if($null -eq $versionDir -or $null -eq $versionDir.Parent){return}
        [pscustomobject]@{
            File=$_
            PackagePath=$versionDir.Parent.FullName
            VersionDir=$versionDir.Name
            VersionKey=(Get-NaturalVersionKey $versionDir.Name)
        }
    }
)
if($fileRows.Count -eq 0){throw 'No WinGet installer manifests were found.'}
$selectedFiles=@()
foreach($group in ($fileRows | Group-Object PackagePath)){
    $selectedFiles += ($group.Group | Sort-Object VersionKey -Descending | Select-Object -First 1).File
}
Write-Host ("Installer manifests discovered: {0}; newest package paths selected: {1}" -f $fileRows.Count,$selectedFiles.Count)

$rows=@()
foreach($file in $selectedFiles){
    try {$m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Yaml} catch {continue}
    $id=[string](Get-OptionalProperty $m 'PackageIdentifier')
    $version=[string](Get-OptionalProperty $m 'PackageVersion')
    if([string]::IsNullOrWhiteSpace($id)-or[string]::IsNullOrWhiteSpace($version)){continue}
    if($id.Length -gt 200 -or $version.Length -gt 100){continue}

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
        if($type -notin $allowedTypes){continue}
        if($url -notmatch '^https://'){continue}
        try {$uri=[Uri]$url}catch{continue}
        if($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)){continue}
        if($url.Length -gt 2048){continue}
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
        $publisherPattern=''
        $afe=@(Get-OptionalProperty $i 'AppsAndFeaturesEntries')
        if($afe.Count -eq 0){$afe=$rootAfe}
        if($afe.Count -gt 0 -and $null -ne $afe[0]){
            $displayName=[string](Get-OptionalProperty $afe[0] 'DisplayName')
            if(-not [string]::IsNullOrWhiteSpace($displayName) -and $displayName.Length -le 300){$displayPattern='^'+[regex]::Escape($displayName)}
            $publisher=[string](Get-OptionalProperty $afe[0] 'Publisher')
            if(-not [string]::IsNullOrWhiteSpace($publisher) -and $publisher.Length -le 300){$publisherPattern='^'+[regex]::Escape($publisher)+'$'}
            if([string]::IsNullOrWhiteSpace($productCode)){$productCode=[string](Get-OptionalProperty $afe[0] 'ProductCode')}
        }

        if($AutomaticSafeSubset -and [string]::IsNullOrWhiteSpace($productCode)){continue}
        if([string]::IsNullOrWhiteSpace($productCode)-and[string]::IsNullOrWhiteSpace($displayPattern)){continue}
        if(-not[string]::IsNullOrWhiteSpace($productCode) -and ($productCode.Length -gt 200 -or $productCode -match '[\x00-\x1F\x7F]')){continue}

        $installers += [ordered]@{
            architecture=$arch
            installerType=$type
            url=$url
            sha256=$sha
            productCode=$productCode
            displayNamePattern=$displayPattern
            publisherPattern=$publisherPattern
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

$packages=@()
foreach($g in ($rows | Group-Object id | Sort-Object Name)){
    $chosen=$g.Group | Sort-Object versionKey -Descending | Select-Object -First 1
    $packages += [ordered]@{id=$chosen.id;version=$chosen.version;displayName=$chosen.displayName;installers=@($chosen.installers)}
}
if($AutomaticSafeSubset -and $packages.Count -lt 100){throw "Automatic safe catalog unexpectedly small: $($packages.Count) packages"}

$out=[ordered]@{
    schemaVersion=1
    source=[ordered]@{
        name='microsoft/winget-pkgs'
        repository='https://github.com/microsoft/winget-pkgs'
        generatedAt=(Get-Date).ToUniversalTime().ToString('o')
        commit=$SourceCommit
        policy=if($AutomaticSafeSubset){'automatic-msi-wix-productcode-v1'}else{'reviewed-generator-v1'}
    }
    packages=$packages
}
$dir=Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ("Generated trusted package catalog: {0} packages; policy={1}" -f $packages.Count,$out.source.policy)
