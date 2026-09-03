Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Never accept the project root through cmd.exe. A quoted Windows path ending
# in a backslash has caused real launcher failures in previous releases.
$ProjectRoot=Split-Path -Parent $PSScriptRoot
$systemDir=$PSScriptRoot
$target=Join-Path $systemDir 'ASK-AGENT.cmd'
$link=Join-Path $ProjectRoot 'ASK-AGENT.cmd.lnk'
$brandingDir=Join-Path $systemDir 'assets\branding'
$iconPng=Join-Path $brandingDir 'dr-swinux-icon.png'
$icon=Join-Path $brandingDir 'dr-swinux.ico'

if(-not (Test-Path -LiteralPath $target -PathType Leaf)){ throw ('Launcher not found: '+$target) }
if(-not (Test-Path -LiteralPath $iconPng -PathType Leaf)){ throw ('Dr.Swinux icon PNG not found: '+$iconPng) }

# The ICO is derived from the approved PNG pixels. Do not redraw the mascot here.
Add-Type -AssemblyName System.Drawing
$source=[System.Drawing.Image]::FromFile($iconPng)
$bitmap=$null
$pngStream=$null
$fileStream=$null
$writer=$null
try {
    $bitmap=New-Object System.Drawing.Bitmap 128,128
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($source,0,0,128,128)
    } finally { $graphics.Dispose() }
    $pngStream=New-Object System.IO.MemoryStream
    $bitmap.Save($pngStream,[System.Drawing.Imaging.ImageFormat]::Png)
    $bytes=$pngStream.ToArray()
    $fileStream=[System.IO.File]::Open($icon,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write)
    $writer=New-Object System.IO.BinaryWriter $fileStream
    $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]1)
    $writer.Write([byte]128); $writer.Write([byte]128); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]$bytes.Length); $writer.Write([UInt32]22); $writer.Write($bytes)
} finally {
    if($null -ne $writer){ $writer.Dispose() }
    if($null -ne $fileStream){ $fileStream.Dispose() }
    if($null -ne $pngStream){ $pngStream.Dispose() }
    if($null -ne $bitmap){ $bitmap.Dispose() }
    $source.Dispose()
}

$shell=New-Object -ComObject WScript.Shell
$sc=$shell.CreateShortcut($link)
$sc.TargetPath=$target
$sc.WorkingDirectory=$systemDir
$sc.Description='Dr.Swinux portable AI doctor'
$sc.IconLocation=$icon+',0'
$sc.WindowStyle=1
$sc.Save()
