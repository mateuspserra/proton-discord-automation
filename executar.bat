@echo off
setlocal EnableExtensions

cd /d "%~dp0"

title Proton VPN + Discord Automation

:: ============================================================
:: Proton VPN + Discord Automation
:: Autor: Mateus Serra - @mateuspserra
:: GitHub: github.com/mateuspserra
:: ============================================================

echo ============================================================
echo.
echo             Proton VPN + Discord Automation
echo.
echo             Desenvolvido por @mateuspserra
echo             GitHub: github.com/mateuspserra
echo.
echo ============================================================
echo.

if not exist "%~dp0proton-discord.ps1" (
    echo ERRO: proton-discord.ps1 nao foi encontrado.
    echo.
    echo Os arquivos executar.bat e proton-discord.ps1
    echo precisam estar dentro da mesma pasta.
    echo.
    pause
    endlocal
    exit /b 1
)

powershell.exe ^
    -NoLogo ^
    -NoProfile ^
    -ExecutionPolicy Bypass ^
    -File "%~dp0proton-discord.ps1"

set "EXIT_CODE=%ERRORLEVEL%"

echo.

if "%EXIT_CODE%"=="0" (
    echo Automacao concluida com sucesso.
) else (
    echo A automacao terminou com o codigo %EXIT_CODE%.
)

echo.
pause

endlocal & exit /b %EXIT_CODE%
