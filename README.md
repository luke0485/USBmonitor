<p align="center"><img src="logo.jpg" width="110" alt="usb-CybersecurityMonitor 图标"></p>
<h1 align="center">usb-CybersecurityMonitor</h1>
<p align="center">扫描 · 监听 · 查询 · 行为查看 · 手动阻断</p>

<p align="center"><img src="docs/overview.svg" width="800" alt="usb-CybersecurityMonitor 功能示意"></p>

Windows 桌面 USB 行为监测工具。查询设备、扫描名称与属性、监听文件变化和关联进程，支持选中设备后手动阻断与恢复，也可在托盘后台运行。

| 功能 | 用途 |
| --- | --- |
| 设备查询 | 查看 USB 设备、存储卷和硬件标识 |
| 扫描巡检 | 检查文件名称与属性，查看扫描结果 |
| 文件监听 | 查看文件创建、修改、重命名和删除 |
| 进程监听 | 查看与 USB 关联的进程及后代进程 |
| 设备控制 | 选中设备后阻断或恢复，同一设备的关联接口会一并处理 |

### 使用

1. 下载并解压项目，保留所有配套文件。
2. 双击 `Launch-usb-CybersecurityMonitor.vbs`；运行 `Install-usb-CybersecurityMonitor.bat` 可安装桌面快捷方式。
3. 接入 USB 设备查看信息；插入 U 盘可进行巡检。阻断前先选中顶部设备行。

运行环境：Windows 10 / 11、Windows PowerShell 5.1。正常监测使用普通权限；禁用或启用设备需要管理员确认。

扫描不读取文件内容；界面展示已检测到的信息，命令行线索不等同于操作已完成。

### 开发验证

使用 Windows PowerShell 运行 `Test-GuardLogic.ps1`、`Test-FileWatcher.ps1`、`Test-AsyncMonitor.ps1`、`Test-MetadataInventory.ps1`；`Test-HardwareSnapshot.ps1` 用于当前连接设备的硬件验证。

### 作者

luke0485 · GPT6Luna · GPT6.1
