@echo off
chcp 65001 >nul
title 상담원 자동연결 워처
where pwsh >nul 2>nul && (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-watcher.ps1" %*
) || (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-watcher.ps1" %*
)
echo.
pause
