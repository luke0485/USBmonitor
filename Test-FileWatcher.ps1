$ErrorActionPreference = 'Stop'
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')) {
    Import-Module (Join-Path $PSHOME ('Modules\' + $module + '\' + $module + '.psd1')) -ErrorAction Stop
}
Add-Type -AssemblyName System.Windows.Forms
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'),[ref]$tokens,[ref]$errors)
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $definition.Extent.Text }
$script:fileEvents=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:fileWatcherOverflow=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
$script:fileWatchers=@{}; $script:fileWatcherSources=@{}; $script:fileWatcherRecoveryAt=@{}
$testRoot=Join-Path $PSScriptRoot ('watcher-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    if(Get-UsbFileMetadataNotice 'D:' 'CREATED' 'D:\folder.exe' ([IO.FileAttributes]::Directory)){throw 'Directory misclassified as executable file'}
    Add-VolumeWatcher $testRoot
    $file=Join-Path $testRoot 'probe.txt'
    [IO.File]::WriteAllBytes($file,[byte[]]@())
    Start-Sleep -Seconds 2
    Rename-Item -LiteralPath $file -NewName 'renamed.txt'
    Start-Sleep -Seconds 2
    Remove-Item -LiteralPath (Join-Path $testRoot 'renamed.txt')
    Start-Sleep -Seconds 2
    $events=@(); $entry=''
    while ($script:fileEvents.TryDequeue([ref]$entry)) { $events += $entry }
    $result=[pscustomobject]@{
        TestLocation='Local project temporary directory; USB contents untouched'
        Created=(@($events | Where-Object { $_ -like '*|CREATED|*' }).Count -gt 0)
        Renamed=(@($events | Where-Object { $_ -like '*|RENAMED|*' }).Count -gt 0)
        Deleted=(@($events | Where-Object { $_ -like '*|DELETED|*' }).Count -gt 0)
        Events=$events
        DoubleExtensionNotice=[bool](Get-UsbFileMetadataNotice 'D:' 'CREATED' 'D:\example.pdf.exe')
        OrdinaryTextNotice=[bool](Get-UsbFileMetadataNotice 'D:' 'CREATED' 'D:\example.txt')
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'file-watcher-test-results.json') -Encoding UTF8
    $result | Select-Object Created,Renamed,Deleted,DoubleExtensionNotice,OrdinaryTextNotice | ConvertTo-Json
    if (-not ($result.Created -and $result.Renamed -and $result.Deleted)) { throw 'File event test failed' }
} finally {
    $sourceIds=@($script:fileWatcherSources[$testRoot])
    Remove-VolumeWatcher $testRoot
    foreach($sourceId in $sourceIds){if(Get-Job -Name $sourceId -ErrorAction SilentlyContinue){throw 'Watcher event job leaked'}}
    if (([IO.Path]::GetFullPath($testRoot)).StartsWith($PSScriptRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
