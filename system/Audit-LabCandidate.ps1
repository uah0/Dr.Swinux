param(
    [Parameter(Mandatory=$true)][string]$CandidateSystem,
    [Parameter(Mandatory=$true)][string]$StableSystem
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Fail([string]$Message){ throw ('LAB AUDIT: '+$Message) }

$candidate=(Resolve-Path -LiteralPath $CandidateSystem).Path
$stable=(Resolve-Path -LiteralPath $StableSystem).Path

$protected=@(
    'Privileged-Broker.ps1','Broker-Request.ps1','Audit-LabCandidate.ps1','Lab-Loop.ps1',
    'Setup-PortableCodex.ps1','Update-DrSwintus.ps1','VERSION.txt'
)
foreach($relative in $protected){
    $a=Join-Path $stable $relative
    $b=Join-Path $candidate $relative
    if(-not (Test-Path -LiteralPath $a -PathType Leaf)){ Fail ('protected stable file missing: '+$relative) }
    if(-not (Test-Path -LiteralPath $b -PathType Leaf)){ Fail ('protected candidate file missing: '+$relative) }
    $ha=(Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
    $hb=(Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
    if($ha -ne $hb){ Fail ('protected file changed: '+$relative) }
}

$forbidden=@(
    ('danger-'+'full-access'),
    ('-RootPath '+[char]34+'%ROOT%'+[char]34),
    ('-UsbRoot '+[char]34+'%USBROOT%'+[char]34)
)
foreach($file in Get-ChildItem -LiteralPath $candidate -Recurse -File -Include *.ps1,*.psm1,*.cmd,*.json,*.md,*.txt){
    $text=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach($needle in $forbidden){ if($text.Contains($needle)){ Fail ('forbidden text in '+$file.FullName+': '+$needle) } }
    if($file.Extension -in @('.ps1','.psm1')){
        $tokens=$null
        $errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){ Fail ('PowerShell parse error in '+$file.FullName+': '+(($errors | ForEach-Object Message) -join '; ')) }
        if($text -match '=\s*try\s*\{'){ Fail ('known parser regression pattern in '+$file.FullName) }
        $bad=[regex]::Matches($text,'\$(?<name>[A-Za-z_][A-Za-z0-9_]*):') | Where-Object { $_.Groups['name'].Value -notin @('env','global','script','local','private','using') }
        if($bad.Count -gt 0){ Fail ('unsafe interpolated variable colon in '+$file.FullName) }
    }
}

$start=Join-Path $candidate 'Start-Agent.ps1'
if(-not (Test-Path -LiteralPath $start -PathType Leaf)){ Fail 'Start-Agent.ps1 missing' }
$startText=Get-Content -LiteralPath $start -Raw -Encoding UTF8
if($startText -notmatch 'approval_policy=\\?"never\\?"'){ Fail 'approval_policy=never invariant missing' }
if($startText -notmatch 'windows\.sandbox=\\?"unelevated\\?"'){ Fail 'windows.sandbox=unelevated invariant missing' }
if($startText -notmatch "'--sandbox','workspace-write'"){ Fail 'workspace-write invariant missing' }

Write-Host 'LAB AUDIT OK'
exit 0
