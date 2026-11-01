@echo off
setlocal
cd /d "%~dp0.."
set "LOGS=logs"
if not exist "%LOGS%" mkdir "%LOGS%"

rem Find the interpreter without opening a visible command window.
set "PY="
for /f "delims=" %%I in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do if not defined PY set "PY=%%I"
if not defined PY for /f "delims=" %%I in ('where python 2^>nul') do if not defined PY set "PY=%%I"
if not defined PY (
    echo [%DATE% %TIME%] ERROR python not found >> "%LOGS%\notify_stdout.txt"
    exit /b 9009
)

"%PY%" "cline_notify.py" --follow >> "%LOGS%\notify_stdout.txt" 2>&1
