param(
    [Parameter(Mandatory=$true)][string]$Session,
    [Parameter(Mandatory=$true)][ValidateSet('FAILURE','BLOCKED','UNKNOWN')][string]$Status,
    [int]$CodexExit=0,
    [string]$Task='',
    [string]$ReportsRoot='',
    [string]$ProjectRoot=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-OptionalPropertyValue {
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $null}
    return $property.Value
}

function ConvertTo-SafeText {
    param([string]$Text,[hashtable]$Replacements)
    if($null -eq $Text){return ''}
    $safe=[string]$Text
    foreach($key in @($Replacements.Keys | Sort-Object Length -Descending)){
        if([string]::IsNullOrWhiteSpace([string]$key)){continue}
        $safe=$safe.Replace([string]$key,[string]$Replacements[$key])
    }

    # Redact common credential/token forms. This is intentionally conservative and
    # operates only on the diagnostic copy, never on the original session logs.
    $safe=[regex]::Replace($safe,'(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}','Bearer <REDACTED>')
    $safe=[regex]::Replace($safe,'(?i)\b(?:sk|sess|ghp|gho|github_pat)_[A-Za-z0-9_-]{12,}\b','<REDACTED_TOKEN>')
    $safe=[regex]::Replace($safe,'(?im)^(\s*(?:OPENAI_API_KEY|CODEX_ACCESS_TOKEN|GITHUB_TOKEN|GH_TOKEN|PASSWORD|PASSWD|TOKEN|AUTHORIZATION)\s*[:=]\s*).+$','$1<REDACTED>')
    $safe=[regex]::Replace($safe,'(?i)([?&](?:token|key|apikey|api_key|access_token)=)[^&\s]+','$1<REDACTED>')
    return $safe
}

function Read-LimitedText {
    param([string]$Path,[int]$MaxBytes=2097152)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($file.Length -le $MaxBytes){return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $stream.Seek(-$MaxBytes,[IO.SeekOrigin]::End)|Out-Null
        $buffer=New-Object byte[] $MaxBytes
        $read=$stream.Read($buffer,0,$buffer.Length)
        return "[Dr.Swinux reporter: beginning truncated; last $read bytes follow]`r`n"+[Text.Encoding]::UTF8.GetString($buffer,0,$read)
    } finally {$stream.Dispose()}
}

