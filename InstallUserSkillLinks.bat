@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Creates user-level Agent Skill junctions for every skill in this repository.
rem Run this file from anywhere; it resolves paths from the script location.

set "REPO_ROOT=%~dp0"
set "SOURCE_SKILLS=%REPO_ROOT%skills"
set "TARGET_SKILLS=%USERPROFILE%\.agents\skills"

echo Tirefly UE5 Agent Skills link installer
echo.
echo Source: "%SOURCE_SKILLS%"
echo Target: "%TARGET_SKILLS%"
echo.

if not exist "%SOURCE_SKILLS%\" (
    echo ERROR: Source skills folder does not exist.
    echo Expected: "%SOURCE_SKILLS%"
    exit /b 1
)

if not exist "%TARGET_SKILLS%\" (
    echo Creating target folder...
    mkdir "%TARGET_SKILLS%"
    if errorlevel 1 (
        echo ERROR: Failed to create target folder.
        exit /b 1
    )
)

set "INSTALLED_COUNT=0"
set "SKIPPED_COUNT=0"

for /D %%S in ("%SOURCE_SKILLS%\*") do (
    set "SKILL_NAME=%%~nxS"
    set "SOURCE_PATH=%%~fS"
    set "TARGET_PATH=%TARGET_SKILLS%\!SKILL_NAME!"

    if not exist "!SOURCE_PATH!\SKILL.md" (
        echo [SKIP] !SKILL_NAME! does not contain SKILL.md
        set /a SKIPPED_COUNT+=1
    ) else if exist "!TARGET_PATH!\" (
        echo [SKIP] !SKILL_NAME! already exists at target
        set /a SKIPPED_COUNT+=1
    ) else (
        echo [LINK] !SKILL_NAME!
        mklink /J "!TARGET_PATH!" "!SOURCE_PATH!" >nul
        if errorlevel 1 (
            echo [FAIL] !SKILL_NAME! link creation failed
            set /a SKIPPED_COUNT+=1
        ) else (
            echo [ OK ] !TARGET_PATH! ^-^> !SOURCE_PATH!
            set /a INSTALLED_COUNT+=1
        )
    )
)

echo.
echo Completed.
echo Installed: %INSTALLED_COUNT%
echo Skipped:   %SKIPPED_COUNT%
echo.
pause

endlocal
