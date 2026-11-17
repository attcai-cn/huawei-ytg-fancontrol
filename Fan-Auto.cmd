@echo off
rem Double-click launcher: hand the fan back to firmware (automatic) control.
rem Self-elevates, then runs Restore-HuaweiFanVendorControl.ps1.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Restore-HuaweiFanVendorControl.ps1"
