@echo off
rem Builds dist\OverwatchServerLock.exe with the scripts and icon embedded.
rem Uses the C# compiler that ships with Windows (.NET Framework 4.x); nothing to install.
setlocal
cd /d "%~dp0"
if not exist dist mkdir dist
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize ^
  /out:dist\OverwatchServerLock.exe ^
  /win32manifest:src\app.manifest /win32icon:assets\icon.ico ^
  /resource:src\ow-lock.ps1,ow-lock.ps1 ^
  /resource:src\ow-gui.ps1,ow-gui.ps1 ^
  /resource:assets\icon.ico,icon.ico ^
  /reference:System.Windows.Forms.dll ^
  src\launcher.cs
if errorlevel 1 exit /b 1
echo Built dist\OverwatchServerLock.exe