$sessionFull=[IO.Path]::GetFullPath($Session)
if(-not(Test-Path -LiteralPath $sessionFull -PathType Container)){throw 'Failure reporter session directory does not exist.'}
if([string]::IsNullOrWhiteSpace($ReportsRoot)){$ReportsRoot=Split-Path -Parent $sessionFull}
$reportsFull=[IO.Path]::GetFullPath($ReportsRoot)
if(-not $sessionFull.StartsWith(($reportsFull.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Failure reporter session must be inside ReportsRoot.'}
if([string]::IsNullOrWhiteSpace($ProjectRoot)){$ProjectRoot=Split-Path -Parent $reportsFull}
$projectFull=[IO.Path]::GetFullPath($ProjectRoot)

$outbox=Join-Path $reportsFull '_failure-outbox'
New-Item -ItemType Directory -Path $outbox -Force|Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$id=[guid]::NewGuid().ToString('N').Substring(0,10)
$baseName=('DrSwinux-failure-{0}-{1}-{2}' -f $stamp,$Status.ToLowerInvariant(),$id)
$stage=Join-Path $outbox ($baseName+'.stage')
$zipPath=Join-Path $outbox ($baseName+'.zip')
New-Item -ItemType Directory -Path $stage -Force|Out-Null

$replacements=@{}
foreach($pair in @(
    @($sessionFull,'<SESSION>'),
    @($projectFull,'<DRSW_ROOT>'),
    @([string]$env:USERPROFILE,'<USERPROFILE>'),
    @([string]$env:LOCALAPPDATA,'<LOCALAPPDATA>'),
    @([string]$env:APPDATA,'<APPDATA>')
)){
    if(-not[string]::IsNullOrWhiteSpace([string]$pair[0])){$replacements[[string]$pair[0]]=[string]$pair[1]}
}

$allowlist=@(
    'preflight.log',
    'codex-error.log',
    'codex-console.log',
    'final-answer.txt',
    'environment.log',
    'sandbox-env.log',
    'broker\broker.log'
)
$included=@()
try {
    foreach($relative in $allowlist){
        $source=Join-Path $sessionFull $relative
        $text=Read-LimitedText -Path $source
        if($null -eq $text){continue}
        $safe=ConvertTo-SafeText -Text $text -Replacements $replacements
        $destination=Join-Path $stage $relative
        $parent=Split-Path -Parent $destination
        if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        Set-Content -LiteralPath $destination -Value $safe -Encoding UTF8 -NoNewline
        $included += $relative
    }

    $safeTask=ConvertTo-SafeText -Text $Task -Replacements $replacements
    if($safeTask.Length -gt 4000){$safeTask=$safeTask.Substring(0,4000)+' [truncated]'}
    Set-Content -LiteralPath (Join-Path $stage 'task.txt') -Value $safeTask -Encoding UTF8 -NoNewline
    $included += 'task.txt'

    $version='unknown'
    $versionFile=Join-Path (Join-Path $projectFull 'system') 'VERSION.txt'
    if(Test-Path -LiteralPath $versionFile -PathType Leaf){try{$version=(Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()}catch{}}
    $taskHash=''
    if(-not[string]::IsNullOrWhiteSpace($Task)){
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$taskHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Task)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    }
    $manifest=[ordered]@{
        schemaVersion=1
        createdAt=(Get-Date).ToString('o')
        status=$Status
        codexExit=$CodexExit
        version=$version
        sessionLeaf=(Split-Path -Leaf $sessionFull)
        taskSha256=$taskHash
        files=$included
        redaction='paths-and-common-credential-patterns'
        transport='outbox'
        sent=$false
    }

    $configPath=Join-Path (Join-Path $projectFull 'system') 'failure-reporting.json'
    $config=$null
    if(Test-Path -LiteralPath $configPath -PathType Leaf){
        try{$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{}
    }
    $transport=([string](Get-OptionalPropertyValue -Object $config -Name 'transport')).ToLowerInvariant()
    $webhookUrl=[string](Get-OptionalPropertyValue -Object $config -Name 'webhookUrl')
    if([string]::IsNullOrWhiteSpace($transport)){$transport='outbox'}
    if($transport -notin @('outbox','webhook')){$transport='outbox'}
    $manifest.transport=$transport

    $manifestPath=Join-Path $stage 'manifest.json'
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if(Test-Path -LiteralPath $zipPath -PathType Leaf){Remove-Item -LiteralPath $zipPath -Force}
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    if(-not(Test-Path -LiteralPath $zipPath -PathType Leaf)){throw 'Failure reporter did not create the ZIP bundle.'}

    $sendError=$null
    if($transport -eq 'webhook'){
        try {
            if([string]::IsNullOrWhiteSpace($webhookUrl)){throw 'webhook transport selected but webhookUrl is empty.'}
            $uri=[Uri]$webhookUrl
            if($uri.Scheme -ne 'https'){throw 'Failure reporter webhook must use HTTPS.'}
            if($webhookUrl.Length -gt 2048){throw 'Failure reporter webhook URL is too long.'}
            $headers=@{
                'X-DrSwinux-Status'=$Status
                'X-DrSwinux-Version'=$version
                'X-DrSwinux-Bundle'=[IO.Path]::GetFileName($zipPath)
            }
            $response=Invoke-WebRequest -Uri $uri -Method Post -InFile $zipPath -ContentType 'application/zip' -Headers $headers -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){throw ('Webhook returned HTTP '+[int]$response.StatusCode)}
            $manifest.sent=$true
        } catch {$sendError=$_.Exception.Message}
    }

    $manifest.sent=[bool]$manifest.sent
    $sidecar=Join-Path $outbox ($baseName+'.json')
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $sidecar -Encoding UTF8
    if(-not[string]::IsNullOrWhiteSpace($sendError)){
        Set-Content -LiteralPath (Join-Path $outbox ($baseName+'.send-error.txt')) -Value (ConvertTo-SafeText -Text $sendError -Replacements $replacements) -Encoding UTF8
    }
    [pscustomobject]@{Bundle=$zipPath;Manifest=$sidecar;Transport=$transport;Sent=[bool]$manifest.sent;SendError=$sendError}
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
