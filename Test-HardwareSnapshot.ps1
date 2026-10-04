$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'),[ref]$tokens,[ref]$errors)
foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){ Invoke-Expression $definition.Extent.Text }
. (Join-Path $PSScriptRoot 'AsyncMonitor.ps1')
$clock=[Diagnostics.Stopwatch]::StartNew()
$task=New-UsbAsyncTask @('Get-UsbPhysicalDisks','Get-UsbDevices','Get-UsbVolumes','Get-DeviceType','Get-DeviceContainerId') @'
$script:containerIdCache=@{}
$disks=@(Get-UsbPhysicalDisks)
$devices=@(Get-UsbDevices $disks)
$volumes=@(Get-UsbVolumes $disks)
[pscustomobject]@{Disks=$disks | Select-Object Model,PNPDeviceID,Size;Devices=$devices;Volumes=$volumes}
'@ @{}
$startMs=$clock.ElapsedMilliseconds
try {
    while(-not $task.Handle.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 60){Start-Sleep -Milliseconds 100}
    if(-not $task.Handle.IsCompleted){throw 'Hardware snapshot timed out'}
    $output=@($task.PowerShell.EndInvoke($task.Handle))
    if($task.PowerShell.HadErrors){throw ($task.PowerShell.Streams.Error[0].ToString())}
    $output[0] | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $PSScriptRoot 'hardware-snapshot-test-results.json') -Encoding UTF8
    [pscustomobject]@{AsyncStartMs=$startMs;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,2);Devices=@($output[0].Devices).Count;UsbDisks=@($output[0].Disks).Count;UsbVolumes=@($output[0].Volumes).Count;Errors=$task.PowerShell.Streams.Error.Count} | ConvertTo-Json
} finally {
    if($task.Handle.IsCompleted){$task.PowerShell.Dispose();$task.Runspace.Dispose()}else{Close-UsbAsyncTask $task}
}
