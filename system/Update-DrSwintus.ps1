param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [ValidateSet('Check','Install')][string]$Mode='Check'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo='uah0/Dr.Swinux'
$systemRoot=Join-Path $ProjectRoot 'system'
$versionPath=Join-Path $systemRoot 'VERSION.txt'
$reportsRoot=Join-Path $ProjectRoot 'reports'
$workRoot=Join-Path $reportsRoot '_update'
$availablePath=Join-Path $workRoot 'update-available.json'
function Get-VersionFromText([string]$Text){
    $m=[regex]::Match($Text,'(?i)\bv?(\d+)\.(\d+)\.(\d+)\b')
    if(-not $m.Success){ throw ('Не удалось определить версию: '+$Text) }
    return [version](('{0}.{1}.{2}' -f $m.Groups[1].Value,$m.Groups[2].Value,$m.Groups[3].Value))
}
function Get-ReleaseInfo {
    if(-not (Test-Path -LiteralPath $versionPath -PathType Leaf)){ return $null }
    $localVersion=Get-VersionFromText ((Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim())
    $headers=@{'User-Agent'='Dr-Swinux-Updater';'Accept'='application/vnd.github+json'}
    $release=Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $repo) -Headers $headers -TimeoutSec 12
    $remoteVersion=Get-VersionFromText ([string]$release.tag_name)
    if($remoteVersion -le $localVersion){ return $null }
    $asset=@($release.assets | Where-Object { $_.name -match '^Dr\.Swinux-v[0-9]+\.[0-9]+\.[0-9]+-final\.zip$' }) | Select-Object -First 1
    if($null -eq $asset){ $asset=@($release.assets | Where-Object { $_.name -match '^Dr\.Swintus-v[0-9]+\.[0-9]+\.[0-9]+-final\.zip$' }) | Select-Object -First 1 }
    if($null -eq $asset){ $asset=@($release.assets | Where-Object { $_.name -match '^Doctor\.Swinux-v[0-9]+\.[0-9]+\.[0-9]+-final\.zip$' }) | Select-Object -First 1 }
    if($null -eq $asset){ throw 'В последнем GitHub Release не найден пакет Dr.Swinux.' }
    $digest=[string]$asset.digest
    $digestMatch=[regex]::Match($digest,'^sha256:([0-9a-fA-F]{64})$')
    if(-not $digestMatch.Success){ throw 'GitHub Release не содержит SHA-256 digest для пакета.' }
    return [pscustomobject]@{LocalVersion=$localVersion.ToString();RemoteVersion=$remoteVersion.ToString();Tag=[string]$release.tag_name;AssetName=[string]$asset.name;DownloadUrl=[string]$asset.browser_download_url;ExpectedHash=$digestMatch.Groups[1].Value.ToUpperInvariant()}
}
try {
    $info=Get-ReleaseInfo
    if($null -eq $info){ Remove-Item -LiteralPath $availablePath -Force -ErrorAction SilentlyContinue; exit 0 }
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $info | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $availablePath -Encoding UTF8
    if($Mode -eq 'Check'){ exit 10 }
    $zipPath=Join-Path $workRoot $info.AssetName
    $extractRoot=Join-Path $workRoot 'extracted'
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $info.DownloadUrl -Headers @{'User-Agent'='Dr-Swinux-Updater'} -OutFile $zipPath -TimeoutSec 60
    $actualHash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if($actualHash -ne $info.ExpectedHash){ throw 'SHA-256 загруженного обновления не совпадает с digest GitHub Release.' }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    $packageRoot=$null
    foreach($name in @('Dr.Swinux','Doctor.Swinux','Dr.Swintus')){
        $candidate=Join-Path $extractRoot $name
        if(Test-Path -LiteralPath (Join-Path $candidate 'system') -PathType Container){ $packageRoot=$candidate; break }
    }
    if($null -eq $packageRoot){ throw 'Пакет обновления имеет неизвестную структуру.' }
    $packageSystem=Join-Path $packageRoot 'system'
    if(-not (Test-Path -LiteralPath (Join-Path $packageSystem 'Start-Agent.ps1') -PathType Leaf)){ throw 'Пакет обновления имеет неверную структуру.' }
    if(-not (Test-Path -LiteralPath (Join-Path $packageSystem 'VERSION.txt') -PathType Leaf)){ throw 'В пакете обновления отсутствует VERSION.txt.' }
    $packageVersion=Get-VersionFromText ((Get-Content -LiteralPath (Join-Path $packageSystem 'VERSION.txt') -Raw -Encoding UTF8).Trim())
    $remoteVersion=Get-VersionFromText $info.Tag
    if($packageVersion -ne $remoteVersion){ throw 'Версия внутри пакета не совпадает с тегом GitHub Release.' }
    $backupRoot=Join-Path $workRoot ('backup-system-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $systemRoot -Destination $backupRoot -Recurse -Force
    Copy-Item -Path (Join-Path $packageSystem '*') -Destination $systemRoot -Recurse -Force
    exit 20
} catch {
    try { New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null; Add-Content -LiteralPath (Join-Path $reportsRoot 'update-error.log') -Encoding UTF8 -Value ('{0:o} {1}' -f (Get-Date),$_.Exception.Message) } catch {}
    exit 21
}
