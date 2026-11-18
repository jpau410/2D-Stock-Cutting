@echo off
rem Starts the application and opens it in the browser.
cd /d "%~dp0"
where julia >nul 2>&1
if errorlevel 1 (
    echo Julia was not found. Install it from https://julialang.org/downloads/ and run this again.
    pause
    exit /b 1
)
call julia --project -e "import Pkg; Pkg.instantiate()"
if errorlevel 1 (
    echo The packages could not be installed. Check the internet connection and run this again.
    pause
    exit /b 1
)
call julia --project app\server.jl --open
if errorlevel 1 pause
