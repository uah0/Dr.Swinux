$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path='system/Privileged-Broker.ps1'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old=@'
function Search-TrustedPackages {
    param([string]$Query)
    if([string]::IsNullOrWhiteSpace($Query)){throw 'Query is required.'}
    if($Query.Length -gt 200){throw 'Query is too long.'}
    if($Query -match '[\x00-\x1F\x7F]'){throw 'Query contains control characters.'}
    $needle=$Query.Trim()
    $catalog=Get-TrustedPackageCatalog
    @($catalog.packages | Where-Object {
        ([string]$_.id -like ('*'+$needle+'*')) -or ([string]$_.displayName -like ('*'+$needle+'*'))
    } | Select-Object -First 50 | ForEach-Object {
        [pscustomobject]@{Id=[string]$_.id;Version=[string]$_.version;DisplayName=[string]$_.displayName;Architectures=@($_.installers|ForEach-Object{[string]$_.architecture}|Sort-Object -Unique)}
    })
}
'@
$new=@'
function Search-TrustedPackages {
    param([string]$Query)
    if([string]::IsNullOrWhiteSpace($Query)){throw 'Query is required.'}
    if($Query.Length -gt 200){throw 'Query is too long.'}
    if($Query -match '[\x00-\x1F\x7F]'){throw 'Query contains control characters.'}
    $needle=$Query.Trim()
    $normalize={param([string]$Value) if([string]::IsNullOrWhiteSpace($Value)){return ''}; return (($Value.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+',' ').Trim() -replace '\s+',' ')}
    $normalizedNeedle=& $normalize $needle
    $tokens=@($normalizedNeedle -split ' ' | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    $catalog=Get-TrustedPackageCatalog
    @($catalog.packages | Where-Object {
        $id=[string]$_.id
        $display=[string]$_.displayName
        $haystack=& $normalize ($id+' '+$display)
        ($id -like ('*'+$needle+'*')) -or ($display -like ('*'+$needle+'*')) -or
            ($tokens.Count -gt 0 -and @($tokens | Where-Object {$haystack -notlike ('*'+$_+'*')}).Count -eq 0)
    } | Select-Object -First 50 | ForEach-Object {
        [pscustomobject]@{Id=[string]$_.id;Version=[string]$_.version;DisplayName=[string]$_.displayName;Architectures=@($_.installers|ForEach-Object{[string]$_.architecture}|Sort-Object -Unique)}
    })
}
'@
if(-not $text.Contains($old)){throw 'Trusted search anchor not found.'}
$text=$text.Replace($old,$new)
Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.58-final' -Encoding UTF8 -NoNewline
$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors);if($errors){$errors|ForEach-Object{Write-Error $_};throw 'Broker parser audit failed.'}
$catalog=Get-Content -LiteralPath 'system/catalog/trusted-packages.json' -Raw | ConvertFrom-Json
$chrome=@($catalog.packages | Where-Object {$_.id -eq 'Google.Chrome'})
if($chrome.Count -ne 1){throw 'Google.Chrome catalog invariant missing.'}
$check=Get-Content -LiteralPath $path -Raw
if(-not $check.Contains("[^\p{L}\p{Nd}]+")){throw 'Normalized trusted search invariant missing.'}
if($check -match 'Invoke-Expression'){throw 'Unsafe Invoke-Expression detected.'}
Write-Host 'v1.5.58 trusted search migration completed.'
