param([switch]$Tray)

$ErrorActionPreference = 'Stop'
$utilityModuleManifest = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
if (Test-Path -LiteralPath $utilityModuleManifest) { Import-Module $utilityModuleManifest -ErrorAction Stop } else { Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop }
$managementModuleManifest = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1'
if (Test-Path -LiteralPath $managementModuleManifest) { Import-Module $managementModuleManifest -ErrorAction Stop } else { Import-Module Microsoft.PowerShell.Management -ErrorAction Stop }
$cimModuleManifest = Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1'
if (Test-Path -LiteralPath $cimModuleManifest) { Import-Module $cimModuleManifest -ErrorAction Stop } else { Import-Module (Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1') -ErrorAction Stop }
trap {
    $message = 'usb-CybersecurityMonitor 启动失败：' + $_.Exception.Message
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($message, 'usb-CybersecurityMonitor', 'OK', 'Error') | Out-Null
    } catch { [Console]::Error.WriteLine($message) }
    break
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:scriptPath = $PSCommandPath
$script:instanceMutexOwned = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\UsbCybersecurityMonitor.Singleton', [ref]$script:instanceMutexOwned)
if (!$script:instanceMutexOwned) {
    if (!$Tray) {
        try {
            $showRequest = [Threading.EventWaitHandle]::OpenExisting('Local\UsbCybersecurityMonitor.ShowWindow')
            try { [void]$showRequest.Set() } finally { $showRequest.Dispose() }
            exit 0
        } catch {}
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UsbCybersecurityMonitorWindowActivation {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr handle, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
}
'@ -ErrorAction SilentlyContinue
            $existingWindow = [UsbCybersecurityMonitorWindowActivation]::FindWindow($null, 'usb-CybersecurityMonitor')
            if ($existingWindow -ne [IntPtr]::Zero) {
                [void][UsbCybersecurityMonitorWindowActivation]::ShowWindowAsync($existingWindow, 9)
                [void][UsbCybersecurityMonitorWindowActivation]::SetForegroundWindow($existingWindow)
            }
        } catch {}
    }
    exit 0
}
$script:showWindowRequest = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\UsbCybersecurityMonitor.ShowWindow')
$script:powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (!(Test-Path -LiteralPath $script:powershellPath)) { $script:powershellPath = Join-Path $PSHOME 'powershell.exe' }
$script:wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$script:launcherPath = Join-Path $PSScriptRoot 'Launch-usb-CybersecurityMonitor.vbs'
$script:startupFolder = [Environment]::GetFolderPath('Startup')
$script:startupLink = Join-Path $script:startupFolder 'usb-CybersecurityMonitor.lnk'
$script:stateFolder = Join-Path $env:LOCALAPPDATA 'UsbCybersecurityMonitor'
if (!$env:LOCALAPPDATA) { $script:stateFolder = Join-Path $env:TEMP 'UsbCybersecurityMonitor' }
$script:startupInitialized = Join-Path $script:stateFolder 'startup-default-v1'
$script:iconPath = Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ico'
$script:knownDevices = @{}
$script:knownCompositeDevices = @{}
$script:containerIdCache = @{}
$script:knownVolumes = @{}
$script:inventoriedVolumes = @{}
$script:activeUsbDrives = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:usbDriveInstances = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
$script:trackedUsbProcesses = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[int,object]'
$script:fileWatchers = @{}
$script:fileWatcherSources = @{}
$script:fileEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:fileEventsRaw = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:processEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:pendingOperations = @{}
$script:metadataInventoryActive = $false
$script:activeMetadataRoots = @{}
$script:pendingMetadataScans = New-Object 'System.Collections.Generic.Queue[object]'
$script:queuedMetadataRoots = @{}
$script:alertHistory = @{}
$script:processEventSource = 'USBMON-PROCESSSTART'
$script:processEventJob = $null
$script:usbProcessEventOverflow = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatcherOverflow = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatcherRecoveryAt = @{}
$script:trayIcon = $null
$script:exitRequested = $false
$script:hasInitialSnapshot = $false
$script:processMonitorStatus = '未启动'
$script:processMonitorErrors = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

function ConvertTo-PsLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}
function New-StartupShortcut {
    if (!(Test-Path -LiteralPath $script:scriptPath)) { throw '找不到 usb-CybersecurityMonitor.ps1。' }
    if (!(Test-Path -LiteralPath $script:launcherPath)) { throw '找不到隐藏启动器。' }
    New-Item -ItemType Directory -Path $script:startupFolder -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($script:startupLink)
    $shortcut.TargetPath = $script:wscriptPath
    $shortcut.Arguments = '"' + $script:launcherPath + '" -Tray'
    $shortcut.WorkingDirectory = Split-Path -Parent $script:scriptPath
    $shortcut.Description = '启动便携式 USB 检测器（托盘监听）'
    if (Test-Path -LiteralPath $script:iconPath) { $shortcut.IconLocation = $script:iconPath + ',0' }
    $shortcut.Save()
}
function Initialize-StartupDefault {
    if (Test-Path -LiteralPath $script:startupInitialized) {
        if (Test-Path -LiteralPath $script:startupLink) { New-StartupShortcut }
        return
    }
    New-StartupShortcut
    if (!(Test-Path -LiteralPath $script:stateFolder)) { New-Item -ItemType Directory -Path $script:stateFolder -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:startupInitialized, '1', [System.Text.Encoding]::ASCII)
}
function Format-Bytes([double] $Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
function Get-DeviceType([string] $Name, [string] $Class, [string] $InstanceId) {
    $text = '{0} {1} {2}' -f $Name, $Class, $InstanceId
    if ($text -match '(?i)headset|headphone|earphone|耳机|audio|sound|microphone|麦克风|扬声器|speaker') { return '耳机 / 音频' }
    if ($text -match '(?i)gamepad|game.?controller|joystick|xbox|dualshock|dualsense|playstation|switch pro|手柄|游戏控制器|操纵杆') { return '游戏手柄' }
    if ($text -match '(?i)keyboard|kbd|键盘') { return '键盘' }
    if ($text -match '(?i)mouse|mice|鼠标') { return '鼠标' }
    if ($text -match '(?i)camera|webcam|摄像头|相机') { return '摄像头' }
    if ($text -match '(?i)ftdibus|usb.?serial|serial port|串口') { return 'USB 串口设备' }
    if ($text -match '(?i)USBSTOR|disk.?drive|storage|mass storage|存储') { return 'USB 存储' }
    if ($Class -match '(?i)HID') { return 'HID 外设' }
    if ($Class -match '(?i)USB') { return 'USB 设备' }
    if ($Class) { return $Class }
    return 'USB 设备'
}
function Get-UsbPhysicalDisks {
    $allDisks = @()
    $allDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
    $usbIds = @{}
    foreach ($disk in $allDisks) {
        $instanceId = [string]$disk.PNPDeviceID
        if ($instanceId -match '(?i)^(USBSTOR|USB)\\') { $usbIds[$instanceId] = $true }
    }
    try {
        Import-Module Storage -ErrorAction Stop
        foreach ($storageDisk in @(Get-Disk -ErrorAction Stop | Where-Object { [string]$_.BusType -eq 'USB' })) {
            $index = [int]$storageDisk.Number
            $physical = $allDisks | Where-Object { [int]$_.Index -eq $index } | Select-Object -First 1
            if (!$physical) { $physical = Get-CimInstance -ClassName Win32_DiskDrive -Filter ('Index = ' + $index) -ErrorAction SilentlyContinue }
            if ($physical -and $physical.PNPDeviceID) { $usbIds[[string]$physical.PNPDeviceID] = $true }
        }
    } catch {}
    return @($allDisks | Where-Object { $usbIds.ContainsKey([string]$_.PNPDeviceID) })
}
function Get-UsbDevices([object[]] $UsbPhysicalDisks) {
    $found = @()
    $diskModels = @{}
    if ($null -eq $UsbPhysicalDisks) { $UsbPhysicalDisks = @(Get-UsbPhysicalDisks) }
    $usbDiskIds = @{}
    foreach ($disk in $UsbPhysicalDisks) {
        if ($disk.PNPDeviceID) { $usbDiskIds[[string]$disk.PNPDeviceID] = $true }
        if ($disk.PNPDeviceID -and $disk.Model) { $diskModels[[string]$disk.PNPDeviceID] = [string]$disk.Model }
    }
    try {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB%' OR PNPDeviceID LIKE 'USBSTOR%' OR PNPDeviceID LIKE 'FTDIBUS%' OR PNPDeviceID LIKE 'HID%' OR PNPDeviceID LIKE 'SCSI%'" -ErrorAction Stop)
        $usbVidPidPairs = @{}
        foreach ($candidate in $devices) {
            if (($null -ne $candidate.Present) -and (-not $candidate.Present)) { continue }
            $candidateId = [string]$candidate.PNPDeviceID
            if ($candidateId -notmatch '(?i)^(USB|USBSTOR|FTDIBUS)\\') { continue }
            $candidateHardware = @($candidate.HardwareID | ForEach-Object { [string]$_ }) -join ' '
            $candidateIdentity = $candidateId + ' ' + $candidateHardware
            $candidateVid = [regex]::Match($candidateIdentity, '(?i)(?:^|[&+\\])VID_([0-9A-F]{4})(?:[&+\\]|$)')
            $candidatePid = [regex]::Match($candidateIdentity, '(?i)(?:^|[&+\\])PID_([0-9A-F]{4})(?:[&+\\]|$)')
            if ($candidateVid.Success -and $candidatePid.Success) { $usbVidPidPairs[$candidateVid.Groups[1].Value.ToUpperInvariant() + ':' + $candidatePid.Groups[1].Value.ToUpperInvariant()] = $true }
        }
        foreach ($device in $devices) {
            $instanceId = [string]$device.PNPDeviceID
            $directUsb = ($instanceId -match '(?i)^(USB|USBSTOR|FTDIBUS)\\') -or $usbDiskIds.ContainsKey($instanceId)
            $hardwareText = @($device.HardwareID | ForEach-Object { [string]$_ }) -join ' '
            $identityText = $instanceId + ' ' + $hardwareText
            $vendorMatch = [regex]::Match($identityText, '(?i)(?:^|[&+\\])VID_([0-9A-F]{4})(?:[&+\\]|$)')
            $productMatch = [regex]::Match($identityText, '(?i)(?:^|[&+\\])PID_([0-9A-F]{4})(?:[&+\\]|$)')
            $hidChildOfUsb = $false
            if (!$directUsb -and $instanceId -match '(?i)^HID\\' -and $vendorMatch.Success -and $productMatch.Success) {
                $pair = $vendorMatch.Groups[1].Value.ToUpperInvariant() + ':' + $productMatch.Groups[1].Value.ToUpperInvariant()
                $hidChildOfUsb = $usbVidPidPairs.ContainsKey($pair)
            }
            if (!$directUsb -and !$hidChildOfUsb) { continue }
            if (($null -ne $device.Present) -and (-not $device.Present)) { continue }
            $name = [string]$device.Name
            if (!$name) { $name = [string]$device.Caption }
            if (!$name) { $name = '(未知设备)' }
            if ($diskModels.ContainsKey($instanceId) -and $name -match '(?i)mass storage|存储设备|usb device') {
                $name = $diskModels[$instanceId]
            }
            if ($instanceId -match '(?i)^FTDIBUS\\' -and $name -match '(?i)unknown|未知设备|usb device') { $name = 'FTDI USB 串口设备' }
            $vendorId = ''
            $productId = ''
            if ($vendorMatch.Success) { $vendorId = $vendorMatch.Groups[1].Value.ToUpperInvariant() }
            if ($productMatch.Success) { $productId = $productMatch.Groups[1].Value.ToUpperInvariant() }
            $class = [string]$device.PNPClass
            $status = '正常'
            if (($device.Status) -and ($device.Status -ne 'OK')) { $status = [string]$device.Status }
            elseif (($null -ne $device.ConfigManagerErrorCode) -and ($device.ConfigManagerErrorCode -ne 0)) { $status = '异常 {0}' -f $device.ConfigManagerErrorCode }
            $found += [pscustomobject]@{
                InstanceId = $instanceId
                ContainerId = (Get-DeviceContainerId $instanceId)
                Name = $name
                VendorId = $vendorId
                ProductId = $productId
                Class = $class
                Type = (Get-DeviceType $name $class $instanceId)
                Status = $status
            }
        }
    } catch { throw }
    return @($found | Sort-Object Type, Name, InstanceId)
}
function Get-DeviceContainerId([string] $InstanceId) {
    if (!$InstanceId) { return '' }
    $now = Get-Date
    if ($script:containerIdCache.ContainsKey($InstanceId)) {
        $cached = $script:containerIdCache[$InstanceId]
        if (($now - [datetime]$cached.CheckedAt).TotalSeconds -lt 30) { return [string]$cached.Value }
    }
    $value = ''
    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction Stop
        if ($property -and $property.Data) { $value = [string]$property.Data }
    } catch {}
    $containerGuid = [guid]::Empty
    if (-not [guid]::TryParse($value,[ref]$containerGuid) -or $containerGuid -eq [guid]::Empty -or $containerGuid -eq [guid]'00000000-0000-0000-ffff-ffffffffffff') { $value = '' }
    $script:containerIdCache[$InstanceId] = [pscustomobject]@{ Value=$value; CheckedAt=$now }
    return $value
}
function Get-UsbVolumes([object[]] $UsbPhysicalDisks) {
    $usbLetters = @{}
    try {
        if ($null -eq $UsbPhysicalDisks) { $UsbPhysicalDisks = @(Get-UsbPhysicalDisks) }
        $usbDisks = @($UsbPhysicalDisks)
        foreach ($disk in $usbDisks) {
            $partitions = @(Get-CimAssociatedInstance -InputObject $disk -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop)
            foreach ($partition in $partitions) {
                $logicalDisks = @(Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -ErrorAction Stop)
                foreach ($logicalDisk in $logicalDisks) {
                    if ($logicalDisk.DeviceID) { $usbLetters[$logicalDisk.DeviceID.ToUpperInvariant()] = [string]$disk.PNPDeviceID }
                }
            }
        }
    } catch { throw }
    $found = @()
    try {
        foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)) {
            $letter = [string]$disk.DeviceID
            if (!$letter) { continue }
            if ($usbLetters.ContainsKey($letter.ToUpperInvariant())) {
                $label = [string]$disk.VolumeName
                if (!$label) { $label = '(无卷标)' }
                $fileSystem = [string]$disk.FileSystem
                if (!$fileSystem) { $fileSystem = '—' }
                $found += [pscustomobject]@{
                    Drive = $letter; Label = $label; Size = [double]$disk.Size
                    Free = [double]$disk.FreeSpace; FileSystem = $fileSystem
                    InstanceId = [string]$usbLetters[$letter.ToUpperInvariant()]
                }
            }
        }
    } catch { throw }
    return @($found | Sort-Object Drive)
}
function Add-LogLine([string] $Message) {
    if (!$script:logList) { return }
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    [void]$script:logList.Items.Insert(0, $line)
    while ($script:logList.Items.Count -gt 200) { $script:logList.Items.RemoveAt($script:logList.Items.Count - 1) }
}
function Set-ListTheme([System.Windows.Forms.ListView] $List) {
    $List.OwnerDraw = $true
    $List.Add_DrawColumnHeader({
        param($sender, $eventArgs)
        $eventArgs.Graphics.FillRectangle([System.Drawing.Brushes]::Black, $eventArgs.Bounds)
        $eventArgs.Graphics.DrawRectangle([System.Drawing.Pens]::White, $eventArgs.Bounds.X, $eventArgs.Bounds.Y, ($eventArgs.Bounds.Width - 1), ($eventArgs.Bounds.Height - 1))
        $format = New-Object System.Drawing.StringFormat
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $eventArgs.Graphics.DrawString($eventArgs.Header.Text, $sender.Font, [System.Drawing.Brushes]::White, $eventArgs.Bounds, $format)
        $format.Dispose()
    })
    $List.Add_DrawSubItem({
        param($sender, $eventArgs)
        $background = if ($eventArgs.Item.Selected) { [System.Drawing.SystemBrushes]::Highlight } else { [System.Drawing.Brushes]::Black }
        $eventArgs.Graphics.FillRectangle($background, $eventArgs.Bounds)
        $eventArgs.Graphics.DrawRectangle([System.Drawing.Pens]::White, $eventArgs.Bounds.X, $eventArgs.Bounds.Y, ($eventArgs.Bounds.Width - 1), ($eventArgs.Bounds.Height - 1))
        $format = New-Object System.Drawing.StringFormat
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $textBounds = New-Object System.Drawing.RectangleF(($eventArgs.Bounds.X + 7), $eventArgs.Bounds.Y, [Math]::Max(0, ($eventArgs.Bounds.Width - 14)), $eventArgs.Bounds.Height)
        $eventArgs.Graphics.DrawString($eventArgs.SubItem.Text, $sender.Font, [System.Drawing.Brushes]::White, $textBounds, $format)
        $format.Dispose()
    })
}
function Set-FlatButton([System.Windows.Forms.Button] $Button, [System.Drawing.Color] $Color) {
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderColor = $Color
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $Button.BackColor = [System.Drawing.Color]::Black
    $Button.ForeColor = $Color
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
}
function Show-RiskNotification([string] $Title, [string] $Body) {
    try {
        if ($script:toastTimer) { $script:toastTimer.Stop(); $script:toastTimer.Dispose(); $script:toastTimer = $null }
        if ($script:toast -and !$script:toast.IsDisposed) { $script:toast.Close(); $script:toast.Dispose() }
        $toast = New-Object System.Windows.Forms.Form
        $toast.Text = 'usb-CybersecurityMonitor ALERT'
        $toast.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
        $toast.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $toast.ShowInTaskbar = $false
        $toast.TopMost = $true
        $toast.BackColor = [System.Drawing.Color]::Black
        $toast.ForeColor = [System.Drawing.Color]::White
        $toast.ClientSize = New-Object System.Drawing.Size(370, 142)
        $toast.MaximizeBox = $false
        $toast.MinimizeBox = $false
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $area = $screen.WorkingArea
        $toast.Location = New-Object System.Drawing.Point(($area.Right - $toast.Width - 14), ($area.Bottom - $toast.Height - 14))
        $header = New-Object System.Windows.Forms.Label
        $header.Text = 'USB ALERT  //  重点监测'
        $header.Location = New-Object System.Drawing.Point(13, 10)
        $header.Size = New-Object System.Drawing.Size(338, 24)
        $header.ForeColor = [System.Drawing.Color]::Red
        $header.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
        $toast.Controls.Add($header)
        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.Text = $Title
        $titleLabel.Location = New-Object System.Drawing.Point(14, 40)
        $titleLabel.Size = New-Object System.Drawing.Size(338, 22)
        $titleLabel.ForeColor = [System.Drawing.Color]::White
        $titleLabel.Font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
        $toast.Controls.Add($titleLabel)
        $bodyLabel = New-Object System.Windows.Forms.Label
        $bodyLabel.Text = $Body
        $bodyLabel.Location = New-Object System.Drawing.Point(14, 63)
        $bodyLabel.Size = New-Object System.Drawing.Size(338, 40)
        $bodyLabel.ForeColor = [System.Drawing.Color]::Gainsboro
        $bodyLabel.Font = New-Object System.Drawing.Font('Consolas', 8)
        $toast.Controls.Add($bodyLabel)
        $openButton = New-Object System.Windows.Forms.Button
        $openButton.Text = '查看'
        $openButton.Location = New-Object System.Drawing.Point(205, 108)
        $openButton.Size = New-Object System.Drawing.Size(148, 26)
        Set-FlatButton $openButton ([System.Drawing.Color]::Red)
        $openButton.Add_Click({
            if ($script:form -and !$script:form.IsDisposed) { $script:form.Show(); $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $script:form.Activate() }
            if ($script:toast -and !$script:toast.IsDisposed) { $script:toast.Close() }
        })
        $toast.Controls.Add($openButton)
        $script:toast = $toast
        $script:toastTimer = New-Object System.Windows.Forms.Timer
        $script:toastTimer.Interval = 9000
        $script:toastTimer.Add_Tick({
            $script:toastTimer.Stop()
            if ($script:toast -and !$script:toast.IsDisposed) { $script:toast.Close() }
        })
        $toast.Show()
        $script:toastTimer.Start()
    } catch { Add-LogLine ('右下角告警弹窗失败：{0}' -f $_.Exception.Message) }
}
function Invoke-RiskAlert([string] $Title, [string] $Body, [string] $Key) {
    $now = Get-Date
    foreach ($knownKey in @($script:alertHistory.Keys)) {
        if (($now - $script:alertHistory[$knownKey]).TotalMinutes -gt 5) { $script:alertHistory.Remove($knownKey) }
    }
    if ($Key -and $script:alertHistory.ContainsKey($Key) -and (($now - $script:alertHistory[$Key]).TotalSeconds -lt 60)) { return }
    if ($Key) { $script:alertHistory[$Key] = $now }
    while ($script:alertHistory.Count -gt 256) { $script:alertHistory.Remove(@($script:alertHistory.Keys)[0]) }
    Add-LogLine ('重点监测  {0}  {1}' -f $Title, $Body)
    Show-RiskNotification $Title $Body
}
function Get-UsbFileMetadataNotice([string] $Drive, [string] $Kind, [string] $Path, [System.IO.FileAttributes] $Attributes = [System.IO.FileAttributes]::Normal) {
    if ($Attributes -band [System.IO.FileAttributes]::Directory) { return $null }
    if ($Kind -notin @('CREATED','CHANGED','RENAMED')) { return $null }
    $targetPath = $Path
    $arrow = $targetPath.LastIndexOf(' -> ')
    if ($arrow -ge 0) { $targetPath = $targetPath.Substring($arrow + 4) }
    try { $leaf = [System.IO.Path]::GetFileName($targetPath) } catch { return $null }
    if (!$leaf) { return $null }
    $extension = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant()
    $detail = ''
    $needsReview = $false
    if ($leaf -ieq 'autorun.inf') {
        $detail = '检测到文件：autorun.inf'
        $needsReview = $true
    } elseif ($leaf -match '(?i)\.(pdf|docx?|xlsx?|pptx?|jpg|jpeg|png|txt|zip|rar)\.(exe|scr|com|bat|cmd|ps1|vbs|js|hta|wsf|msi)$') {
        $detail = '文件名包含双扩展名。'
        $needsReview = $true
    } elseif (($Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) -and $extension -in @('.exe','.scr','.com','.bat','.cmd','.ps1','.vbs','.js','.hta','.msi')) {
        $detail = '执行类文件带隐藏或系统属性。'
        $needsReview = $true
    } elseif ($extension -in @('.exe','.dll','.scr','.com','.bat','.cmd','.ps1','.psm1','.vbs','.js','.hta','.wsf','.msi','.lnk','.url')) {
        $detail = ('检测到文件：{0}' -f $leaf)
    } else { return $null }
    return [pscustomobject]@{ Drive=$Drive; Kind=$Kind; Path=$targetPath; Name=$leaf; Detail=$detail; NeedsReview=$needsReview }
}
function Get-UsbProcessAssociation([string] $Image, [string] $ProcessName, [string] $CommandLine, [string[]] $Drives, $ParentChain) {
    if ($ParentChain) {
        return [pscustomobject]@{ Drive=[string]$ParentChain.Drive; Detection='USB 程序的子进程'; ParentChain=$ParentChain }
    }
    $isCommandTool = ($ProcessName -match '(?i)^(robocopy|xcopy|copy|move|cmd|powershell|pwsh|7z|tar|wscript|cscript|mshta|rundll32|regsvr32|reg|schtasks|sc|certutil|bitsadmin|msiexec)(\.exe)?$')
    foreach ($drive in @($Drives)) {
        if (!$drive) { continue }
        $root = [string]$drive + '\'
        if ($Image -and $Image.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Drive=[string]$drive; Detection='程序从 USB 路径启动'; ParentChain=$null }
        }
        if ($isCommandTool -and $CommandLine -and $CommandLine.IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return [pscustomobject]@{ Drive=[string]$drive; Detection='命令行提及 USB 路径'; ParentChain=$null }
        }
    }
    return $null
}
function Get-UsbCompositeDeviceWarnings([object[]] $Devices) {
    $warnings = New-Object 'System.Collections.Generic.List[object]'
    $groups = @($Devices | Where-Object { $_.ContainerId } | Group-Object { [string]$_.ContainerId })
    foreach ($group in $groups) {
        $items = @($group.Group)
        $hasStorage = @($items | Where-Object { $_.Type -eq 'USB 存储' }).Count -gt 0
        $hasKeyboard = @($items | Where-Object { $_.Type -eq '键盘' }).Count -gt 0
        if ($hasStorage -and $hasKeyboard) {
            $deviceNames = (@($items | ForEach-Object { [string]$_.Name } | Select-Object -Unique) -join ' / ')
            $warnings.Add([pscustomobject]@{
                Key=[string]$group.Name
                Title='USB 复合接口提示'
                Body=('同一设备同时检测到存储和键盘接口：{0}' -f $deviceNames)
            })
        }
    }
    return @($warnings.ToArray())
}
function Get-UsbDeviceExplanation($Device) {
    if ([string]$Device.Type -eq '键盘') {
        return ('检测到键盘接口：{0}' -f [string]$Device.Name)
    }
    return ''
}
function Start-ProcessMonitor {
    try {
        $data = @{
            Queue = $script:processEvents
            Drives = $script:activeUsbDrives
            DriveInstances = $script:usbDriveInstances
            Chains = $script:trackedUsbProcesses
            Overflow = $script:usbProcessEventOverflow
            MaxTracked = 512
            Errors = $script:processMonitorErrors
            Diagnostics = $script:processMonitorDiagnostics
        }
        $processAction = {
            param($started, $monitorData)
            try {
                if ($started.TargetInstance) {
                    $target = $started.TargetInstance
                    $started = [pscustomobject]@{ ProcessID=$target.ProcessId; ParentProcessID=$target.ParentProcessId; ProcessName=$target.Name }
                }
                $processId = [int]$started.ProcessID
                $parentProcessId = [int]$started.ParentProcessID
                $process = $null
                for ($attempt = 0; $attempt -lt 3 -and !$process; $attempt++) {
                    $process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $processId) -Property ProcessId, ExecutablePath, CreationDate -ErrorAction SilentlyContinue
                    if (!$process -and $attempt -lt 2) { Start-Sleep -Milliseconds 50 }
                }
                if (!$process) { return }
                $image = [string]$process.ExecutablePath
                $processName = [string]$started.ProcessName
                if ($null -ne $monitorData.Diagnostics) { $monitorData.Diagnostics.Enqueue(('EVENT {0} {1}' -f $processId,$processName)) }
                $commandLine = ''
                $usbCommandTool = ($processName -match '(?i)^(robocopy|xcopy|copy|move|cmd|powershell|pwsh|7z|tar|wscript|cscript|mshta|rundll32|regsvr32|reg|schtasks|sc|certutil|bitsadmin|msiexec)(\.exe)?$')
                if ($usbCommandTool) {
                    $commandInfo = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $processId) -Property ProcessId, CommandLine -ErrorAction SilentlyContinue
                    if ($commandInfo) { $commandLine = [string]$commandInfo.CommandLine }
                }
                $matchedDrive = ''
                $rootDetection = ''
                foreach ($drive in @($monitorData.Drives.Keys)) {
                    if (!$monitorData.Drives[$drive]) { continue }
                    $root = [string]$drive + '\'
                    if ($image -and $image.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $matchedDrive = $drive
                        $rootDetection = '程序从 USB 启动'
                        break
                    }
                    if ($usbCommandTool -and $commandLine -and $commandLine.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedDrive = $drive
                        $rootDetection = '命令行显式引用 USB'
                        break
                    }
                }
                $parentChain = $null
                if ($parentProcessId -gt 0 -and $monitorData.Chains.TryGetValue($parentProcessId, [ref]$parentChain)) {
                    try {
                        $parentProcess = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $parentProcessId) -Property ProcessId, ExecutablePath, CreationDate -ErrorAction SilentlyContinue
                        $parentTime = if ($parentProcess) { ([datetime]$parentProcess.CreationDate).ToFileTimeUtc() } else { 0L }
                        if (!$parentProcess -or ([long]$parentChain.CreationFileTime -gt 0 -and [Math]::Abs([double]($parentTime - [long]$parentChain.CreationFileTime)) -gt 10000000)) { $parentChain = $null }
                    } catch { $parentChain = $null }
                }
                if (!$matchedDrive -and !$parentChain) { return }
                if (!$commandLine) {
                    $commandInfo = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $processId) -Property ProcessId, CommandLine -ErrorAction SilentlyContinue
                    if ($commandInfo) { $commandLine = [string]$commandInfo.CommandLine }
                }
                if ($parentChain) {
                    $matchedDrive = [string]$parentChain.Drive
                    $rootProcessId = [int]$parentChain.RootPid
                    $rootImage = [string]$parentChain.RootImage
                    $rootDetection = [string]$parentChain.RootDetection
                    $deviceInstanceId = [string]$parentChain.DeviceInstanceId
                    $depth = [int]$parentChain.Depth + 1
                    $matchKind = 'USB 程序的子进程'
                } else {
                    $rootProcessId = $processId
                    $rootImage = $image
                    $deviceInstanceId = ''
                    [void]$monitorData.DriveInstances.TryGetValue($matchedDrive, [ref]$deviceInstanceId)
                    $depth = 0
                    $matchKind = $rootDetection
                }
                $creationFileTime = 0L
                try { $creationFileTime = ([datetime]$process.CreationDate).ToFileTimeUtc() } catch {}
                if ($creationFileTime -le 0) { try { $creationFileTime = [System.Diagnostics.Process]::GetProcessById($processId).StartTime.ToFileTimeUtc() } catch {} }
                $record = [pscustomobject]@{
                    ProcessId = $processId
                    ParentProcessId = $parentProcessId
                    ProcessName = $processName
                    Image = $image
                    CommandLine = $commandLine
                    Drive = $matchedDrive
                    DeviceInstanceId = $deviceInstanceId
                    RootPid = $rootProcessId
                    RootImage = $rootImage
                    RootDetection = $rootDetection
                    Depth = $depth
                    CreationFileTime = $creationFileTime
                    Detection = $matchKind
                }
                $oldRecord = $null
                if ($monitorData.Chains.TryGetValue($processId, [ref]$oldRecord)) {
                    [void]$monitorData.Chains.TryUpdate($processId, $record, $oldRecord)
                } elseif ($monitorData.Chains.Count -lt [int]$monitorData.MaxTracked) {
                    [void]$monitorData.Chains.TryAdd($processId, $record)
                }
                $payload = $record | ConvertTo-Json -Compress
                $q = $monitorData.Queue
                if ($q.Count -lt 1000) { $q.Enqueue(('PROCESS|' + $payload)) }
                else { [void]$monitorData.Overflow.TryAdd('USB', $true) }
            } catch {
                if ($null -ne $monitorData.Errors -and $monitorData.Errors.Count -lt 20) { $monitorData.Errors.Enqueue($_.Exception.Message) }
            }
        }
        $data.Handler = $processAction
        try {
            $script:processEventJob = Register-WmiEvent -Class Win32_ProcessStartTrace -SourceIdentifier $script:processEventSource -MessageData $data -Action { & $Event.MessageData.Handler $Event.SourceEventArgs.NewEvent $Event.MessageData } -ErrorAction Stop
            $script:processMonitorStatus = '实时事件'
        } catch {
            Add-LogLine ('实时进程事件不可用，切换普通权限后备监听：{0}' -f $_.Exception.Message)
            $script:processPollAction = $processAction
            $script:processMonitorData = $data
            $script:seenProcessInstances = @{}
            foreach ($process in @(Get-CimInstance Win32_Process -Property ProcessId,Name,ParentProcessId,CreationDate -ErrorAction Stop)) {
                $script:seenProcessInstances[[int]$process.ProcessId] = [string]$process.CreationDate
            }
            $script:processMonitorStatus = '轮询'
        }
        Add-LogLine 'USB 程序链监听已开启；仅保留直接关联 USB 的程序与后代链路'
    } catch {
        $script:processMonitorStatus = '失败：' + $_.Exception.Message
        Add-LogLine ('进程行为监听未能开启：{0}' -f $_.Exception.Message)
    }
}
function Invoke-UsbProcessPoll {
    if (-not $script:processPollAction) { return }
    try {
        $current = @{}
        foreach ($process in @(Get-CimInstance Win32_Process -Property ProcessId,Name,ParentProcessId,CreationDate -ErrorAction Stop)) {
            $id = [int]$process.ProcessId
            $stamp = [string]$process.CreationDate
            $current[$id] = $stamp
            if (-not $script:seenProcessInstances.ContainsKey($id) -or $script:seenProcessInstances[$id] -ne $stamp) {
                & $script:processPollAction ([pscustomobject]@{TargetInstance=$process}) $script:processMonitorData
            }
        }
        $script:seenProcessInstances = $current
    } catch {
        $script:processMonitorStatus = '轮询失败'
        Add-LogLine ('进程轮询失败：' + $_.Exception.Message)
    }
}
function Add-VolumeWatcher([string] $Drive) {
    $root = $Drive + '\'
    if ($script:fileWatchers.ContainsKey($Drive) -or !(Test-Path -LiteralPath $root)) { return }
    $watcher = $null
    $ids = @()
    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $root
        $watcher.Filter = '*'
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName -bor [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        $ids = @()
        $queue = $script:fileEvents
        if ($null -ne $script:fileEventsRaw) { $queue = $script:fileEventsRaw }
        $messageData = @{ Queue = $queue; Drive = $Drive; Overflow = $script:fileWatcherOverflow }
        foreach ($eventName in @('Created', 'Changed', 'Deleted', 'Renamed')) {
            $sourceId = 'USBMON-' + $Drive.Replace(':','') + '-' + $eventName + '-' + [guid]::NewGuid().ToString('N')
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceId -MessageData $messageData -Action {
                $q = $Event.MessageData.Queue
                if ($q.Count -ge 1000) { [void]$Event.MessageData.Overflow.TryAdd([string]$Event.MessageData.Drive, $true); return }
                $kind = $Event.SourceEventArgs.ChangeType.ToString().ToUpperInvariant()
                if ($kind -notin @('CREATED','CHANGED','RENAMED','DELETED')) { return }
                $path = $Event.SourceEventArgs.FullPath
                if ($Event.SourceEventArgs -is [System.IO.RenamedEventArgs]) { $path = $Event.SourceEventArgs.OldFullPath + ' -> ' + $Event.SourceEventArgs.FullPath }
                $targetPath = $path
                $arrow = $targetPath.LastIndexOf(' -> ')
                if ($arrow -ge 0) { $targetPath = $targetPath.Substring($arrow + 4) }
                try { $leaf = [System.IO.Path]::GetFileName($targetPath); $extension = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant() } catch { return }
                $scanExtensions = @('.exe','.dll','.scr','.com','.sys','.cpl','.ocx','.msi','.msp','.bat','.cmd','.ps1','.psm1','.psd1','.vbs','.vbe','.js','.jse','.hta','.wsf','.wsh','.reg','.lnk','.url','.inf','.docm','.xlsm','.pptm','.pdf')

                $q.Enqueue(('FILE|{0}|{1}|{2}' -f $Event.MessageData.Drive, $kind, $path))
            } | Out-Null
            $ids += $sourceId
        }
        $errorSourceId = 'USBMON-' + $Drive.Replace(':','') + '-ERROR-' + [guid]::NewGuid().ToString('N')
        Register-ObjectEvent -InputObject $watcher -EventName Error -SourceIdentifier $errorSourceId -MessageData $messageData -Action {
            [void]$Event.MessageData.Overflow.TryAdd([string]$Event.MessageData.Drive, $true)
        } | Out-Null
        $ids += $errorSourceId
        $watcher.EnableRaisingEvents = $true
        $script:fileWatchers[$Drive] = $watcher
        $script:fileWatcherSources[$Drive] = $ids
        Add-LogLine ('文件名/属性变化监听已开启  {0}  （不读取文件内容）' -f $Drive)
    } catch {
        foreach ($sourceId in $ids) {
            Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
            Get-Job -Name $sourceId -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $watcher) { $watcher.Dispose() }
        Add-LogLine ('文件监听未能开启 {0}：{1}' -f $Drive, $_.Exception.Message)
    }
}
function Remove-VolumeWatcher([string] $Drive) {
    if ($script:fileWatcherSources.ContainsKey($Drive)) {
        foreach ($sourceId in $script:fileWatcherSources[$Drive]) {
            Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
            Get-Job -Name $sourceId -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        $script:fileWatcherSources.Remove($Drive)
    }
    if ($script:fileWatchers.ContainsKey($Drive)) {
        try { $script:fileWatchers[$Drive].EnableRaisingEvents = $false; $script:fileWatchers[$Drive].Dispose() } catch {}
        $script:fileWatchers.Remove($Drive)
    }
    $overflow = $false
    [void]$script:fileWatcherOverflow.TryRemove($Drive, [ref]$overflow)
    $script:fileWatcherRecoveryAt.Remove($Drive)
}
function Reset-UsbVolumeScanState([string] $Drive, [string] $InstanceId) {
    $script:inventoriedVolumes.Remove($Drive + '|' + $InstanceId)
    $overflow = $false
    [void]$script:fileWatcherOverflow.TryRemove($Drive, [ref]$overflow)
    $script:fileWatcherRecoveryAt.Remove($Drive)
}
function Prune-UsbProcessChains {
    foreach ($processId in @($script:trackedUsbProcesses.Keys)) {
        $record = $null
        if (!$script:trackedUsbProcesses.TryGetValue([int]$processId, [ref]$record)) { continue }
        $process = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
        if (!$process) {
            $discard = $null
            [void]$script:trackedUsbProcesses.TryRemove([int]$processId, [ref]$discard)
            continue
        }
        if ([long]$record.CreationFileTime -gt 0) {
            try {
                if ($process.StartTime.ToFileTimeUtc() -ne [long]$record.CreationFileTime) {
                    $discard = $null
                    [void]$script:trackedUsbProcesses.TryRemove([int]$processId, [ref]$discard)
                }
            } catch {}
        }
    }
}
function Get-UsbProcessChainText($Record) {
    $segments = New-Object 'System.Collections.Generic.List[string]'
    if ($queue.Count -eq 0) { throw '设备已断开或存储卷映射已变化，请刷新后重试' }
$seen = @{}
    $cursor = $Record
    while ($cursor -and $segments.Count -lt 16) {
        $pid = [int]$cursor.ProcessId
        if ($seen.ContainsKey($pid)) { break }
        $seen[$pid] = $true
        $leaf = [System.IO.Path]::GetFileName([string]$cursor.Image)
        if (!$leaf) { $leaf = [string]$cursor.ProcessName }
        $segments.Insert(0, $leaf)
        if ($pid -eq [int]$cursor.RootPid) { break }
        $parent = $null
        if (!$script:trackedUsbProcesses.TryGetValue([int]$cursor.ParentProcessId, [ref]$parent)) {
            $rootLeaf = [System.IO.Path]::GetFileName([string]$cursor.RootImage)
            if ($rootLeaf -and $segments[0] -ne $rootLeaf) { $segments.Insert(0, $rootLeaf) }
            break
        }
        $cursor = $parent
    }
    return ('[{0}] {1}  {2}' -f [string]$Record.RootDetection, [string]$Record.Drive, ($segments -join ' → '))
}
function Get-UsbProcessRiskReason($Record) {
    $name = [System.IO.Path]::GetFileName([string]$Record.Image).ToLowerInvariant()
    if ([string]$Record.RootDetection -eq '命令行显式引用 USB') { return '' }
    $commandLine = [string]$Record.CommandLine
    $encodedHidden = ($commandLine -match '(?i)(-encodedcommand\b|-enc\s+[A-Za-z0-9+/]{20,})' -and $commandLine -match '(?i)(-windowstyle\s+hidden|\s-w\s+hidden|-executionpolicy\s+bypass)')
    $downloadExecute = ($commandLine -match '(?i)(downloadstring|downloadfile|invoke-webrequest|start-bitstransfer|frombase64string)' -and $commandLine -match '(?i)(invoke-expression|\biex\b|start-process|assembly\]::load)')
    if ($encodedHidden -and $downloadExecute) {
        return 'USB 程序链同时出现隐藏编码与下载执行特征'
    }
    if ($downloadExecute) {
        return 'USB 程序链出现下载后执行特征'
    }
    if (($name -eq 'reg.exe' -and $commandLine -match '(?i)\badd\b.*\\(run|runonce)(?:\\|\s|$)') -or
        ($name -eq 'schtasks.exe' -and $commandLine -match '(?i)\s/create\b') -or
        ($name -eq 'sc.exe' -and $commandLine -match '(?i)\screate\s') -or
        ($commandLine -match '(?i)(set-itemproperty|new-itemproperty|new-item).*(?:\\CurrentVersion\\Run(?:Once)?\b|\\RunOnce\b|\\Startup\\)') -or
        ($commandLine -match '(?i)(register-scheduledtask|new-service|new-scheduledtaskaction).*(runonce|currentversion|startup|scheduledtask|service)')) {
        return 'USB 程序链出现新增启动项、计划任务或服务的命令特征'
    }
    return ''
}
function Get-UsbTransferHint($Record) {
    $leaf = [System.IO.Path]::GetFileName([string]$Record.Image).ToLowerInvariant()
    if ($leaf -notin @('robocopy.exe', 'xcopy.exe', 'copy.exe', 'move.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe')) { return '' }
    $commandLine = [string]$Record.CommandLine
    if ($commandLine -notmatch '(?i)(robocopy|xcopy|copy-item|move-item|\bcopy\b|\bmove\b)') { return '' }
    $usbPath = [string]$Record.Drive + '\'
    $argumentText = $commandLine
    $toolMatch = [regex]::Match($commandLine, '(?i)(copy-item|move-item|robocopy|xcopy|copy\.exe|move\.exe|\bcopy\b|\bmove\b)')
    if ($toolMatch.Success) { $argumentText = $commandLine.Substring($toolMatch.Index + $toolMatch.Length) }
    $pathMatches = [regex]::Matches($argumentText, '(?i)([A-Z]:\\(?:"[^"]*"|''[^'']*''|[^\s]+))')
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pathMatch in $pathMatches) {
        $path = [string]$pathMatch.Groups[1].Value
        $path = $path.Trim([char[]]@([char]34, [char]39))
        if ($path -match '^[A-Z]:\\') { $paths.Add($path) }
    }
    $usbPosition = -1
    $localPosition = -1
    for ($index = 0; $index -lt $paths.Count; $index++) {
        if ($paths[$index].StartsWith($usbPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($usbPosition -lt 0) { $usbPosition = $index }
        } elseif ($localPosition -lt 0) { $localPosition = $index }
    }
    if ($usbPosition -lt 0 -or $localPosition -lt 0) { return '' }
    if ($localPosition -lt $usbPosition) { return '  [命令行包含文件操作及 USB 路径]' }
    return '  [命令行包含文件操作及 USB 路径]'
}
function Get-UsbPathReferenceHint($Record) {
    $commandLine = [string]$Record.CommandLine
    if ($commandLine -match '(?i)[A-Z]:\\Users\\[^\\\s"]+\\(?:Desktop|Documents|Downloads|Pictures|Videos|AppData)\\') {
        return '  [命令行提及本机资料目录；无法据此确认实际读取]'
    }
    return ''
}
function Drain-FileEvents {
    $monitorError = ''
    while ($script:processMonitorErrors.TryDequeue([ref]$monitorError)) {
        $script:processMonitorStatus = '事件处理异常'
        Add-LogLine ('进程事件处理失败：' + $monitorError)
    }
    foreach ($drive in @($script:fileWatcherOverflow.Keys)) {
        $overflowed = $false
        if (!$script:fileWatcherOverflow.TryRemove([string]$drive,[ref]$overflowed)) { continue }
        if (!$script:activeUsbDrives.ContainsKey([string]$drive) -or !$script:activeUsbDrives[[string]$drive]) { continue }
        $lastRecovery = $null
        if ($script:fileWatcherRecoveryAt.ContainsKey([string]$drive)) { $lastRecovery = [datetime]$script:fileWatcherRecoveryAt[[string]$drive] }
        if ($lastRecovery -and ((Get-Date)-$lastRecovery).TotalSeconds -lt 60) { continue }
        $script:fileWatcherRecoveryAt[[string]$drive] = Get-Date
        $line = '{0}  USB {1} 文件事件队列溢出；期间事件可能未逐条显示，未据此判危险' -f (Get-Date -Format 'HH:mm:ss'),[string]$drive
        [void]$script:fileEventList.Items.Insert(0,$line)
        Add-LogLine ('USB {0} 文件事件队列溢出；安排仅读取名称/属性的有限巡检' -f [string]$drive)
        Start-UsbMetadataInventory -Paths @([string]$drive + '\') -Source '事件队列恢复'
    }
    if ($script:usbProcessEventOverflow.ContainsKey('USB')) {
        $overflowed = $false
        if ($script:usbProcessEventOverflow.TryRemove('USB',[ref]$overflowed)) { Add-LogLine 'USB 关联进程事件达到上限；该时段链路可能不完整' }
    }
    $fileChangeCounts = @{}
    $fileNoticesSeen = @{}
    $entry = ''
    $count = 0
    while ($count -lt 200) {
        $hasEntry = $script:processEvents.TryDequeue([ref]$entry)
        if (!$hasEntry) { $hasEntry = $script:fileEvents.TryDequeue([ref]$entry) }
        if (!$hasEntry) { break }
        if ($entry.StartsWith('FILE|')) {
            $parts = [System.Text.RegularExpressions.Regex]::Split($entry,'\|',5)
            if ($parts.Count -ge 5) {
                $drive = [string]$parts[1]
                $kind = [string]$parts[2]
                $path = [string]$parts[4]
                if (!$fileChangeCounts.ContainsKey($drive)) { $fileChangeCounts[$drive] = 0 }
                $fileChangeCounts[$drive]++
                $targetPath = $path
                $arrow = $targetPath.LastIndexOf(' -> ')
                if ($arrow -ge 0) { $targetPath = $targetPath.Substring($arrow + 4) }
                $attributes = [System.IO.FileAttributes][int]$parts[3]
                $changeName = switch ($kind) { 'CREATED' { '创建' } 'CHANGED' { '修改' } 'RENAMED' { '重命名' } 'DELETED' { '删除' } default { $kind } }
                [void]$script:fileEventList.Items.Insert(0,('{0}  {1}  {2}' -f (Get-Date -Format 'HH:mm:ss'),$changeName,$path))
                $notice = Get-UsbFileMetadataNotice $drive $kind $path $attributes
                if ($notice) {
                    $noticeKey = $notice.Kind + '|' + $notice.Path
                    if (!$fileNoticesSeen.ContainsKey($noticeKey)) {
                        $fileNoticesSeen[$noticeKey] = $true
                        $line = '{0}  USB 文件线索  {1}  {2}' -f (Get-Date -Format 'HH:mm:ss'),$notice.Name,$notice.Detail
                        [void]$script:fileEventList.Items.Insert(0,$line)
                        if ($notice.NeedsReview) { Add-LogLine ('USB 文件属性：' + $notice.Name) }
                    }
                }
            }
        } elseif ($entry.StartsWith('PROCESS|')) {
            try {
                $processInfo = $entry.Substring(8) | ConvertFrom-Json -ErrorAction Stop
                $chainText = Get-UsbProcessChainText $processInfo
                $transferHint = Get-UsbTransferHint $processInfo
                $pathHint = if ($transferHint) { '' } else { Get-UsbPathReferenceHint $processInfo }
                $line = '{0}  USB 关联程序链  {1}{2}{3}' -f (Get-Date -Format 'HH:mm:ss'),$chainText,$transferHint,$pathHint
                $reason = Get-UsbProcessRiskReason $processInfo
                if ($reason) {
                    $line += '  [命令行线索，未确认执行结果]'
                    Add-LogLine ('命令行特征：' + $reason + '  ' + [string]$processInfo.Image)
                }
                [void]$script:fileEventList.Items.Insert(0,$line)
            } catch { [void]$script:fileEventList.Items.Insert(0,('{0}  USB 进程事件无法解析' -f (Get-Date -Format 'HH:mm:ss'))) }
        }
        $count++
    }
    foreach ($drive in @($fileChangeCounts.Keys)) {
        [void]$script:fileEventList.Items.Insert(0,('{0}  USB {1} 文件变化 {2} 条' -f (Get-Date -Format 'HH:mm:ss'),$drive,$fileChangeCounts[$drive]))
    }
    while ($script:fileEventList.Items.Count -gt 200) { $script:fileEventList.Items.RemoveAt($script:fileEventList.Items.Count - 1) }
}
function Start-Worker([string] $Operation, [string] $Body, [bool] $Elevate) {
    if (!(Test-Path -LiteralPath $script:stateFolder)) { New-Item -ItemType Directory -Path $script:stateFolder -Force | Out-Null }
    $reportPath = Join-Path $script:stateFolder (([guid]::NewGuid().ToString('N')) + '.result')
    $reportLiteral = ConvertTo-PsLiteral $reportPath
    $wrapped = '$ErrorActionPreference = "Stop"; $workerReport = "OK"; try { ' + $Body + '; [System.IO.File]::WriteAllText(' + $reportLiteral + ', [string]$workerReport, [System.Text.Encoding]::Unicode); exit 0 } catch { [System.IO.File]::WriteAllText(' + $reportLiteral + ', ("ERROR|" + $_.Exception.Message), [System.Text.Encoding]::Unicode); exit 1 }'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
    $parameters = @{
        FilePath = $script:powershellPath
        ArgumentList = ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
        PassThru = $true
        WindowStyle = 'Hidden'
        ErrorAction = 'Stop'
    }
    if ($Elevate) { $parameters.Verb = 'RunAs' }
    $process = Start-Process @parameters
    $processStartTime = 0L
    try { $processStartTime = $process.StartTime.ToFileTimeUtc() } catch {}
    $script:pendingOperations[$process.Id] = [pscustomobject]@{ Operation = $Operation; ReportPath = $reportPath; ProcessStartTime = $processStartTime }
    Add-LogLine ('已启动 {0}{1}' -f $Operation, $(if ($Elevate) { '（等待系统权限确认）' } else { '' }))
}
function Start-UsbMetadataInventory([string[]] $Paths, [string] $Source) {
    if ($script:metadataInventoryActive) {
        foreach ($path in @($Paths)) {
            try { $fullPath = [System.IO.Path]::GetFullPath([string]$path) } catch { continue }
            if ($script:activeMetadataRoots.ContainsKey($fullPath) -or $script:queuedMetadataRoots.ContainsKey($fullPath)) { continue }
            if ($script:pendingMetadataScans.Count -ge 64) { Add-LogLine 'USB 巡检排队已满；本次手动巡检未排入'; break }
            $script:queuedMetadataRoots[$fullPath] = $true
            $script:pendingMetadataScans.Enqueue([pscustomobject]@{ Path=$fullPath; Source=$Source })
        }
        return
    }
    $validVolumes = @($script:currentUsbVolumes)
    $roots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @($Paths)) {
        if (!$path) { continue }
        try { $fullPath = [System.IO.Path]::GetFullPath($path) } catch { continue }
        foreach ($volume in $validVolumes) {
            $root = [string]$volume.Drive + '\'
            if ($fullPath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullPath -PathType Container)) {
                $roots.Add([pscustomobject]@{ Path=$fullPath; Drive=[string]$volume.Drive; InstanceId=[string]$volume.InstanceId })
                break
            }
        }
    }
    if ($roots.Count -eq 0) { Add-LogLine '没有可巡检的 USB 存储卷'; return }
    $script:activeMetadataRoots = @{}
    foreach ($root in $roots) { $script:activeMetadataRoots[[string]$root.Path] = $true }
    $rootsJson = ConvertTo-Json -InputObject @($roots.ToArray()) -Compress -Depth 3
    $rootsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rootsJson))
    $body = @'
