@echo off
rem Tests, then runs the Windows desktop app. Requires flutter on PATH.
setlocal
cd /d "%~dp0.."
call flutter pub get || exit /b 1
call flutter test || exit /b 1
call flutter run -d windows %*
