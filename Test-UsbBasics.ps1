param([switch]$ProcessOnly)
$ErrorActionPreference = 'Stop'
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','CimCmdlets')) {
    Import-Module (Join-Path $PSHOME ('Modules\' + $module + '\' + $module + '.psd1')) -ErrorAction Stop
}
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Script syntax errors' }
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    Invoke-Expression $definition.Extent.Text
}
$script:containerIdCache = @{}
$script:processEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:processMonitorErrors = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:processMonitorDiagnostics = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:activeUsbDrives = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:usbDriveInstances = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
$script:trackedUsbProcesses = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[int,object]'
$script:usbProcessEventOverflow = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:processEventSource = 'USBMON-TEST-' + [guid]::NewGuid().ToString('N')
$script:fileEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:fileWatcherOverflow = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatchers = @{}; $script:fileWatcherSources = @{}; $script:fileWatcherRecoveryAt = @{}
$script:logList = New-Object System.Windows.Forms.ListBox
Write-Output 'Reading USB disks and device interfaces...'
if ($ProcessOnly) {
    $disks=@(); $devices=@()
    $volumes=@([pscustomobject]@{Drive='D:';InstanceId='TEST-USB-PATH-ONLY'})
} else {
    $disks = @(Get-UsbPhysicalDisks)
    $devices = @(Get-UsbDevices $disks)
    $volumes = @(Get-UsbVolumes $disks)
    if ($volumes.Drive -notcontains 'D:') { throw 'Inserted USB volume D: was not detected' }
}
foreach ($volume in $volumes) {
    $script:activeUsbDrives[$volume.Drive] = $true
    $script:usbDriveInstances[$volume.Drive] = $volume.InstanceId
    if (-not $ProcessOnly) { Add-VolumeWatcher $volume.Drive }
}
try {
    Start-ProcessMonitor
    $listenerRegistered = [bool](Get-EventSubscriber -SourceIdentifier $script:processEventSource -ErrorAction SilentlyContinue) -or [bool]$script:processPollAction
    Start-Sleep -Seconds 2
    # Harmless local process with a USB path in its arguments; does not access the drive.
    $probe = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d /c "ping -n 9 127.0.0.1 >nul & rem D:\UsbCybersecurityMonitor-readonly-probe"' -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(12)
    do { Start-Sleep -Milliseconds 250; Invoke-UsbProcessPoll } while ($script:processEvents.IsEmpty -and (Get-Date) -lt $deadline)
    $events = @(); $entry = ''
    while ($script:processEvents.TryDequeue([ref]$entry)) { $events += $entry }
    [pscustomobject]@{
        Disks=$disks | Select-Object Index,Model,PNPDeviceID,Size
        Volumes=$volumes
        Devices=$devices
        CompositeWarnings=@(Get-UsbCompositeDeviceWarnings $devices)
        FileWatcherPaths=@($script:fileWatchers.Values | Select-Object Path,EnableRaisingEvents)
        ProcessListenerRegistered=$listenerRegistered
        ProcessProbeDetected=(@($events | Where-Object { $_ -match 'UsbCybersecurityMonitor-readonly-probe' }).Count -gt 0)
        ProcessEvents=$events
        Logs=@($script:logList.Items)
        MonitorStatus=$script:processMonitorStatus
        SyntheticDriveAssociation=[bool]$ProcessOnly
        HandlerErrors=@($script:processMonitorErrors.ToArray())
        Diagnostics=@($script:processMonitorDiagnostics.ToArray())
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot $(if ($ProcessOnly) {'process-monitor-test-results.json'} else {'usb-test-results.json'})) -Encoding UTF8
} finally {
    foreach ($drive in @($script:fileWatchers.Keys)) { Remove-VolumeWatcher $drive }
    Unregister-Event -SourceIdentifier $script:processEventSource -ErrorAction SilentlyContinue
    Get-Job -Name $script:processEventSource -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    $script:logList.Dispose()
}