$roots = @(ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(__ROOTS__))) -ErrorAction Stop)
$usbDriveMap = @{}
Import-Module (Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1') -ErrorAction Stop
foreach ($disk in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
    foreach ($partition in @(Get-CimAssociatedInstance -InputObject $disk -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop)) {
        foreach ($logicalDisk in @(Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -ErrorAction Stop)) {
            if ($logicalDisk.DeviceID) { $usbDriveMap[$logicalDisk.DeviceID.ToUpperInvariant()] = [string]$disk.PNPDeviceID }
        }
    }
}
$queue = New-Object 'System.Collections.Generic.Queue[string]'
$skippedVolumes = 0
foreach ($root in $roots) {
    $driveKey = ([string]$root.Drive).ToUpperInvariant()
    if (!$usbDriveMap.ContainsKey($driveKey) -or ![string]::Equals([string]$usbDriveMap[$driveKey],[string]$root.InstanceId,[System.StringComparison]::OrdinalIgnoreCase)) { $skippedVolumes++; continue }
    if (Test-Path -LiteralPath ([string]$root.Path) -PathType Container) { $queue.Enqueue([string]$root.Path) }
}
if ($queue.Count -eq 0) { throw '设备已断开或存储卷映射已变化，请刷新后重试' }
$seen = @{}
$files = 0
$directories = 0
$entries = 0
$unreadable = 0
$limited = $false
$findings = New-Object 'System.Collections.Generic.List[object]'
$maxEntries = 10000
$maxFindings = 100
$executionExtensions = @('.exe','.dll','.scr','.com','.bat','.cmd','.ps1','.psm1','.vbs','.js','.hta','.wsf','.msi','.lnk','.url')
while ($queue.Count -gt 0 -and $entries -lt $maxEntries) {
    $current = $queue.Dequeue()
    if ($seen.ContainsKey($current)) { continue }
    $seen[$current] = $true
    try {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
            $entries++
            if ($entries -gt $maxEntries) { $limited = $true; break }
            try { $attributes = [System.IO.File]::GetAttributes($entry) } catch { $unreadable++; continue }
            if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $leaf = [System.IO.Path]::GetFileName($entry)
            if ($attributes -band [System.IO.FileAttributes]::Directory) {
                $directories++
                if ($leaf -notin @('$RECYCLE.BIN','System Volume Information') -and $queue.Count -lt $maxEntries) { $queue.Enqueue($entry) }
                continue
            }
            $files++
            if ($findings.Count -ge $maxFindings) { continue }
            $extension = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant()
            $reason = ''
            if ($leaf -ieq 'autorun.inf') { $reason = '检测到文件：autorun.inf' }
            elseif ($leaf -match '(?i)\.(pdf|docx?|xlsx?|pptx?|jpg|jpeg|png|txt|zip|rar)\.(exe|scr|com|bat|cmd|ps1|vbs|js|hta|wsf|msi)$') { $reason = '文件名包含双扩展名。' }
            elseif (($attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) -and $extension -in $executionExtensions) { $reason = '执行类文件或快捷方式带隐藏/系统属性。' }
            if ($reason) { $findings.Add([pscustomobject]@{ Path=$entry; Reason=$reason }) }
        }
    } catch { $unreadable++ }
}
if ($queue.Count -gt 0) { $limited = $true }
$summary = [pscustomobject]@{ Files=$files; Directories=$directories; Entries=$entries; Unreadable=$unreadable; SkippedVolumes=$skippedVolumes; Limited=$limited; ContentBytesRead=0; Findings=@($findings.ToArray()) }
$workerReport = 'META|' + (ConvertTo-Json -InputObject $summary -Compress -Depth 4)
'@
    $body = $body.Replace('__ROOTS__',(ConvertTo-PsLiteral $rootsBase64))
    $script:metadataInventoryActive = $true
    try { Start-Worker ('USB 元数据巡检|' + $Source) $body $false }
    catch { $script:metadataInventoryActive = $false; $script:activeMetadataRoots = @{}; Add-LogLine ('USB 元数据巡检启动失败：{0}' -f $_.Exception.Message) }
}
function Get-RelatedDeviceInstanceIds([string] $InstanceId) {
    $selected = $script:knownDevices[$InstanceId]
    if (!$selected -or !$selected.ContainerId) { return @($InstanceId) }
    $ids = @($script:knownDevices.Values | Where-Object { [string]::Equals([string]$_.ContainerId,[string]$selected.ContainerId,[System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [string]$_.InstanceId } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return @($InstanceId) }
    return $ids
}
function Start-SelectedDeviceControl([string[]] $InstanceIds, [bool] $Disable) {
    $uniqueIds = @($InstanceIds | Where-Object { $_ } | Select-Object -Unique)
    if ($uniqueIds.Count -eq 0) { Add-LogLine '没有有效的 USB 设备标识'; return }
    $literals = @($uniqueIds | ForEach-Object { ConvertTo-PsLiteral ([string]$_) }) -join ','
    if ($Disable) { $operation = '禁用 USB 设备接口'; $command = 'Disable-PnpDevice' }
    else { $operation = '恢复 USB 设备接口'; $command = 'Enable-PnpDevice' }
    $body = '$instanceIds = @(' + $literals + '); Import-Module PnpDevice -ErrorAction Stop; $failed = New-Object ''System.Collections.Generic.List[string]''; foreach ($id in $instanceIds) { try { ' + $command + ' -InstanceId $id -Confirm:$false -ErrorAction Stop | Out-Null } catch { $failed.Add(($id + '': '' + $_.Exception.Message)) } }; if ($failed.Count -gt 0) { throw ($failed -join ''；'') }'
    try { Start-Worker ($operation + '（接口 ' + $uniqueIds.Count + ' 个）') $body $true }
    catch { Add-LogLine ($operation + '失败：' + $_.Exception.Message) }
}
function Get-TrackedProcessCountForDevice([string[]] $InstanceIds) {
    Prune-UsbProcessChains
    $count = 0
    foreach ($record in $script:trackedUsbProcesses.Values) {
        if ($InstanceIds -contains [string]$record.DeviceInstanceId) { $count++ }
    }
    return $count
}
function Start-UsbEmergencyBlock([string[]] $InstanceIds) {
    Prune-UsbProcessChains
    $matching = @($script:trackedUsbProcesses.Values | Where-Object {
        $InstanceIds -contains [string]$_.DeviceInstanceId
    })
    $processSpecs = @($matching | ForEach-Object {
        [pscustomobject]@{ ProcessId = [int]$_.ProcessId; Image = [string]$_.Image; CreationFileTime = [long]$_.CreationFileTime; DeviceInstanceId=[string]$_.DeviceInstanceId }
    })
    $specJson = ConvertTo-Json -InputObject @($processSpecs) -Compress -Depth 3
    $specBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($specJson))
    $idsJson = ConvertTo-Json -InputObject @($InstanceIds) -Compress -Depth 2
    $idsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($idsJson))
    $body = @'
$specs = @(ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(__SPECS__))) -ErrorAction Stop)
$instanceIds = @(ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(__IDS__))) -ErrorAction Stop)
$failures = New-Object 'System.Collections.Generic.List[string]'
Import-Module PnpDevice -ErrorAction Stop
$disabledCount = 0
foreach ($instanceId in $instanceIds) {
    try { Disable-PnpDevice -InstanceId ([string]$instanceId) -Confirm:$false -ErrorAction Stop | Out-Null; $disabledCount++ }
    catch { $failures.Add(('设备接口停用失败：' + [string]$instanceId + '；' + $_.Exception.Message)) }
}
$allProcesses = @()
if ($specs.Count -gt 0) {
    try { $allProcesses = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    catch { $failures.Add(('USB 设备已尝试停用，但无法读取进程树：' + $_.Exception.Message)) }
}
$byId = @{}
foreach ($item in $allProcesses) { $byId[[int]$item.ProcessId] = $item }
$targets = @{}
foreach ($spec in $specs) {
    $pid = [int]$spec.ProcessId
    if (!$byId.ContainsKey($pid)) { continue }
    $candidate = $byId[$pid]
    $candidateTime = 0L
    try { $candidateTime = ([datetime]$candidate.CreationDate).ToFileTimeUtc() } catch {}
    $pathMatches = [string]::Equals([string]$candidate.ExecutablePath, [string]$spec.Image, [System.StringComparison]::OrdinalIgnoreCase)
    $timeMatches = ([long]$spec.CreationFileTime -gt 0 -and [Math]::Abs([double]($candidateTime - [long]$spec.CreationFileTime)) -le 10000000)
    if ($pathMatches -and $timeMatches) {
        $targets[$pid] = [pscustomobject]@{ ProcessId = $pid; ParentProcessId = [int]$candidate.ParentProcessId; Image = [string]$candidate.ExecutablePath; CreationFileTime = $candidateTime; Depth = 0 }
    } else {
        $failures.Add(('已跟踪的根进程 PID {0} 身份校验失败；为避免误杀未执行结束操作' -f $pid))
    }
}
$changed = $true
while ($changed -and $targets.Count -lt 512) {
    $changed = $false
    foreach ($candidate in $allProcesses) {
        $candidatePid = [int]$candidate.ProcessId
        $parentPid = [int]$candidate.ParentProcessId
        if ($targets.ContainsKey($candidatePid) -or !$targets.ContainsKey($parentPid)) { continue }
        $parentTarget = $targets[$parentPid]
        $parentProcess = $byId[$parentPid]
        if (!$parentProcess) { continue }
        $parentTime = 0L
        try { $parentTime = ([datetime]$parentProcess.CreationDate).ToFileTimeUtc() } catch {}
        $parentIdentityMatches = [string]::Equals([string]$parentProcess.ExecutablePath, [string]$parentTarget.Image, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([long]$parentTarget.CreationFileTime -gt 0 -and [Math]::Abs([double]($parentTime - [long]$parentTarget.CreationFileTime)) -le 10000000)
        if (!$parentIdentityMatches) { continue }
        $candidateTime = 0L
        try { $candidateTime = ([datetime]$candidate.CreationDate).ToFileTimeUtc() } catch {}
        if ($candidateTime -le [long]$parentTarget.CreationFileTime) { continue }
        $targets[$candidatePid] = [pscustomobject]@{ ProcessId = $candidatePid; ParentProcessId = $parentPid; Image = [string]$candidate.ExecutablePath; CreationFileTime = $candidateTime; Depth = ([int]$parentTarget.Depth + 1) }
        $changed = $true
    }
}
foreach ($target in @($targets.Values | Sort-Object Depth -Descending)) {
    $process = Get-Process -Id ([int]$target.ProcessId) -ErrorAction SilentlyContinue
    if (!$process) { continue }
    try {
        $pathMatches = [string]::Equals([string]$process.Path, [string]$target.Image, [System.StringComparison]::OrdinalIgnoreCase)
        $timeMatches = ([Math]::Abs([double]($process.StartTime.ToFileTimeUtc() - [long]$target.CreationFileTime)) -le 10000000)
        if ($pathMatches -and $timeMatches) {
            $process.Kill()
            $process.WaitForExit(3000)
            if (Get-Process -Id ([int]$target.ProcessId) -ErrorAction SilentlyContinue) {
                $failures.Add(('PID {0} 已发送结束请求，但仍在运行' -f $target.ProcessId))
            }
        } else {
            $failures.Add(('PID {0} 身份校验失败，未结束以避免误杀' -f $target.ProcessId))
        }
    } catch { $failures.Add(('PID {0} 未能结束：{1}' -f $target.ProcessId, $_.Exception.Message)) }
}
if ($disabledCount -ne $instanceIds.Count -or $failures.Count -gt 0) { throw ('阻断未能完整完成。接口已停用 {0}/{1}；{2}' -f $disabledCount,$instanceIds.Count,($failures -join '；')) }
'@
    $body = $body.Replace('__SPECS__', (ConvertTo-PsLiteral $specBase64)).Replace('__IDS__', (ConvertTo-PsLiteral $idsBase64))
    try { Start-Worker '一键阻断 USB 设备及关联程序链' $body $true }
    catch { Add-LogLine ('紧急阻断启动失败：{0}' -f $_.Exception.Message) }
}
function Check-PendingOperations {
    foreach ($processId in @($script:pendingOperations.Keys)) {
        $entry = $script:pendingOperations[$processId]
        $running = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($running) {
            if (-not $entry.PSObject.Properties['ProcessStartTime'] -or $entry.ProcessStartTime -le 0) { continue }
            try { if ($running.StartTime.ToFileTimeUtc() -eq $entry.ProcessStartTime) { continue } } catch { continue }
        }
        $result = ''
        if (Test-Path -LiteralPath $entry.ReportPath) {
            try { $result = [System.IO.File]::ReadAllText($entry.ReportPath,[System.Text.Encoding]::Unicode) } catch {}
            Remove-Item -LiteralPath $entry.ReportPath -Force -ErrorAction SilentlyContinue
        }
        if ($entry.Operation -like 'USB 元数据巡检|*') {
            $script:metadataInventoryActive = $false
            if ($result -like 'META|*') {
                try {
                    $summary = $result.Substring(5) | ConvertFrom-Json -ErrorAction Stop
                    $line = 'USB 元数据巡检完成：文件 {0} / 目录 {1} / 条目 {2}；文件内容读取 0 字节' -f $summary.Files,$summary.Directories,$summary.Entries
                    if ([int]$summary.Unreadable -gt 0) { $line += ('；无法访问 {0} 项' -f $summary.Unreadable) }
                    if ($summary.Limited) { $line += '；达到上限，未巡完' }
                    if ([int]$summary.SkippedVolumes -gt 0) { $line += '；设备映射变化，部分卷跳过' }
                    [void]$script:fileEventList.Items.Insert(0,('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'),$line))
                    foreach ($finding in @($summary.Findings)) {
                        $detail = '{0}  USB 名称/属性线索  {1}  {2}' -f (Get-Date -Format 'HH:mm:ss'),$finding.Path,$finding.Reason
                        [void]$script:fileEventList.Items.Insert(0,$detail)
                    }
                    Add-LogLine $line
                } catch { Add-LogLine ('USB 元数据巡检结果无法解析：{0}' -f $_.Exception.Message) }
            } elseif ($result -like 'ERROR|*') { Add-LogLine ('USB 元数据巡检失败：{0}' -f $result.Substring(6)) }
            else { Add-LogLine 'USB 元数据巡检未返回结果' }
        } elseif ($result -like 'ERROR|*') {
            Add-LogLine ('{0} 失败：{1}' -f $entry.Operation,$result.Substring(6))
        } elseif ($result -eq 'OK') {
            Add-LogLine ($entry.Operation + '：系统命令已完成')
        } else {
            Add-LogLine ($entry.Operation + '：未返回有效结果，无法确认完成')
        }
        $script:pendingOperations.Remove($processId)
        if ($entry.Operation -like 'USB 元数据巡检|*') {
            $script:activeMetadataRoots = @{}
            while (!$script:metadataInventoryActive -and $script:pendingMetadataScans.Count -gt 0) {
                $nextScan = $script:pendingMetadataScans.Dequeue()
                $script:queuedMetadataRoots.Remove([string]$nextScan.Path)
                Start-UsbMetadataInventory -Paths @([string]$nextScan.Path) -Source ([string]$nextScan.Source)
            }
        }
    }
}
function Update-StartupUi {
    if (Test-Path -LiteralPath $script:startupLink) {
        $script:startupButton.Text = '关闭开机自启'
        $script:startupState.Text = '开机自启：已开启'
    } else {
        $script:startupButton.Text = '开启开机自启'
        $script:startupState.Text = '开机自启：未开启'
    }
}
function Refresh-Views($Snapshot) {
    if ($null -eq $Snapshot) { if ($script:scanRequest) { [void]$script:scanRequest.Set() }; return }
    $devices = @($Snapshot.Devices)
    $volumes = @($Snapshot.Volumes)
    $script:currentUsbVolumes = $volumes
    $currentCompositeDevices = @{}
    foreach ($notice in @(Get-UsbCompositeDeviceWarnings $devices)) {
        $currentCompositeDevices[$notice.Key] = $true
        if (!$script:knownCompositeDevices.ContainsKey($notice.Key)) {
            [void]$script:fileEventList.Items.Insert(0,('{0}  {1}  {2}' -f (Get-Date -Format 'HH:mm:ss'),$notice.Title,$notice.Body))
        }
    }
    $script:knownCompositeDevices = $currentCompositeDevices
    $currentDriveSet = @{}
    foreach ($volume in $volumes) { $currentDriveSet[[string]$volume.Drive] = $true }
    foreach ($driveKey in @($script:activeUsbDrives.Keys)) { if (-not $currentDriveSet.ContainsKey($driveKey)) { $script:activeUsbDrives[$driveKey] = $false } }
    foreach ($volumeKey in $volumes) {
        $script:usbDriveInstances[$volumeKey.Drive] = [string]$volumeKey.InstanceId
        $script:activeUsbDrives[$volumeKey.Drive] = $true
    }
    $currentDevices = @{}
    $currentVolumes = @{}
    $selectedDeviceIds = @{}
    foreach ($selected in $script:deviceList.SelectedItems) { $selectedDeviceIds[[string]$selected.Tag] = $true }
    $selectedDrives = @{}
    foreach ($selected in $script:volumeList.SelectedItems) { $selectedDrives[[string]$selected.Text] = $true }
    $script:deviceList.BeginUpdate()
    $script:deviceList.Items.Clear()
    foreach ($device in $devices) {
        $currentDevices[$device.InstanceId] = $device
        $item = New-Object System.Windows.Forms.ListViewItem([string]$device.Type)
        $item.Tag = [string]$device.InstanceId
        [void]$item.SubItems.Add([string]$device.Name)
        [void]$item.SubItems.Add([string]$device.Status)
        [void]$item.SubItems.Add([string]$device.Class)
        [void]$script:deviceList.Items.Add($item)
        $item.Selected = $selectedDeviceIds.ContainsKey([string]$device.InstanceId)
        if (!$script:hasInitialSnapshot) {
            Add-LogLine ('已连接  {0}  {1}' -f $device.Type, $device.Name)
        } elseif (!$script:knownDevices.ContainsKey($device.InstanceId)) {
            Add-LogLine ('检测到设备  {0}  {1}' -f $device.Type, $device.Name)
        }
    }
    foreach ($cachedId in @($script:containerIdCache.Keys)) {
        if (!$currentDevices.ContainsKey($cachedId)) { $script:containerIdCache.Remove($cachedId) }
    }
    $script:deviceList.EndUpdate()
    $script:emptyDevices.Visible = ($devices.Count -eq 0)

    $script:volumeList.BeginUpdate()
    $script:volumeList.Items.Clear()
    foreach ($volume in $volumes) {
        $currentVolumes[$volume.Drive] = $volume
        if ($script:knownVolumes.ContainsKey($volume.Drive) -and ![string]::Equals([string]$script:knownVolumes[$volume.Drive].InstanceId, [string]$volume.InstanceId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $previousVolume = $script:knownVolumes[$volume.Drive]
            Add-LogLine ('USB 存储已更换  {0}' -f $volume.Drive)
            Reset-UsbVolumeScanState $volume.Drive ([string]$previousVolume.InstanceId)
        }
        $item = New-Object System.Windows.Forms.ListViewItem([string]$volume.Drive)
        $item.Selected = $selectedDrives.ContainsKey([string]$volume.Drive)
        [void]$item.SubItems.Add([string]$volume.Label)
        [void]$item.SubItems.Add((Format-Bytes $volume.Size))
        [void]$item.SubItems.Add((Format-Bytes $volume.Free))
        [void]$item.SubItems.Add([string]$volume.FileSystem)
        [void]$script:volumeList.Items.Add($item)
        if (!$script:hasInitialSnapshot) {
            Add-LogLine ('存储卷已挂载  {0}  {1}' -f $volume.Drive, $volume.Label)
        } elseif (!$script:knownVolumes.ContainsKey($volume.Drive)) {
            Add-LogLine ('USB 存储已挂载  {0}  {1}' -f $volume.Drive, $volume.Label)
        }
        $scanKey = [string]$volume.Drive + '|' + [string]$volume.InstanceId
        if (!$script:inventoriedVolumes.ContainsKey($scanKey)) {
            $script:inventoriedVolumes[$scanKey] = $true
            Start-UsbMetadataInventory -Paths @($volume.Drive + '\') -Source '自动接入'
        }
    }
    $script:volumeList.EndUpdate()
    $script:emptyVolumes.Visible = ($volumes.Count -eq 0)

    if ($script:hasInitialSnapshot) {
        foreach ($oldId in @($script:knownDevices.Keys)) {
            if (!$currentDevices.ContainsKey($oldId)) {
                $old = $script:knownDevices[$oldId]
                Add-LogLine ('设备已移除  {0}  {1}' -f $old.Type, $old.Name)
            }
        }
        foreach ($oldDrive in @($script:knownVolumes.Keys)) {
            if (!$currentVolumes.ContainsKey($oldDrive)) {
                Add-LogLine ('USB 存储已移除  {0}' -f $oldDrive)
                Reset-UsbVolumeScanState $oldDrive ([string]$script:knownVolumes[$oldDrive].InstanceId)
                Remove-VolumeWatcher $oldDrive
            }
        }
    }
    $script:knownDevices = $currentDevices
    $script:knownVolumes = $currentVolumes
    $script:hasInitialSnapshot = $true
    $script:statusLabel.Text = ('设备 {0} | 存储卷 {1} | 进程监听：{2} | {3}' -f $devices.Count, $volumes.Count, $script:processMonitorStatus, (Get-Date -Format 'HH:mm:ss'))
    Drain-FileEvents
    Check-PendingOperations
}

$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'usb-CybersecurityMonitor'
$form.Name = 'UsbCybersecurityMonitorMainWindow'
if (Test-Path -LiteralPath $script:iconPath) {
    try { $script:appIcon = [System.Drawing.Icon]::new($script:iconPath); $form.Icon = $script:appIcon } catch { Add-LogLine ('图标加载失败：{0}' -f $_.Exception.Message) }
}
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1040, 880)
$form.MinimumSize = New-Object System.Drawing.Size(900, 790)
$form.BackColor = [System.Drawing.Color]::FromArgb(5, 5, 5)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font

$script:logoPicture = New-Object System.Windows.Forms.PictureBox
$script:logoPicture.Location = New-Object System.Drawing.Point(24, 18)
$script:logoPicture.Size = New-Object System.Drawing.Size(48, 62)
$script:logoPicture.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:logoPicture.BackColor = [System.Drawing.Color]::White
$script:logoPicture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$logoPath = Join-Path $PSScriptRoot 'logo.jpg'
if (Test-Path -LiteralPath $logoPath) { $sourceLogo = [System.Drawing.Image]::FromFile($logoPath); try { $script:logoPicture.Image = [System.Drawing.Bitmap]::new($sourceLogo) } finally { $sourceLogo.Dispose() } }
$form.Controls.Add($script:logoPicture)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'USB // MONITOR'
$title.Location = New-Object System.Drawing.Point(87, 18)
$title.Size = New-Object System.Drawing.Size(500, 42)
$title.Font = New-Object System.Drawing.Font('Consolas', 21, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'USB DEVICE + PROCESS WATCH  |  METADATA ONLY  |  FILE CONTENTS ARE NEVER READ'
$subtitle.Location = New-Object System.Drawing.Point(90, 60)
$subtitle.Size = New-Object System.Drawing.Size(690, 22)
$subtitle.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($subtitle)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = '正在启动监听器…'
$script:statusLabel.Location = New-Object System.Drawing.Point(27, 97)
$script:statusLabel.Size = New-Object System.Drawing.Size(690, 24)
$script:statusLabel.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($script:statusLabel)

$script:startupState = New-Object System.Windows.Forms.Label
$script:startupState.Location = New-Object System.Drawing.Point(820, 21)
$script:startupState.Size = New-Object System.Drawing.Size(186, 22)
$script:startupState.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$script:startupState.ForeColor = [System.Drawing.Color]::Gainsboro
$script:startupState.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($script:startupState)

$script:startupButton = New-Object System.Windows.Forms.Button
$script:startupButton.Location = New-Object System.Drawing.Point(830, 49)
$script:startupButton.Size = New-Object System.Drawing.Size(176, 32)
$script:startupButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
Set-FlatButton $script:startupButton ([System.Drawing.Color]::White)
$script:startupButton.Add_Click({
    try {
        if (Test-Path -LiteralPath $script:startupLink) {
            Remove-Item -LiteralPath $script:startupLink -Force
            Add-LogLine '已关闭开机自启'
        } else {
            New-StartupShortcut
            Add-LogLine '已开启开机自启（当前 Windows 账户）'
        }
        Update-StartupUi
    } catch { Add-LogLine ('自启设置失败：{0}' -f $_.Exception.Message) }
})
$form.Controls.Add($script:startupButton)

$deviceHeading = New-Object System.Windows.Forms.Label
$deviceHeading.Text = 'USB DEVICES  //  设备类型与即插即用信息'
$deviceHeading.Location = New-Object System.Drawing.Point(26, 126)
$deviceHeading.Size = New-Object System.Drawing.Size(700, 22)
$deviceHeading.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($deviceHeading)

$script:deviceList = New-Object System.Windows.Forms.ListView
$script:deviceList.Location = New-Object System.Drawing.Point(24, 151)
$script:deviceList.Size = New-Object System.Drawing.Size(982, 178)
$script:deviceList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:deviceList.View = [System.Windows.Forms.View]::Details
$script:deviceList.FullRowSelect = $true
$script:deviceList.MultiSelect = $false
$script:deviceList.GridLines = $true
$script:deviceList.HideSelection = $false
$script:deviceList.BackColor = [System.Drawing.Color]::Black
$script:deviceList.ForeColor = [System.Drawing.Color]::White
$script:deviceList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:deviceList.Font = New-Object System.Drawing.Font('Consolas', 9)
[void]$script:deviceList.Columns.Add('设备类型', 120)
[void]$script:deviceList.Columns.Add('设备名称', 490)
[void]$script:deviceList.Columns.Add('状态', 90)
[void]$script:deviceList.Columns.Add('接口类别', 160)
Set-ListTheme $script:deviceList
$form.Controls.Add($script:deviceList)

$script:emptyDevices = New-Object System.Windows.Forms.Label
$script:emptyDevices.Text = '未发现已连接的 USB 外设'
$script:emptyDevices.Location = New-Object System.Drawing.Point(34, 166)
$script:emptyDevices.Size = New-Object System.Drawing.Size(350, 22)
$script:emptyDevices.ForeColor = [System.Drawing.Color]::DarkGray
$script:emptyDevices.BackColor = [System.Drawing.Color]::Black
$form.Controls.Add($script:emptyDevices)

$volumeHeading = New-Object System.Windows.Forms.Label
$volumeHeading.Text = '名称/属性'
$volumeHeading.Location = New-Object System.Drawing.Point(26, 341)
$volumeHeading.Size = New-Object System.Drawing.Size(600, 22)
$volumeHeading.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($volumeHeading)

$script:volumeList = New-Object System.Windows.Forms.ListView
$script:volumeList.Location = New-Object System.Drawing.Point(24, 366)
$script:volumeList.Size = New-Object System.Drawing.Size(982, 116)
$script:volumeList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:volumeList.View = [System.Windows.Forms.View]::Details
$script:volumeList.FullRowSelect = $true
$script:volumeList.GridLines = $true
$script:volumeList.HideSelection = $false
$script:volumeList.BackColor = [System.Drawing.Color]::Black
$script:volumeList.ForeColor = [System.Drawing.Color]::White
$script:volumeList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:volumeList.Font = New-Object System.Drawing.Font('Consolas', 9)
[void]$script:volumeList.Columns.Add('盘符', 90)
[void]$script:volumeList.Columns.Add('卷标', 250)
[void]$script:volumeList.Columns.Add('总容量', 150)
[void]$script:volumeList.Columns.Add('可用空间', 150)
[void]$script:volumeList.Columns.Add('文件系统', 140)
Set-ListTheme $script:volumeList
$form.Controls.Add($script:volumeList)

$script:emptyVolumes = New-Object System.Windows.Forms.Label
$script:emptyVolumes.Text = '未发现已挂载的 USB 存储卷'
$script:emptyVolumes.Location = New-Object System.Drawing.Point(34, 381)
$script:emptyVolumes.Size = New-Object System.Drawing.Size(350, 22)
$script:emptyVolumes.ForeColor = [System.Drawing.Color]::DarkGray
$script:emptyVolumes.BackColor = [System.Drawing.Color]::Black
$form.Controls.Add($script:emptyVolumes)

$fileHeading = New-Object System.Windows.Forms.Label
$fileHeading.Text = '文件变化'
$fileHeading.Location = New-Object System.Drawing.Point(26, 493)
$fileHeading.Size = New-Object System.Drawing.Size(850, 22)
$fileHeading.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($fileHeading)

$script:fileEventList = New-Object System.Windows.Forms.ListBox
$script:fileEventList.Location = New-Object System.Drawing.Point(24, 518)
$script:fileEventList.Size = New-Object System.Drawing.Size(982, 108)
$script:fileEventList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:fileEventList.BackColor = [System.Drawing.Color]::Black
$script:fileEventList.ForeColor = [System.Drawing.Color]::White
$script:fileEventList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:fileEventList.Font = New-Object System.Drawing.Font('Consolas', 8)
$form.Controls.Add($script:fileEventList)

$eventHeading = New-Object System.Windows.Forms.Label
$eventHeading.Text = 'USB行为'
$eventHeading.Location = New-Object System.Drawing.Point(26, 638)
$eventHeading.Size = New-Object System.Drawing.Size(700, 22)
$eventHeading.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($eventHeading)

$script:logList = New-Object System.Windows.Forms.ListBox
$script:logList.SelectionMode = [System.Windows.Forms.SelectionMode]::None
$script:logList.Location = New-Object System.Drawing.Point(24, 663)
$script:logList.Size = New-Object System.Drawing.Size(982, 105)
$script:logList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:logList.BackColor = [System.Drawing.Color]::Black
$script:logList.ForeColor = [System.Drawing.Color]::White
$script:logList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:logList.Font = New-Object System.Drawing.Font('Consolas', 8)
$form.Controls.Add($script:logList)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '立即刷新'
$refreshButton.Location = New-Object System.Drawing.Point(24, 788)
$refreshButton.Size = New-Object System.Drawing.Size(112, 38)
Set-FlatButton $refreshButton ([System.Drawing.Color]::White)
$refreshButton.Add_Click({ try { Refresh-Views } catch { Add-LogLine ('刷新失败：{0}' -f $_.Exception.Message) } })
$form.Controls.Add($refreshButton)

$script:scanButton = New-Object System.Windows.Forms.Button
$script:scanButton.Text = 'USB 元数据巡检'
$script:scanButton.Location = New-Object System.Drawing.Point(148, 788)
$script:scanButton.Size = New-Object System.Drawing.Size(142, 38)
Set-FlatButton $script:scanButton ([System.Drawing.Color]::White)
$script:scanMenu = New-Object System.Windows.Forms.ContextMenuStrip
$scanLocalItem = $script:scanMenu.Items.Add('巡检 USB 名称/属性（不读内容）')
$scanLocalItem.Add_Click({
    $volumes = @($script:currentUsbVolumes)
    if ($volumes.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('未检测到 USB 存储卷。', 'usb-CybersecurityMonitor', 'OK', 'Information') | Out-Null; return }
    $paths = @($volumes | ForEach-Object { $_.Drive + '\' })
    Start-UsbMetadataInventory -Paths $paths -Source '手动扫描'
})
$script:scanButton.Add_Click({
    $script:scanMenu.Show($script:scanButton, 0, $script:scanButton.Height)
})
$form.Controls.Add($script:scanButton)
$script:blockButton = New-Object System.Windows.Forms.Button
$script:blockButton.Text = '一键阻断 USB'
$script:blockButton.Location = New-Object System.Drawing.Point(308, 788)
$script:blockButton.Size = New-Object System.Drawing.Size(228, 38)
Set-FlatButton $script:blockButton ([System.Drawing.Color]::Red)
$script:blockButton.Add_Click({
    if ($script:deviceList.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('先选择设备。', 'usb-CybersecurityMonitor', 'OK', 'Information') | Out-Null
        return
    }
    $selected = $script:deviceList.SelectedItems[0]
    $instanceId = [string]$selected.Tag
    $instanceIds = @(Get-RelatedDeviceInstanceIds $instanceId)
    $deviceName = [string]$selected.SubItems[1].Text
    $deviceType = [string]$selected.SubItems[0].Text
    $chainCount = Get-TrackedProcessCountForDevice $instanceIds
    $scopeText = if ($chainCount -gt 0) { '同时结束关联的 ' + $chainCount + ' 个已跟踪进程及后代。' } else { '未发现关联进程。' }
    if ($instanceIds.Count -gt 1) { $scopeText += '同一设备容器的 ' + $instanceIds.Count + ' 个接口将一并停用。' } else { $scopeText += '仅停用所选设备接口。' }
    $answer = [System.Windows.Forms.MessageBox]::Show(('阻断 ' + $deviceType + ' / ' + $deviceName + '？' + [Environment]::NewLine + $scopeText + [Environment]::NewLine + '确认后请求管理员权限。'), '确认阻断', 'YesNo', 'Warning')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-UsbEmergencyBlock $instanceIds }
})
$form.Controls.Add($script:blockButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中设备'
$restoreButton.Location = New-Object System.Drawing.Point(548, 788)
$restoreButton.Size = New-Object System.Drawing.Size(150, 38)
Set-FlatButton $restoreButton ([System.Drawing.Color]::White)
$restoreButton.Add_Click({
    if ($script:deviceList.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('先选择设备。', 'usb-CybersecurityMonitor', 'OK', 'Information') | Out-Null
        return
    }
    $selected = $script:deviceList.SelectedItems[0]
    $instanceId = [string]$selected.Tag
    $instanceIds = @(Get-RelatedDeviceInstanceIds $instanceId)
    $deviceName = [string]$selected.SubItems[1].Text
    $answer = [System.Windows.Forms.MessageBox]::Show(('恢复 ' + $deviceName + '？将恢复同一设备容器中列出的 ' + $instanceIds.Count + ' 个接口。确认后会请求 UAC。'), '确认恢复', 'YesNo', 'Question')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-SelectedDeviceControl $instanceIds $false }
})
$form.Controls.Add($restoreButton)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = 'usb-CybersecurityMonitor'
$footer.Location = New-Object System.Drawing.Point(710, 795)
$footer.Size = New-Object System.Drawing.Size(296, 24)
$footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$footer.ForeColor = [System.Drawing.Color]::DarkGray
$footer.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$footer.Font = New-Object System.Drawing.Font('Consolas', 8)
$form.Controls.Add($footer)

try { Initialize-StartupDefault } catch { Add-LogLine ('默认开机自启设置失败：{0}' -f $_.Exception.Message) }
Update-StartupUi
Add-LogLine '监听器已启动；USB 设备、文件变化与关联进程监听已开启'
. (Join-Path $PSScriptRoot 'AsyncMonitor.ps1')
Start-UsbBackgroundMonitors
try {
    $script:trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $trayOpenItem = $script:trayMenu.Items.Add('打开 usb-CybersecurityMonitor')
    [void]$trayOpenItem.Add_Click({
        if ($script:form -and !$script:form.IsDisposed) { $script:form.Show(); $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $script:form.Activate() }
    })
    $trayExitItem = $script:trayMenu.Items.Add('退出 usb-CybersecurityMonitor')
    [void]$trayExitItem.Add_Click({
        $script:exitRequested = $true
        if ($script:form -and !$script:form.IsDisposed) { $script:form.Close() }
    })
    $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:trayIcon.Text = 'usb-CybersecurityMonitor - USB 行为监听中'
    $script:trayIcon.ContextMenuStrip = $script:trayMenu
    if ($script:appIcon) { $script:trayIcon.Icon = $script:appIcon } else { $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Shield }
    $script:trayIcon.Visible = $true
    $script:trayIcon.Add_DoubleClick({
        if ($script:form -and !$script:form.IsDisposed) { $script:form.Show(); $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $script:form.Activate() }
    })
} catch { Add-LogLine ('系统托盘图标未能显示：{0}' -f $_.Exception.Message) }

$script:scanTimer = New-Object System.Windows.Forms.Timer
$script:scanTimer.Interval = 150
$script:scanTimer.Add_Tick({
    if ($script:showWindowRequest.WaitOne(0)) {
        $script:startHidden = $false
        $script:form.Show()
        $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:form.Activate()
    }
    try { Receive-UsbBackgroundResults; Drain-FileEvents; Check-PendingOperations } catch { Add-LogLine ('刷新失败：{0}' -f $_.Exception.Message) }
})
$script:scanTimer.Start()
$script:startHidden = [bool]$Tray
$form.Add_Shown({ if ($script:startHidden) { $script:form.Hide() } })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (!$script:exitRequested) {
        $eventArgs.Cancel = $true
        $sender.Hide()
    }
})
$form.Add_FormClosed({
    $script:scanTimer.Stop()
    $script:scanTimer.Dispose()
    if ($script:monitorCancel) { [void]$script:monitorCancel.Set() }
    Close-UsbAsyncTask $script:hardwareTask
    Close-UsbAsyncTask $script:processTask
    Close-UsbAsyncTask $script:fileTask
    foreach ($drive in @($script:fileWatchers.Keys)) { Remove-VolumeWatcher $drive }
    Unregister-Event -SourceIdentifier $script:processEventSource -ErrorAction SilentlyContinue
    Get-Job -Name $script:processEventSource -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($script:toastTimer) { $script:toastTimer.Stop(); $script:toastTimer.Dispose() }
    if ($script:toast -and !$script:toast.IsDisposed) { $script:toast.Close(); $script:toast.Dispose() }
    if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
    if ($script:trayMenu) { $script:trayMenu.Dispose() }
    if ($script:logoPicture.Image) { $script:logoPicture.Image.Dispose() }
    if ($script:appIcon) { $script:appIcon.Dispose() }
    if ($script:showWindowRequest) { $script:showWindowRequest.Dispose() }
    if ($script:instanceMutex -and $script:instanceMutexOwned) { try { $script:instanceMutex.ReleaseMutex() } catch {}; $script:instanceMutex.Dispose() }
})
[System.Windows.Forms.Application]::Run($form)
