@echo off
chcp 65001 >nul
title Remote Support
rem Customer entry point. Launches the PowerShell GUI launcher.
rem Production: bake server/key/portal defaults into support-client.ps1 at build time.
set "RS_PORTAL=https://support.example.com"
set "RS_ORG=demo"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0support-client.ps1"
