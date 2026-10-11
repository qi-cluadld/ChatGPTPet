@echo off
rem ChatGPT Desktop Pet launcher (fallback if .vbs is blocked)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ChatGPTPet.ps1"
