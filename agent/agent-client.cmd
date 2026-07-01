@echo off
chcp 65001 >nul
title Agent (1bun sangdamwon)
rem 1번 상담원용 진입점. 어느 기기에서든 실행 → RustDesk 설정 + 대시보드 로그인.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-client.ps1"
