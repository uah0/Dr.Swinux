$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Replace-ExactlyOnce([string]$Path,[string]$Old,[string]$New) {
    $text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $first=$text.IndexOf($Old,[StringComparison]::Ordinal)
    if($first -lt 0){throw ("Text not found in {0}" -f $Path)}
    $second=$text.IndexOf($Old,$first+$Old.Length,[StringComparison]::Ordinal)
    if($second -ge 0){throw ("Text occurs more than once in {0}" -f $Path)}
    $updated=$text.Substring(0,$first)+$New+$text.Substring($first+$Old.Length)
    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
}

$broker='system/Privileged-Broker.ps1'
Replace-ExactlyOnce $broker "                SignerPattern='(?i)Igor Pavlov'`n                InstallerArguments=@('/S')" "                Sha256='6745FA76DC2EA031596D8678F6F6B99C3C1B435B4164A63485ADBBC7B8D82EF0'`n                InstallerArguments=@('/S')"
Replace-ExactlyOnce $broker 'Dr.Swinux проверит цифровую подпись перед запуском установщика.' 'Dr.Swinux проверит закреплённый SHA-256 перед запуском установщика.'
$old=@'
        $signature=Get-AuthenticodeSignature -LiteralPath $installer -ErrorAction Stop
        $subject=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Subject}else{''}
        Write-BrokerLog ("TRUSTED_PACKAGE_SIGNATURE id={0} status={1} signer={2}" -f $definition.Id,$signature.Status,$subject)
        if($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid){throw ("Trusted package signature is not valid: {0}" -f $signature.Status)}
        if($subject -notmatch $definition.SignerPattern){throw ("Unexpected trusted package signer: {0}" -f $subject)}

'@
$new=@'
        $actualHash=(Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        $expectedHash=([string]$definition.Sha256).ToUpperInvariant()
        Write-BrokerLog ("TRUSTED_PACKAGE_SHA256 id={0} expected={1} actual={2}" -f $definition.Id,$expectedHash,$actualHash)
        if($actualHash -ne $expectedHash){throw ("Trusted package SHA-256 mismatch. Expected {0}, got {1}." -f $expectedHash,$actualHash)}

'@
Replace-ExactlyOnce $broker $old $new

$agent='system/Start-Agent.ps1'
Replace-ExactlyOnce $agent 'This fallback is broker-owned, hard-coded to the official 7-Zip release, verifies Authenticode signer/status, shows its own Yes/No confirmation, and does not accept a URL or command line from you.' 'This fallback is broker-owned, hard-coded to the official 7-Zip release and a pinned SHA-256, shows its own Yes/No confirmation, and does not accept a URL or command line from you. Call this fallback at most once per task; if it returns an error, report that concrete blocker instead of retrying the same deterministic action.'

Set-Content -LiteralPath 'system/VERSION.txt' -Value 'Dr.Swinux v1.5.46-final' -Encoding UTF8

$parseErrors=@()
Get-ChildItem system -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors){$parseErrors += $errors}
}
if($parseErrors){$parseErrors | ForEach-Object {Write-Error $_};throw 'PowerShell parser audit failed'}

$brokerText=Get-Content $broker -Raw -Encoding UTF8
if($brokerText -match 'Get-AuthenticodeSignature'){throw 'Obsolete Authenticode fallback verification remains'}
if($brokerText -notmatch '6745FA76DC2EA031596D8678F6F6B99C3C1B435B4164A63485ADBBC7B8D82EF0'){throw 'Pinned 7-Zip SHA-256 missing'}
if($brokerText -notmatch 'Get-FileHash -LiteralPath \$installer -Algorithm SHA256'){throw 'SHA-256 runtime verification missing'}
if($brokerText -notmatch 'Trusted package SHA-256 mismatch'){throw 'SHA-256 mismatch fail-closed guard missing'}
if($brokerText -notmatch 'https://github\.com/ip7z/7zip/releases/download/26\.02/7z2602-x64\.exe'){throw 'Pinned official 7-Zip URL missing'}

$agentText=Get-Content $agent -Raw -Encoding UTF8
if($agentText -notmatch 'Call this fallback at most once per task'){throw 'Deterministic retry guard missing from agent instructions'}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add system/Privileged-Broker.ps1 system/Start-Agent.ps1 system/VERSION.txt
git commit -m 'Pin trusted 7-Zip installer SHA256'
git push
