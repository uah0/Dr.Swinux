$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$broker='system/Privileged-Broker.ps1'
$version='system/VERSION.txt'
$text=Get-Content -LiteralPath $broker -Raw -Encoding UTF8

$old=@'
    $matches=@()
    foreach($root in $roots){
'@
$new=@'
    # Do not use $matches here: PowerShell's -match operator writes the automatic $Matches hashtable.
    $entries=@()
    foreach($root in $roots){
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Trusted HKLM accumulator marker mismatch'}
$text=$text.Replace($old,$new)

$old=@'
            $matches += [pscustomobject]@{
'@
$new=@'
            $entries += [pscustomobject]@{
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Trusted HKLM append marker mismatch'}
$text=$text.Replace($old,$new)

$old='    return @($matches)'
$new='    return @($entries)'
$helper=[regex]::Match($text,'(?s)function Get-TrustedHklmInstalledMatches \{.*?function Convert-TrustedQuietUninstallCommand \{').Value
if([string]::IsNullOrWhiteSpace($helper)){throw 'Trusted HKLM helper block missing'}
if(([regex]::Matches($helper,[regex]::Escape($old))).Count -ne 1){throw 'Trusted HKLM return marker mismatch'}
$helper2=$helper.Replace($old,$new)
$text=$text.Replace($helper,$helper2)

$old=@'
    $matches=@(Get-TrustedHklmInstalledMatches -Package $package)
    if($matches.Count -eq 0){return [pscustomobject]@{Confirmed=$null;Changed=$false;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';Installed=$false}}
    if($matches.Count -ne 1){throw ("Trusted uninstall registry match is ambiguous for {0}: {1} entries." -f $package.id,$matches.Count)}
    $entry=$matches[0]
'@
$new=@'
    $entries=@(Get-TrustedHklmInstalledMatches -Package $package)
    if($entries.Count -eq 0){return [pscustomobject]@{Confirmed=$null;Changed=$false;Verified=$true;Id=[string]$package.id;Method='RegisteredTrustedUninstall';Installed=$false}}
    if($entries.Count -ne 1){throw ("Trusted uninstall registry match is ambiguous for {0}: {1} entries." -f $package.id,$entries.Count)}
    $entry=$entries[0]
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Trusted uninstall consumer marker mismatch'}
$text=$text.Replace($old,$new)
Set-Content -LiteralPath $broker -Value $text -Encoding UTF8 -NoNewline

Set-Content -LiteralPath $version -Value 'Dr.Swinux v1.5.50-final' -Encoding UTF8 -NoNewline

# Parser audit plus regression-specific semantic checks.
$parseErrors=@()
Get-ChildItem system -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){$parseErrors += $errors}
}
if($parseErrors){$parseErrors|ForEach-Object{Write-Error $_};throw 'PowerShell parser audit failed'}

$final=Get-Content -LiteralPath $broker -Raw -Encoding UTF8
$block=[regex]::Match($final,'(?s)function Get-TrustedHklmInstalledMatches \{.*?function Convert-TrustedQuietUninstallCommand \{').Value
if([string]::IsNullOrWhiteSpace($block)){throw 'Trusted HKLM helper missing after patch'}
if($block -match '(?i)\$matches\s*(?:=|\+=)'){throw 'Regression: trusted HKLM helper reuses PowerShell automatic $Matches variable'}
if($block -notmatch '\$entries=@\(\)' -or $block -notmatch '\$entries \+= \[pscustomobject\]' -or $block -notmatch 'return @\(\$entries\)'){throw 'Trusted HKLM accumulator fix incomplete'}
if($final -notmatch "'UninstallTrustedPackage'"){throw 'Trusted uninstall action missing'}

# Small executable regression test for the exact PowerShell failure mode.
$probe=@()
$probe += [pscustomobject]@{Name='before'}
'x' -match 'x' | Out-Null
$collisionRaised=$false
try {$Matches += [pscustomobject]@{Name='after'}} catch {$collisionRaised=$_.Exception.Message -match 'hash table'}
if(-not $collisionRaised){throw 'Expected PowerShell automatic Matches collision probe did not reproduce'}

# Validate the fixed pattern independently: regex use must not mutate the entries array.
$entries=@()
'x' -match 'x' | Out-Null
$entries += [pscustomobject]@{Name='ok'}
if($entries.Count -ne 1 -or $entries[0].Name -ne 'ok'){throw 'Fixed accumulator regression probe failed'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/VERSION.txt
git commit -m 'Fix PowerShell Matches collision in trusted uninstall'
git push
