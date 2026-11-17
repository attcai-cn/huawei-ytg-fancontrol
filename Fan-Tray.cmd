@echo off
rem Double-click launcher: fan tray icon (two gears: max speed / automatic).
rem Self-elevates, then starts the tray app without a console window.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0HuaweiFan-Tray.ps1"
exit /b
