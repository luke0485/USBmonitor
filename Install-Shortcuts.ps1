$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$launcher = Join-Path $root 'Launch-usb-CybersecurityMonitor.vbs'
$icon = Join-Path $root 'usb-CybersecurityMonitor.ico'
if (!(Test-Path -LiteralPath $wscript)) { throw 'Windows Script Host 未找到。' }
if (!(Test-Path -LiteralPath $launcher)) { throw '隐藏启动器未找到。' }
if (!(Test-Path -LiteralPath $icon -PathType Leaf)) { throw '快捷方式图标未找到。' }
Add-Type -AssemblyName System.Drawing
$validatedIcon = [System.Drawing.Icon]::new($icon)
$validatedIcon.Dispose()
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')
foreach ($folder in @($desktop, $startup)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
$desktopLink = $shell.CreateShortcut((Join-Path $desktop 'usb-CybersecurityMonitor.lnk'))
$desktopLink.TargetPath = $wscript
$desktopLink.Arguments = '"' + $launcher + '"'
$desktopLink.WorkingDirectory = $root
$desktopLink.Description = 'usb-CybersecurityMonitor'
$desktopLink.IconLocation = $icon + ',0'
$desktopLink.Save()
$startupLink = $shell.CreateShortcut((Join-Path $startup 'usb-CybersecurityMonitor.lnk'))
$startupLink.TargetPath = $wscript
$startupLink.Arguments = '"' + $launcher + '" -Tray'
$startupLink.WorkingDirectory = $root
$startupLink.Description = 'usb-CybersecurityMonitor - tray'
$startupLink.IconLocation = $icon + ',0'
$startupLink.Save()
foreach ($folder in @($desktop,$startup)) {
    $legacyPath = Join-Path $folder 'USB检测器.lnk'
    if (Test-Path -LiteralPath $legacyPath) {
        $legacy = $shell.CreateShortcut($legacyPath)
        if ($legacy.TargetPath -eq $wscript -and $legacy.Arguments -match 'USBDetector\\App\\LaunchUSBMonitor\.vbs') {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }
}
Write-Output 'Shortcuts installed.'
if (-not ('UsbCybersecurityMonitorShellNotify' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class UsbCybersecurityMonitorShellNotify {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint eventId, uint flags, string item, IntPtr item2);
}
"@
}
foreach ($linkPath in @((Join-Path $desktop 'usb-CybersecurityMonitor.lnk'), (Join-Path $startup 'usb-CybersecurityMonitor.lnk'))) {
    $check = $shell.CreateShortcut($linkPath)
    if ($check.TargetPath -ne $wscript -or $check.IconLocation -ne ($icon + ',0')) { throw "快捷方式校验失败：$linkPath" }
    [UsbCybersecurityMonitorShellNotify]::SHChangeNotify(0x00002000, 0x0005, $linkPath, [IntPtr]::Zero)
}
