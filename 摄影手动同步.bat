@echo off
chcp 936 >nul
setlocal

title 摄影镜像同步 V3.3
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0摄影同步核心.ps1"
set "SYNC_EXIT=%ERRORLEVEL%"

echo.
if not "%SYNC_EXIT%"=="0" (
    echo 同步存在异常，请查看上方原因。
)
echo 按任意键关闭窗口
pause >nul

endlocal