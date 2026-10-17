@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
rem ============================================================
rem synth\run_synth.bat —— 一键综合 soc_top（Vivado）
rem
rem 为什么要绕：Vivado 不接受含中文的路径（本仓库在「比赛」目录下），
rem 直接跑会报 "Could not open 'C' for writing"。所以先把 RTL 复制到
rem 纯英文的临时目录再综合，报告再拷回 build\synth。
rem
rem 用法：双击本文件，或在仓库根目录执行  synth\run_synth.bat
rem ============================================================

set WORK=C:\Windows\Temp\soc_synth
set PART=%~1
if "%PART%"=="" set PART=xc7vx485tffg1157-1

if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%\RTL" 2>nul
copy /y "%~dp0..\RTL\*.v" "%WORK%\RTL" >nul
copy /y "%~dp0..\RTL\cpu\cortexm0ds\cortexm0ds_logic.v" "%WORK%\RTL" >nul
copy /y "%~dp0run_synth.tcl" "%WORK%\" >nul

set VIVADO=vivado.bat
where vivado.bat >nul 2>nul || set VIVADO=D:\apps\vivado\Vivado\2026.1\Vivado\bin\vivado.bat
if not exist "%VIVADO%" if not "%VIVADO%"=="vivado.bat" (echo 找不到 vivado.bat，请改本文件里的 VIVADO 变量 & exit /b 1)

echo 器件   : %PART%
echo 工作目录: %WORK%
echo.
cd /d "%WORK%"
call "%VIVADO%" -mode batch -nojournal -nolog -notrace -source "%WORK%\run_synth.tcl" -tclargs %PART%
if errorlevel 1 goto fail

if not exist "%~dp0..\build\synth" mkdir "%~dp0..\build\synth"
copy /y "%WORK%\util.rpt" "%~dp0..\build\synth\" >nul 2>nul
copy /y "%WORK%\timing.rpt" "%~dp0..\build\synth\" >nul 2>nul
copy /y "%WORK%\soc_top_synth.dcp" "%~dp0..\build\synth\" >nul 2>nul
echo.
echo ===== 综合成功，报告在 build\synth（util.rpt / timing.rpt）=====
exit /b 0

:fail
echo.
echo ===== 综合失败，看上面的 ERROR 行 =====
exit /b 1
