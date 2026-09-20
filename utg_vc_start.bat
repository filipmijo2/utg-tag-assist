@echo off
title UTG VC-Soundboard
cd /d "%~dp0"
python -u utg_vc_player.py
echo.
echo Fenster geschlossen. Beliebige Taste zum Beenden.
pause >nul
