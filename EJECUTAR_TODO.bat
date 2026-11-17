@echo off
REM Construye la base, ejecuta todas las pruebas y guarda la evidencia.
REM Doble clic para ejecutar. Resultado: carpeta evidencias\
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_all.ps1" %*
echo.
echo Proceso terminado. Revise evidencias\00_resumen_ejecucion.txt
timeout /t 20
