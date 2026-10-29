@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent.ps1" up
if errorlevel 1 pause
