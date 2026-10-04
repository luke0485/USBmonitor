$ErrorActionPreference='Stop'
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','CimCmdlets')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop
}
Add-Type -AssemblyName System.Windows.Forms
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'),[ref]$tokens,[ref]$errors)
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $definition.Extent.Text }
. (Join-Path $PSScriptRoot 'AsyncMonitor.ps1')
$script:processEvents=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:fileEvents=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:fileEventsRaw=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:processMonitorErrors=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:activeUsbDrives=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:usbDriveInstances=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
$script:trackedUsbProcesses=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[int,object]'
$script:usbProcessEventOverflow=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatcherOverflow=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatchers=@{}; $script:fileWatcherSources=@{}; $script:fileWatcherRecoveryAt=@{}
$script:activeUsbDrives['D:']=$true; $script:usbDriveInstances['D:']='TEST-ONLY'
$script:logList=New-Object System.Windows.Forms.ListBox
# Deliberately slow the real background function boundary; no USB file access.
function Get-UsbPhysicalDisks { return @() }
function Get-UsbDevices { param($Disks) Start-Sleep -Seconds 3; return @() }
function Get-UsbVolumes { param($Disks) return @() }
function Refresh-Views($Snapshot) { $script:snapshotReceived=$true }
$script:snapshotReceived=$false
$script:processDetected=$false; $script:fileDetected=$false
$script:tickCount=0; $script:maxGap=0.0; $script:lastTick=0.0; $script:probe=$null
$script:clock=[Diagnostics.Stopwatch]::StartNew()
$testRoot=Join-Path $PSScriptRoot ('watcher-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:activeUsbDrives[$testRoot]=$true
$testForm=New-Object System.Windows.Forms.Form
$testForm.ShowInTaskbar=$false; $testForm.Opacity=0
$timer=New-Object System.Windows.Forms.Timer; $timer.Interval=50
try {
    Write-Output 'Starting background workers'
    Start-UsbBackgroundMonitors
    Write-Output 'Workers started'
    $readyDeadline=(Get-Date).AddSeconds(8)
    while (-not $script:backgroundStatus.ContainsKey('Process') -and (Get-Date) -lt $readyDeadline) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 500
    $script:probe=Start-Process "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d /c "ping -n 9 127.0.0.1 >nul & rem D:\UsbCybersecurityMonitor-readonly-probe"' -WindowStyle Hidden -PassThru
    [IO.File]::WriteAllBytes((Join-Path $testRoot 'probe.lnk'),[byte[]]@())
    $script:clock.Restart()
    $timer.Add_Tick({
        try {
            $now=$script:clock.Elapsed.TotalMilliseconds
            if ($script:tickCount -gt 0) { $script:maxGap=[Math]::Max($script:maxGap,$now-$script:lastTick) }
            $script:lastTick=$now; $script:tickCount++
            Receive-UsbBackgroundResults
            $entry=''
            while ($script:processEvents.TryDequeue([ref]$entry)) { if ($entry -match 'UsbCybersecurityMonitor-readonly-probe') { $script:processDetected=$true } }
            while ($script:fileEvents.TryDequeue([ref]$entry)) { if ($entry -match '\|CREATED\|[0-9]+\|.*probe.lnk$') { $script:fileDetected=$true } }
            if ($now -gt 6000 -and $script:snapshotReceived -and $script:processDetected -and $script:fileDetected) { $testForm.Close() }
            if ($now -gt 20000) { $testForm.Close() }
        } catch { Write-Host ('UI test error: '+$_.Exception.Message); $testForm.Close() }
    })
    Write-Output 'Running UI heartbeat'
    $timer.Start()
    [System.Windows.Forms.Application]::Run($testForm)
    $result=[pscustomobject]@{
        UiTicks=$script:tickCount; MaxUiGapMs=[Math]::Round($script:maxGap,1)
        SlowScanReturned=$script:snapshotReceived; ProcessDetected=$script:processDetected; FileEventDetected=$script:fileDetected
        ProcessMode=$script:backgroundStatus['Process']; HandlerErrors=@($script:processMonitorErrors.ToArray())
        WorkerErrors=@(@($script:hardwareTask,$script:processTask,$script:fileTask) | ForEach-Object { for($index=0;$index -lt $_.PowerShell.Streams.Error.Count;$index++){ $_.PowerShell.Streams.Error[$index].ToString() } })
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $PSScriptRoot 'async-test-results.json') -Encoding UTF8
    $result | ConvertTo-Json -Depth 4
    if (-not ($result.SlowScanReturned -and $result.ProcessDetected -and $result.FileEventDetected) -or $result.MaxUiGapMs -gt 750 -or $result.WorkerErrors.Count -or $result.HandlerErrors.Count) { throw 'Async monitoring or UI responsiveness test failed' }
} finally {
    $timer.Stop(); $timer.Dispose(); $testForm.Dispose()
    Remove-VolumeWatcher $testRoot
    if ($script:monitorCancel) { [void]$script:monitorCancel.Set() }
    foreach ($task in @($script:hardwareTask,$script:processTask,$script:fileTask)) {
        if ($null -ne $task) { [void]$task.Handle.AsyncWaitHandle.WaitOne(3000); Close-UsbAsyncTask $task }
    }
    $script:logList.Dispose()
    if (([IO.Path]::GetFullPath($testRoot)).StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
