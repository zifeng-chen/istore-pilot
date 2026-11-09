@echo off
chcp 65001 >nul
cd /d "%~dp0.."
python scripts\install_apk.py %*
echo.
pause
