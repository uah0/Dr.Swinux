param(
    [Parameter(Mandatory=$true)][string]$CandidateDirectory,
    [string]$Repository='uah0/Dr.Swinux',
    [string]$BaseBranch='main'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$token=[Environment]::GetEnvironmentVariable('DRSW_GITHUB_TOKEN','Process')
if([string]::IsNullOrWhiteSpace($token)){throw 'DRSW_GITHUB_TOKEN is not configured; repair candidate remains local.'}
if($Repository-ne'uah0/Dr.Swinux'){throw 'Repair submission repository is not allowlisted.'}
$dir=[IO.Path]::GetFullPath($CandidateDirectory)
$manifestPath=Join-Path $dir 'repair-manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Repair manifest missing.'}
$manifest=Get-Content $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
$changes=@($manifest.changedFiles)
if($changes.Count-lt1-or$changes.Count-gt12){throw 'Repair candidate change count is invalid.'}
$headers=@{Authorization='Bearer '+$token;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='DrSwinux-Repair'}
$api='https://api.github.com/repos/'+$Repository
function Invoke-Gh([string]$Method,[string]$Uri,$Body=$null){
 $params=@{Method=$Method;Uri=$Uri;Headers=$headers;ErrorAction='Stop'}
 if($null-ne$Body){$params.ContentType='application/json';$params.Body=($Body|ConvertTo-Json -Depth 12 -Compress)}
 Invoke-RestMethod @params
}
$base=Invoke-Gh GET ($api+'/git/ref/heads/'+$BaseBranch)
$baseSha=[string]$base.object.sha
if($baseSha-notmatch'^[0-9a-f]{40}$'){throw 'Could not resolve base branch SHA.'}
$branch='auto-repair/'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
[void](Invoke-Gh POST ($api+'/git/refs') @{ref='refs/heads/'+$branch;sha=$baseSha})
foreach($change in $changes){
 $path=[string]$change.path
 if($path-match'(^|\\)(\.github|tools|reports|CodexHome)(\\|$)'){throw "Candidate path is not eligible for automatic PR submission: $path"}
 $file=Join-Path $dir ('files\'+$path)
 if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Candidate file missing: $path"}
 $bytes=[IO.File]::ReadAllBytes($file);$content=[Convert]::ToBase64String($bytes)
 $urlPath=($path.Replace('\','/') -split '/'|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
 $current=$null
 try{$current=Invoke-Gh GET ($api+'/contents/'+$urlPath+'?ref='+[Uri]::EscapeDataString($branch))}catch{if($_.Exception.Response.StatusCode.value__-ne404){throw}}
 $body=@{message=('Auto-repair: '+$path);content=$content;branch=$branch}
 if($null-ne$current-and-not[string]::IsNullOrWhiteSpace([string]$current.sha)){$body.sha=[string]$current.sha}
 [void](Invoke-Gh PUT ($api+'/contents/'+$urlPath) $body)
}
$summary='Automated Dr.Swinux repair candidate generated from a sanitized failure bundle. No code was applied to the user installation. Candidate passed local parser/security invariant checks. Human/CI review is required before merge.'
$pr=Invoke-Gh POST ($api+'/pulls') @{title=('Auto-repair candidate for '+[string]$manifest.sourceVersion);head=$branch;base=$BaseBranch;body=$summary;draft=$true}
$manifest.publish.status='submitted';$manifest.publish.branch=$branch;$manifest.publish.pr=[string]$pr.html_url
$manifest|ConvertTo-Json -Depth 12|Set-Content $manifestPath -Encoding UTF8
[pscustomobject]@{Submitted=$true;Branch=$branch;PullRequest=[string]$pr.html_url}
