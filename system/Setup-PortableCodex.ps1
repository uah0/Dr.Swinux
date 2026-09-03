
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

# Keep a compatibility-pinned Codex runtime for this release.
# Update this only after a newer Codex build has passed a full Windows startup/auth/task acceptance test.
$pinnedCodexVersion='0.151.0'
$pinnedCodexReleaseTag=('rust-v{0}' -f $pinnedCodexVersion)

$RootPath=Split-Path -Parent $PSScriptRoot
if(-not (Test-Path -LiteralPath $RootPath -PathType Container)){
    throw ("SWINTUS root does not exist: {0}" -f $RootPath)
}

$toolsRoot=Join-Path $RootPath 'tools'
$codexDir=Join-Path $toolsRoot 'Codex'
$codexExe=Join-Path $codexDir 'codex.exe'
$codexHome=Join-Path $toolsRoot 'CodexHome'

# Setup may be launched independently of ASK-AGENT.cmd. Ensure the common
# tools parent exists instead of relying on a directory entry in the ZIP.
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

# Keep all Codex state and ChatGPT auth on the USB drive.
$env:CODEX_HOME=$codexHome

$configPath=Join-Path $codexHome 'config.toml'
$config=@'
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"

[sandbox_workspace_write]
exclude_tmpdir_env_var = true
exclude_slash_tmp = true
'@
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

$codeModeHost=Join-Path $codexDir 'codex-code-mode-host.exe'
$commandRunner=Join-Path $codexDir 'codex-command-runner.exe'
$sandboxSetup=Join-Path $codexDir 'codex-windows-sandbox-setup.exe'

$mainCliValid=$false
if(Test-Path -LiteralPath $codexExe -PathType Leaf){
    try {
        $versionText=(& $codexExe --version 2>&1 | Out-String).Trim()
        if(($LASTEXITCODE -eq 0) -and ($versionText -match ('(?m)^codex-cli\s+{0}(?:\s|$)' -f [regex]::Escape($pinnedCodexVersion)))){
            $mainCliValid=$true
        } else {
            Write-Host ("Existing codex.exe failed CLI validation: {0}" -f $versionText)
        }
    } catch {
        Write-Host ("Existing codex.exe failed CLI validation: {0}" -f $_.Exception.Message)
    }
}

