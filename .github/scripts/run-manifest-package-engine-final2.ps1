$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path=(Resolve-Path '.github/scripts/patch-manifest-package-engine-final.ps1').Path
$utf8=[Text.UTF8Encoding]::new($false)
$text=[IO.File]::ReadAllText($path)
$old='if($brokerCount-ne 2){throw "Expected two broker allowlist tails, found $brokerCount"}'
$new='if($brokerCount-ne 1){throw "Expected one broker allowlist tail, found $brokerCount"}'
if(-not $text.Contains($old)){throw 'Final migration allowlist count marker not found.'}
[IO.File]::WriteAllText($path,$text.Replace($old,$new),$utf8)
& $path
