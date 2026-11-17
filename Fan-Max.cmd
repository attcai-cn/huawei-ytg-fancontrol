@echo off
rem Double-click launcher: put the fan at maximum speed.
rem Self-elevates, then runs HuaweiFan-Max.ps1 and keeps the window open.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0HuaweiFan-Max.ps1"
