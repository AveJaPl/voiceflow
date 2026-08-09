@echo off
:: voiceflow installer bootstrap - double-click to install.
:: Downloads and runs windows/install.ps1 from the official repository.
title voiceflow - instalacja
echo.
echo  Instaluje voiceflow (dyktowanie glosowe, lokalnie, za darmo)...
echo  To potrwa kilka minut; przy pierwszym uruchomieniu pobierze sie
echo  model mowy (ok. 1,6 GB).
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex"
echo.
if %errorlevel% neq 0 (
  echo  Instalacja nie powiodla sie - zglos problem:
  echo  https://github.com/AveJaPl/voiceflow/issues
) else (
  echo  Gotowe! Skrot dyktowania: Ctrl+Shift+Space
)
pause