if((-not $mainCliValid) -or (-not (Test-Path -LiteralPath $codeModeHost -PathType Leaf)) -or (-not (Test-Path -LiteralPath $commandRunner -PathType Leaf)) -or (-not (Test-Path -LiteralPath $sandboxSetup -PathType Leaf))){
    Write-Host ("Preparing proven portable Codex {0} for Windows x64..." -f $pinnedCodexVersion)

    $headers=@{
        'User-Agent'='WIN-DIAG'
        'Accept'='application/vnd.github+json'
    }

    $release=Invoke-RestMethod `
        -Uri ('https://api.github.com/repos/openai/codex/releases/tags/{0}' -f $pinnedCodexReleaseTag) `
        -Headers $headers `
        -Method Get `
        -TimeoutSec 60

    $wanted=@(
        'codex-x86_64-pc-windows-msvc.exe.zip',
        'codex-code-mode-host-x86_64-pc-windows-msvc.exe.zip'
    )

    foreach($assetName in $wanted){
        $asset=@($release.assets | Where-Object {
            $_.name -eq $assetName
        } | Select-Object -First 1)

        if(-not $asset){
            throw ("Required official Codex Windows x64 release asset was not found: {0}" -f $assetName)
        }

        $zipPath=Join-Path $codexDir $assetName
        Write-Host ("Downloading {0}..." -f $assetName)
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 180

        if($asset.digest -and ([string]$asset.digest).StartsWith('sha256:')){
            $expected=([string]$asset.digest).Substring(7).ToUpperInvariant()
            $actual=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if($actual -ne $expected){
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                throw ("SHA256 verification failed for {0}." -f $assetName)
            }
        }

        $tmp=Join-Path $codexDir ("_extract_{0}" -f ([IO.Path]::GetFileNameWithoutExtension($assetName)))
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force

        if($assetName -eq 'codex-x86_64-pc-windows-msvc.exe.zip'){
            # Select the MAIN CLI by exact release filename. Never use a broad
            # codex*.exe match: the archive can contain helper executables such
            # as codex-command-runner.exe which are not standalone CLIs.
            $source=@(
                Get-ChildItem -LiteralPath $tmp -Filter 'codex-x86_64-pc-windows-msvc.exe' -File -Recurse |
                Select-Object -First 1
            )
            if(-not $source){
                $source=@(
                    Get-ChildItem -LiteralPath $tmp -Filter 'codex.exe' -File -Recurse |
                    Select-Object -First 1
                )
            }
            if(-not $source){throw 'Main Codex CLI executable was not found in the official archive.'}
            Copy-Item -LiteralPath $source.FullName -Destination $codexExe -Force

            # Official Windows main ZIP bundles the native sandbox helpers.
            $runnerSource=@(
                Get-ChildItem -LiteralPath $tmp -Filter 'codex-command-runner.exe' -File -Recurse |
                Select-Object -First 1
            )
            $setupSource=@(
                Get-ChildItem -LiteralPath $tmp -Filter 'codex-windows-sandbox-setup.exe' -File -Recurse |
                Select-Object -First 1
            )
            if(-not $runnerSource){throw 'codex-command-runner.exe was not found in the official main Codex archive.'}
            if(-not $setupSource){throw 'codex-windows-sandbox-setup.exe was not found in the official main Codex archive.'}
            Copy-Item -LiteralPath $runnerSource.FullName -Destination $commandRunner -Force
            Copy-Item -LiteralPath $setupSource.FullName -Destination $sandboxSetup -Force
        } else {
            $source=@(
                Get-ChildItem -LiteralPath $tmp -Filter '*code-mode-host*.exe' -File -Recurse |
                Select-Object -First 1
            )
            if(-not $source){throw 'codex-code-mode-host.exe was not found in the official archive.'}
            Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $codexDir 'codex-code-mode-host.exe') -Force
        }

        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    if(-not (Test-Path -LiteralPath $codexExe -PathType Leaf)){
        throw 'Portable Codex installation failed.'
    }
    $installedVersion=(& $codexExe --version 2>&1 | Out-String).Trim()
    if(($LASTEXITCODE -ne 0) -or ($installedVersion -notmatch ('(?m)^codex-cli\s+{0}(?:\s|$)' -f [regex]::Escape($pinnedCodexVersion)))){
        throw ("Downloaded main Codex CLI failed validation: {0}" -f $installedVersion)
    }
    Write-Host ("Validated main CLI: {0}" -f $installedVersion)

    if(-not (Test-Path -LiteralPath $codeModeHost -PathType Leaf)){
        throw 'Portable Codex code-mode host installation failed.'
    }
    if(-not (Test-Path -LiteralPath $commandRunner -PathType Leaf)){
        throw 'Portable Codex command runner installation failed.'
    }
    if(-not (Test-Path -LiteralPath $sandboxSetup -PathType Leaf)){
        throw 'Portable Codex Windows sandbox setup helper installation failed.'
    }

    Write-Host ("Portable Codex installed to {0}" -f $codexExe)
}

# Do not clone another Codex installation's ChatGPT auth.json. ChatGPT refresh
# tokens rotate, so copying the same token to two Codex homes can later produce
# refresh_token_reused. Start-Agent performs the official device-auth flow when
# this portable CODEX_HOME has no usable authorization, and keeps that resulting
# authorization on the USB for subsequent computers.

# Runtime setup must not force or probe an interactive login. Start-Agent owns
# authentication after setup completes. In particular, `codex login status` can
# return a non-zero process exit code when the portable CODEX_HOME is not logged
# in. If that external command is the final command in this script, pwsh propagates
# the non-zero code and Start-Agent incorrectly treats a successful runtime setup
# as a setup failure before it can launch device-auth.
Write-Host ''
Write-Host 'Portable Codex runtime is ready.'
Write-Host ("CODEX_HOME: {0}" -f $codexHome)
exit 0
