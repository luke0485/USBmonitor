$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))}
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ps1'),[ref]$t,[ref]$e)
foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if($definition.Name -in @('Get-DeviceContainerId','Get-RelatedDeviceInstanceIds','Check-PendingOperations')){Invoke-Expression $definition.Extent.Text}
}
function Get-PnpDeviceProperty { param($InstanceId,$KeyName,$ErrorAction) [pscustomobject]@{Data=$script:testContainer} }
foreach($value in @('invalid','00000000-0000-0000-0000-000000000000','00000000-0000-0000-ffff-ffffffffffff')) {
    $script:containerIdCache=@{};$script:testContainer=$value
    if((Get-DeviceContainerId 'test') -ne ''){throw 'Invalid container accepted'}
}
$script:knownDevices=@{a=[pscustomobject]@{InstanceId='a';ContainerId=''};b=[pscustomobject]@{InstanceId='b';ContainerId=''}}
if(@(Get-RelatedDeviceInstanceIds 'a').Count -ne 1){throw 'Unrelated devices grouped'}
$script:knownDevices=@{a=[pscustomobject]@{InstanceId='a';ContainerId='valid'};b=[pscustomobject]@{InstanceId='b';ContainerId='valid'}}
if(@(Get-RelatedDeviceInstanceIds 'a').Count -ne 2){throw 'Related devices not grouped'}
$script:testLogs=New-Object 'System.Collections.Generic.List[string]'
function Add-LogLine([string]$Message){$script:testLogs.Add($Message)}
function Get-Process { param($Id,$ErrorAction) return $null }
$script:pendingOperations=@{123=[pscustomobject]@{Operation='No-report test';ReportPath=(Join-Path $PSScriptRoot ('missing-'+[guid]::NewGuid().ToString('N')))}}
Check-PendingOperations
if($script:testLogs.Count -ne 1 -or $script:testLogs[0] -match '系统命令已完成'){throw 'Missing report falsely marked success'}
Write-Output 'PASS container grouping and operation result validation'

function Get-Process { param($Id,$ErrorAction) [pscustomobject]@{StartTime=[datetime]::Now} }
$script:pendingOperations=@{123=[pscustomobject]@{Operation='PID reuse test';ProcessStartTime=1L;ReportPath=(Join-Path $PSScriptRoot 'missing-pid-reuse.result')}}
Check-PendingOperations
if($script:pendingOperations.Count -ne 0){throw 'Reused PID blocked operation completion'}
Write-Output 'PASS reused PID does not block operation completion'
