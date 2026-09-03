$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path='.github/scripts/patch-appx-host-and-request-race.ps1'
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old='$updated=$rx.Replace($text,$Replacement,1)'
$new='$updated=$rx.Replace($text,[Text.RegularExpressions.MatchEvaluator]{param($match)$Replacement},1)'
$count=([regex]::Matches($text,[regex]::Escape($old))).Count
if($count -ne 1){throw "Migration regex-replacement marker mismatch: $count"}
Set-Content -LiteralPath $path -Value $text.Replace($old,$new) -Encoding UTF8 -NoNewline
& $path
