@echo off
cd /d "%~dp0.."

echo === Git Status ===
git status

echo.
echo === Recent Commits ===
git --no-pager log --oneline -10

pause

