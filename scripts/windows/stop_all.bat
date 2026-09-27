@echo off
REM ============================================================
REM  stop_all.bat -- Stop the whole local LLM stack
REM
REM   Windows side : host metrics exporter (9401)
REM                  LibreHardwareMonitor (8085)
REM   WSL side     : vLLM(18020) + litellm(1234)
REM                  + Prometheus(9090) + Grafana(3000)
REM                  + GPU exporter(9400) + LLM waterfall(9410)
REM
REM   USAGE: double-click this file.  Admin NOT required.
REM   ARGS : -WithPostgres  also stop PostgreSQL (default: kept)
REM          -KeepLhm       keep LibreHardwareMonitor running
REM
REM   PostgreSQL is kept by default because litellm stores usage
REM   records (LiteLLM_SpendLogs) in it.
REM ============================================================
chcp 65001 >nul
title GPU + LLM One-Click Stop
cd /d "%~dp0"

echo Launching stop_all.ps1 ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_all.ps1" %*

echo.
pause
