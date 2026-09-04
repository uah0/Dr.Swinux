$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$path='system/Start-Agent.ps1'
$raw=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old="foreach(`$argument in @('exec','--config','approval_policy=\"never\"','--config','windows.sandbox=\"unelevated\"','--sandbox','workspace-write','--cd',`$session,'--skip-git-repo-check','--output-last-message',`$finalPath,'-'))"
$new="foreach(`$argument in @('exec','--config','approval_policy=\"never\"','--config','windows.sandbox=\"unelevated\"','--config','sandbox_workspace_write.exclude_tmpdir_env_var=true','--sandbox','workspace-write','--cd',`$session,'--skip-git-repo-check','--output-last-message',`$finalPath,'-'))"
if(-not $raw.Contains($old)){throw 'Codex argv anchor missing.'}
$raw=$raw.Replace($old,$new)
Set-Content -LiteralPath $path -Value $raw -Encoding UTF8 -NoNewline

$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)
if($errors){$errors|ForEach-Object{Write-Error $_};throw 'Start-Agent.ps1 parser audit failed'}
$check=Get-Content -LiteralPath $path -Raw -Encoding UTF8
foreach($needle in @('sandbox_workspace_write.exclude_tmpdir_env_var=true','windows.sandbox=\"unelevated\"','workspace-write','TASK_CODEX_HOME=','CHILD_TMPDIR=')){
 if(-not $check.Contains($needle)){throw "Invariant missing: $needle"}
}
if($check -match 'danger-full-access'){throw 'Unsafe sandbox regression'}

$versionPath='system/VERSION.txt'
$version=(Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
if($version -ne 'Dr.Swinux v1.5.61-final'){throw "Unexpected VERSION: $version"}
Set-Content -LiteralPath $versionPath -Value "Dr.Swinux v1.5.62-final`n" -Encoding UTF8 -NoNewline
Write-Host 'Patched Codex workspace-write TMP projection and set v1.5.62.'
# trigger
