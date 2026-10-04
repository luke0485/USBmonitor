@echo off
setlocal
set "SOURCE=%~dp0"
if "%SOURCE:~-1%"=="\" set "SOURCE=%SOURCE:~0,-1%"
set "INSTALL_DIR=%USERPROFILE%\UsbCybersecurityMonitor\App"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
robocopy "%SOURCE%" "%INSTALL_DIR%" usb-CybersecurityMonitor.ps1 AsyncMonitor.ps1 Install-Shortcuts.ps1 Launch-usb-CybersecurityMonitor.vbs Launch-usb-CybersecurityMonitor.cmd logo-rounded.ico usb-CybersecurityMonitor.ico logo.jpg /R:1 /W:1 /NFL /NDL /NP
if errorlevel 8 goto :copy_error

for %%F in (Sign-Release.ps1 release.manifest.json release.manifest.sig release-public.xml SECURITY.md) do del /f /q "%INSTALL_DIR%\%%F" >nul 2>&1

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\Install-Shortcuts.ps1"
if errorlevel 1 goto :shortcut_error

start "" "%SystemRoot%\System32\wscript.exe" "%INSTALL_DIR%\Launch-usb-CybersecurityMonitor.vbs" -Tray
echo usb-CybersecurityMonitor installed for the current user.
exit /b 0

:copy_error
echo Copy failed. Close usb-CybersecurityMonitor and run this installer again.
exit /b 2

:shortcut_error
echo Files were copied, but shortcut creation failed.
exit /b 3
