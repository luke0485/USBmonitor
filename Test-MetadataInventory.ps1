$ErrorActionPreference='Stop'
foreach($m in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')) { Import-Module (Join-Path $PSHOME ('Modules\'+$m+'\'+$m+'.psd1')) }
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Source parse error'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if($f.Name -in @('Start-UsbMetadataInventory','ConvertTo-PsLiteral','Get-UsbProcessRiskReason')){Invoke-Expression $f.Extent.Text}
}
function Add-LogLine($Message) {}
function Start-Worker($Operation,$Body,$Elevate) {$script:capturedBody=$Body}
$testRoot=Join-Path $PSScriptRoot ('watcher-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $testRoot 'ordinary.txt'),'test')
    [IO.File]::WriteAllText((Join-Path $testRoot 'invoice.pdf.exe'),'test')
    $drive=[IO.Path]::GetPathRoot($testRoot).TrimEnd('\')
    $script:currentUsbVolumes=@([pscustomobject]@{Drive=$drive;InstanceId='USBSTOR\TEST'})
    $script:metadataInventoryActive=$false
    Start-UsbMetadataInventory @($testRoot) 'Test'
    function Get-CimInstance { [pscustomobject]@{PNPDeviceID='USBSTOR\TEST'} }
    function Get-CimAssociatedInstance { param($InputObject,$Association,$ErrorAction) [pscustomobject]@{DeviceID=$drive} }
    . ([scriptblock]::Create($script:capturedBody))
    $summary=$workerReport.Substring(5) | ConvertFrom-Json
    if($summary.Files -ne 2 -or $summary.Findings.Count -ne 1 -or $summary.ContentBytesRead -ne 0){throw 'Inventory or hint classification failed'}
    function Get-CimInstance { throw 'Synthetic hardware query failure' }
    $failed=$false
    try { . ([scriptblock]::Create($script:capturedBody)) } catch { $failed=$true }
    if(!$failed){throw 'Hardware failure was silently accepted'}
    $benign=[pscustomobject]@{Image='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine='Invoke-WebRequest https://example.test; Start-Process D:\setup.exe';RootDetection='命令行显式引用 USB'}
    if(Get-UsbProcessRiskReason $benign){throw 'Mere USB reference escalated to risk'}
    $benign.RootDetection='程序从 USB 启动'
    if(!(Get-UsbProcessRiskReason $benign)){throw 'USB execution risk hint lost'}
    Write-Output 'PASS inventory counts, benign files, query failure, and process association classification'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(!$resolved.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
