pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrcpy-wifi-safe.ps1" --turn-screen-off --no-audio --stay-awake --window-x=600 --window-y=30 --window-width=1920 --window-height=1020 --keyboard=uhid %*
REM Rausgenommen: Niedrigere Bandwidth: -b2M
