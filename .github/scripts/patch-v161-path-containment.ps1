$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$path='system/Start-Agent.ps1'
$raw=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$old=@'
function Test-PathInsideTaskWorkspace {
    param([Parameter(Mandatory=$true)][string]$Path)
    $workspaceFull=[IO.Path]::GetFullPath($session).TrimEnd('\\')+'\\'
    $pathFull=[IO.Path]::GetFullPath($Path).TrimEnd('\\')+'\\'
    return $pathFull.StartsWith($workspaceFull,[StringComparison]::OrdinalIgnoreCase)
}
'@
$new=@'
function Test-PathInsideTaskWorkspace {
    param([Parameter(Mandatory=$true)][string]$Path)
    $workspaceFull=[IO.DirectoryInfo]::new($session).FullName
    $pathFull=[IO.DirectoryInfo]::new($Path).FullName
    $relative=[IO.Path]::GetRelativePath($workspaceFull,$pathFull)
    if([string]::IsNullOrWhiteSpace($relative)){ return $true }
    if([IO.Path]::IsPathRooted($relative)){ return $false }
    if($relative -eq '..'){ return $false }
    return -not $relative.StartsWith(('..'+[IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal)
}
'@
if(-not $raw.Contains($old)){throw 'Containment function anchor missing.'}
$raw=$raw.Replace($old,$new)
Set-Content -LiteralPath $path -Value $raw -Encoding UTF8 -NoNewline

$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)
if($errors){$errors|ForEach-Object{Write-Error $_};throw 'Start-Agent.ps1 parser audit failed'}

$check=Get-Content -LiteralPath $path -Raw -Encoding UTF8
foreach($needle in @('[IO.Path]::GetRelativePath','[IO.Path]::IsPathRooted','WRITABLE_ROOT_OK','windows.sandbox="unelevated"','workspace-write')){
    if(-not $check.Contains($needle)){throw "Post-patch invariant missing: $needle"}
}
if($check -match 'danger-full-access'){throw 'Unsafe Codex sandbox regression'}

# Exercise the containment algorithm with portable-drive-shaped Windows paths on the Windows runner.
$base='Z:\Dr.Swinux\reports\KOMPUTER_2026-09-04_103017_40127e1b_codex'
foreach($child in @("$base\.codex-tmp","$base\.codex-home")){
    $rel=[IO.Path]::GetRelativePath($base,$child)
    if([IO.Path]::IsPathRooted($rel)-or$rel -eq '..'-or$rel.StartsWith(('..'+[IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal)){
        throw "Containment self-test rejected valid child: $child -> $rel"
    }
}
$outside='C:\Users\a\AppData\Local\Temp'
$outsideRel=[IO.Path]::GetRelativePath($base,$outside)
if((-not[IO.Path]::IsPathRooted($outsideRel))-and$outsideRel -ne '..'-and(-not$outsideRel.StartsWith(('..'+[IO.Path]::DirectorySeparatorChar),[StringComparison]::Ordinal))){
    throw "Containment self-test accepted outside path: $outside -> $outsideRel"
}

$versionPath='system/VERSION.txt'
$version=(Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
if($version -ne 'Dr.Swinux v1.5.60-final'){throw "Unexpected VERSION: $version"}
Set-Content -LiteralPath $versionPath -Value "Dr.Swinux v1.5.61-final`n" -Encoding UTF8 -NoNewline
Write-Host 'Patched path containment and set Dr.Swinux v1.5.61-final'
