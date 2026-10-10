@echo off
title Kai Discord presence - self-test
echo Make sure the Discord desktop app is open and you are logged in.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0discord-rpc.ps1" -SelfTest
echo.
pause
