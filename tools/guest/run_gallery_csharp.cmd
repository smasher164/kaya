@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=gallery
set DOTNET_CLI_TELEMETRY_OPTOUT=1
dotnet run > C:\kaya\out_gallery_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gallery_csharp.txt
