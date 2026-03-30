@echo off
:: Настройка Git для работы через корпоративный прокси Kerio Control
:: Запустить один раз на новой машине

git config --global http.proxy  http://192.168.152.200:8080
git config --global https.proxy http://192.168.152.200:8080
git config --global http.sslVerify false

echo Done. Current config:
git config --global --list | findstr /i "proxy ssl"

pause

