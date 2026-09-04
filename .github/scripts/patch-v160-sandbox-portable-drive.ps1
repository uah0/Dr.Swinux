$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$path='system/Start-Agent.ps1'
$raw=Get-Content -LiteralPath $path -Raw -Encoding UTF8

function Replace-Required([string]$Text,[string]$Old,[string]$New,[string]$Label){
    if(-not $Text.Contains($Old)){throw "Patch anchor missing: $Label"}
    return $Text.Replace($Old,$New)
}
function Replace-RequiredRegex([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Label){
    $regex=[regex]::new($Pattern,[Text.RegularExpressions.RegexOptions]::Multiline)
    if(-not $regex.IsMatch($Text)){throw "Patch regex anchor missing: $Label"}
    return $regex.Replace($Text,$Replacement,1)
}

$old=@'
$codexSessionTemp=Join-Path $session '.codex-tmp'
New-Item -ItemType Directory -Path $codexSessionTemp -Force | Out-Null
Set-Content -LiteralPath (Join-Path $session 'sandbox-env.log') -Encoding UTF8 -Value @(
    'CHILD_TEMP='+$codexSessionTemp,
    'CHILD_TMP='+$codexSessionTemp,
    'CHILD_TMPDIR='+$codexSessionTemp,
    'CODEX_HOME='+$codexHome,
    'WORKSPACE='+$session,
'@
$new=@'
$codexSessionTemp=Join-Path $session '.codex-tmp'
$taskCodexHome=Join-Path $session '.codex-home'
New-Item -ItemType Directory -Path $codexSessionTemp -Force | Out-Null
New-Item -ItemType Directory -Path $taskCodexHome -Force | Out-Null

function Test-PathInsideTaskWorkspace {
    param([Parameter(Mandatory=$true)][string]$Path)
    $workspaceFull=[IO.Path]::GetFullPath($session).TrimEnd('\\')+'\\'
    $pathFull=[IO.Path]::GetFullPath($Path).TrimEnd('\\')+'\\'
    return $pathFull.StartsWith($workspaceFull,[StringComparison]::OrdinalIgnoreCase)
}
foreach($sandboxWritable in @($codexSessionTemp,$taskCodexHome)){
    if(-not(Test-PathInsideTaskWorkspace -Path $sandboxWritable)){
        Stop-WithMessage ("Внутренняя ошибка sandbox: writable path находится вне task workspace: {0}" -f $sandboxWritable)
    }
}
Write-PreAgentLog -Stage 'sandbox' -Status 'WRITABLE_ROOT_OK' -Detail ('workspace={0}; taskCodexHome={1}; temp={2}' -f $session,$taskCodexHome,$codexSessionTemp)

function Initialize-TaskCodexHome {
    New-Item -ItemType Directory -Path $taskCodexHome -Force | Out-Null
    foreach($name in @('auth.json','config.toml')){
        $source=Join-Path $codexHome $name
        $destination=Join-Path $taskCodexHome $name
        if(Test-Path -LiteralPath $source -PathType Leaf){
            Copy-Item -LiteralPath $source -Destination $destination -Force
        } elseif(Test-Path -LiteralPath $destination -PathType Leaf){
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-TaskCodexAuthentication {
    $source=Join-Path $taskCodexHome 'auth.json'
    $destination=Join-Path $codexHome 'auth.json'
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){return}
    try {
        $json=Get-Content -LiteralPath $source -Raw -Encoding UTF8
        $null=$json | ConvertFrom-Json -ErrorAction Stop
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-PreAgentLog -Stage 'codex-auth' -Status 'TASK_AUTH_SYNCED' -Detail 'session-local auth state synchronized without logging credential contents'
    } catch {
        Write-PreAgentLog -Stage 'codex-auth' -Status 'TASK_AUTH_SYNC_WARN' -Detail $_.Exception.Message
    }
}

Set-Content -LiteralPath (Join-Path $session 'sandbox-env.log') -Encoding UTF8 -Value @(
    'CHILD_TEMP='+$codexSessionTemp,
    'CHILD_TMP='+$codexSessionTemp,
    'CHILD_TMPDIR='+$codexSessionTemp,
    'PERSISTENT_CODEX_HOME='+$codexHome,
    'TASK_CODEX_HOME='+$taskCodexHome,
    'WORKSPACE='+$session,
'@
$raw=Replace-Required $raw $old $new 'session-local Codex home'

$raw=Replace-RequiredRegex $raw "Ensure-CodexAuthentication -Reason 'startup-check'\r?\nWrite-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY'" "Ensure-CodexAuthentication -Reason 'startup-check'`r`nInitialize-TaskCodexHome`r`nWrite-PreAgentLog -Stage 'environment' -Status 'RUNTIME_AUTH_READY'" 'initialize task Codex home after auth'

$taskAnchor=@'
        $psi.RedirectStandardInput=$true
        $psi.RedirectStandardOutput=$true
        $psi.RedirectStandardError=$true
        $psi.Environment['CODEX_HOME']=$codexHome
        $psi.Environment['TEMP']=$codexSessionTemp
'@
$taskReplacement=@'
        $psi.RedirectStandardInput=$true
        $psi.RedirectStandardOutput=$true
        $psi.RedirectStandardError=$true
        $psi.Environment['CODEX_HOME']=$taskCodexHome
        $psi.Environment['TEMP']=$codexSessionTemp
'@
$raw=Replace-Required $raw $taskAnchor $taskReplacement 'task process CODEX_HOME'

$pattern=[regex]::Escape("        Write-PreAgentLog -Stage 'codex-process' -Status 'START' -Detail ('workspace={0}; temp={1}' -f `$session,`$codexSessionTemp)")
$replacement="        Write-PreAgentLog -Stage 'codex-process' -Status 'START' -Detail ('workspace={0}; taskCodexHome={1}; temp={2}' -f `$session,`$taskCodexHome,`$codexSessionTemp)"
$raw=Replace-RequiredRegex $raw $pattern $replacement 'task process logging'

$old=@'
$codexExit=[int]$codexExitResult[0]

if(($codexExit -ne 0) -and (Test-CodexAuthenticationFailure -ErrorLogPath $codexStderr)){
'@
$new=@'
$codexExit=[int]$codexExitResult[0]
Sync-TaskCodexAuthentication

if(($codexExit -ne 0) -and (Test-CodexAuthenticationFailure -ErrorLogPath $codexStderr)){
'@
$raw=Replace-Required $raw $old $new 'sync auth after first task'

$old=@'
    try { Ensure-CodexAuthentication -ForceFresh -Reason 'server-auth-rejection' } catch { try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}; throw }
    try { Add-Content -LiteralPath $codexStderr -Value "`r`n--- Dr.Swinux: retry after ChatGPT re-authentication ---`r`n" -Encoding UTF8 } catch {}
'@
$new=@'
    try { Ensure-CodexAuthentication -ForceFresh -Reason 'server-auth-rejection'; Initialize-TaskCodexHome } catch { try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}; throw }
    try { Add-Content -LiteralPath $codexStderr -Value "`r`n--- Dr.Swinux: retry after ChatGPT re-authentication ---`r`n" -Encoding UTF8 } catch {}
'@
$raw=Replace-Required $raw $old $new 'refresh task home after reauth'

$old=@'
    $codexExit=[int]$retryExitResult[0]
}

try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}
'@
$new=@'
    $codexExit=[int]$retryExitResult[0]
    Sync-TaskCodexAuthentication
}

try { New-Item -ItemType File -Path $brokerStop -Force | Out-Null } catch {}
'@
$raw=Replace-Required $raw $old $new 'sync auth after retry'

$old='- Do not inspect passwords, tokens, browser secrets, credential stores, SAM/SECURITY secrets, or CodexHome/auth.json.'
$new='- Do not inspect passwords, tokens, browser secrets, credential stores, SAM/SECURITY secrets, or any auth.json. The .codex-home and .codex-tmp directories inside the task workspace are launcher-managed runtime internals and must not be inspected.'
$raw=Replace-Required $raw $old $new 'prompt credential boundary'

Set-Content -LiteralPath $path -Value $raw -Encoding UTF8 -NoNewline

$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)
if($errors){$errors|ForEach-Object{Write-Error $_};throw 'Start-Agent.ps1 parser audit failed'}

$check=Get-Content -LiteralPath $path -Raw -Encoding UTF8
foreach($needle in @("`$taskCodexHome=Join-Path `$session '.codex-home'",'TASK_CODEX_HOME=','WRITABLE_ROOT_OK',"`$psi.Environment['CODEX_HOME']=`$taskCodexHome",'Sync-TaskCodexAuthentication','any auth.json')){
    if(-not $check.Contains($needle)){throw "Post-patch invariant missing: $needle"}
}
if(([regex]::Matches($check,[regex]::Escape("`$psi.Environment['CODEX_HOME']=`$taskCodexHome"))).Count -ne 1){throw 'Task-local CODEX_HOME assignment count mismatch'}
if($check -match 'danger-full-access'){throw 'Unsafe Codex sandbox regression'}
if($check -notmatch 'windows\.sandbox="unelevated"'){throw 'Unelevated sandbox invariant missing'}

$versionPath='system/VERSION.txt'
$version=(Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
if($version -notmatch '^Dr\.Swinux v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-final$'){throw "Invalid VERSION: $version"}
$newVersion=('Dr.Swinux v{0}.{1}.{2}-final' -f $Matches.major,$Matches.minor,([int]$Matches.patch+1))
Set-Content -LiteralPath $versionPath -Value ($newVersion+"`n") -Encoding UTF8 -NoNewline
Write-Host "Patched portable-drive sandbox and set $newVersion"
