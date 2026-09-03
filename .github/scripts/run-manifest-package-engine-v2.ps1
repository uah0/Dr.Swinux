$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$utf8=[Text.UTF8Encoding]::new($false)
foreach($path in @('system/Privileged-Broker.ps1','system/Broker-Request.ps1','system/Start-Agent.ps1')){
    $text=[IO.File]::ReadAllText((Resolve-Path $path)) -replace "`r`n","`n"
    [IO.File]::WriteAllText((Resolve-Path $path),$text,$utf8)
}

$patch='.github/scripts/patch-manifest-package-engine.ps1'
$text=[IO.File]::ReadAllText((Resolve-Path $patch))
$old='if($bt-match "switch\(\$Id\.ToLowerInvariant\(\)\)"){throw ''Hard-coded package switch remains in broker''}'
$new='if($bt-match ''switch\(\$Id\.ToLowerInvariant\(\)\)''){throw ''Hard-coded package switch remains in broker''}'
if(-not $text.Contains($old)){throw 'Migration audit fix marker not found.'}
$text=$text.Replace($old,$new)
[IO.File]::WriteAllText((Resolve-Path $patch),$text,$utf8)
& $patch
