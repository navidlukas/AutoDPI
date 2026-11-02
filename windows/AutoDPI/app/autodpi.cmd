@echo off
rem ============================================================
rem  AutoDPI - finds the best DPI-bypass setting automatically
rem  Engines: GoodbyeDPI (ValdikSS), zapret winws (bol-van),
rem           presets from Flowseal/zapret-discord-youtube
rem  Usage:   autodpi.cmd [start|retest|stop|install|remove|reset]
rem ============================================================
setlocal EnableExtensions EnableDelayedExpansion
set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=start"
set "APP=%~dp0"
for %%I in ("%APP%..") do set "ROOT=%%~fI\"

rem ---------- Run as administrator ----------
fltmc >nul 2>&1
if errorlevel 1 (
    if exist "%APP%tools\elevator.exe" (
        "%APP%tools\elevator.exe" "%~f0" %ACTION%
        exit /b
    )
    echo Please right-click the file and choose "Run as administrator".
    pause
    exit /b 1
)

rem ---------- Settings ----------
rem   QUICK_TIMEOUT = seconds per site in the screening round
rem   FULL_TIMEOUT  = seconds per site in the final round
rem   FINALISTS     = settings that go to the final round
rem   ROUNDS        = times each finalist is tested
set "QUICK_TIMEOUT=6"
set "FULL_TIMEOUT=10"
set "FINALISTS=10"
set "ROUNDS=3"

rem ---------- Paths ----------
set "GDIR=%APP%engines\goodbyedpi"
set "GDPI=%GDIR%\x86_64\goodbyedpi.exe"
if /i not "%PROCESSOR_ARCHITECTURE%"=="AMD64" if not defined PROCESSOR_ARCHITEW6432 set "GDPI=%GDIR%\x86\goodbyedpi.exe"
set "ZDIR=%APP%engines\zapret"
set "ZEXE=%ZDIR%\winws.exe"
set "SITES=%ROOT%test_sites.txt"
set "RES=%ROOT%results\"
set "BEST=%RES%best_setting.txt"
set "NETDIR=%RES%networks\"
set "LOG=%RES%last_test_log.txt"
set "TMPD=%APP%temp\"
set "CURL=curl.exe"
if exist "%APP%tools\curl.exe" set "CURL=%APP%tools\curl.exe"
if not exist "%RES%" mkdir "%RES%"
title AutoDPI

if /i "%ACTION%"=="stop"    goto :act_stop
if /i "%ACTION%"=="install" goto :act_install
if /i "%ACTION%"=="remove"  goto :act_remove
if /i "%ACTION%"=="reset"   goto :act_reset

"%CURL%" --version >nul 2>&1
if errorlevel 1 (
    echo curl.exe was not found. It is built into Windows 10 ^(1803+^) and 11.
    echo On older Windows, put curl.exe into the app\tools folder.
    pause
    exit /b 1
)
if not exist "%SITES%" call :default_sites
if exist "%TMPD%" rd /s /q "%TMPD%"
mkdir "%TMPD%"
call :read_sites
if %N%==0 (
    echo test_sites.txt has no websites in it.
    pause
    exit /b 1
)
call :read_strategies

echo.
echo =============================================
echo    AutoDPI - automatic DPI bypass tuner
echo =============================================
echo Sites to test: %N%    Settings available: %NS%
rem the best setting is remembered separately for each network
call :get_network
echo Network: !NETNAME!
echo.
set "NBEST=%NETDIR%%NETID%_setting.txt"
set "NSCORE=%NETDIR%%NETID%_score.txt"
if not exist "%NETDIR%" (
    mkdir "%NETDIR%"
    rem first run of this version: the old single saved setting becomes this network's
    if exist "%BEST%" copy /y "%BEST%" "%NBEST%" >nul
    if exist "%RES%best_score.txt" copy /y "%RES%best_score.txt" "%NSCORE%" >nul
)
if /i "%ACTION%"=="retest" goto :full_test
if not exist "%NBEST%" goto :full_test

rem ================= QUICK START WITH SAVED SETTING =================
call :load_best "%NBEST%"
echo Saved setting for this network: !SN!
choice /c RC /t 5 /d C /n /m "Press R within 5 seconds to run all tests again..."
if errorlevel 2 goto :quick_check
goto :full_test

:quick_check
call :stop_all
echo Checking that the saved setting still works...
call :probe %FULL_TIMEOUT% all
set /a BASE_OK=OK
call :run_engine !SE! SA
if !ENGINE_OK!==0 goto :quick_fail
call :probe %FULL_TIMEOUT% all
call :stop_engines
set "SCORE=%N%"
if exist "%NSCORE%" set /p SCORE=<"%NSCORE%"
echo   Works on !OK! of %N% sites ^(when chosen: !SCORE!, without it: !BASE_OK!^)
if !OK! geq !SCORE! goto :quick_go
set /a NEED=SCORE-1
if !OK! leq !BASE_OK! goto :quick_fail
if !OK! lss !NEED! goto :quick_fail
choice /c RC /t 5 /d C /n /m "One site fewer than before. Press R in 5 seconds to re-test, otherwise it starts..."
if errorlevel 2 goto :quick_go
goto :full_test
:quick_fail
echo The saved setting no longer works well - running full tests.
echo.
goto :full_test

:quick_go
call :start_final !SE! SA SN
echo.
echo AutoDPI is running in a minimised window. Close that window to stop it.
goto :finish

rem ======================= FULL TEST =======================
:full_test
call :stop_all
rem some zapret settings ("ts") need TCP timestamps
netsh interface tcp set global timestamps=enabled >nul 2>&1
> "%LOG%" echo AutoDPI test log - started %date% %time%

echo [1/3] Without any bypass:
call :probe %FULL_TIMEOUT% all
set /a BASE_OK=OK, NB=0
for /l %%i in (1,1,%N%) do call :base_one %%i
set "SCREEN=blocked"
set "SCRN=%NB%"
if %NB%==0 (
    set "SCREEN=all"
    set "SCRN=%N%"
    call :say "  All sites load already. Testing anyway to find a setting that keeps them working."
)
set /a EST=NS*(QUICK_TIMEOUT+3)/60+1
echo.
echo [2/3] Trying %NS% settings ^(up to about %EST% minutes - please wait,
echo       and avoid browsing or downloading meanwhile^):
for /l %%j in (1,1,%NS%) do call :screen_one %%j
call :stop_engines
if not exist "%TMPD%screen.txt" goto :nothing_works
sort /r "%TMPD%screen.txt" /o "%TMPD%screen_sorted.txt"

echo.
echo [3/3] Final round: best %FINALISTS% settings, %ROUNDS% times each, all sites:
set /a F=0
for /f "usebackq tokens=2 delims=|" %%k in ("%TMPD%screen_sorted.txt") do call :final_pick %%k
call :stop_all
sort /r "%TMPD%final.txt" /o "%TMPD%final_sorted.txt"

rem ---------- results (first line = winner) ----------
set "WIN="
set /a RK=0
> "%RES%results.csv" echo rank,sites_ok_x100,avg_ms,engine,name
for /f "usebackq tokens=2-4 delims=|" %%a in ("%TMPD%final_sorted.txt") do call :result_one %%a %%b %%c
set "WE=!E[%WIN%]!"
set "WA=!A[%WIN%]!"
set "WN=!NM[%WIN%]!"
> "%NBEST%" echo !WE!^|!WN!^|!WA!
call :pct %WOK% WOKS
set /a WSC=WOK/100
> "%NSCORE%" echo %WSC%
rem also kept as "last winner" for 4_AUTOSTART_with_Windows_ON.cmd
copy /y "%NBEST%" "%BEST%" >nul

echo.
echo =============================================
echo  WINNER: !WN!
echo  Works on !WOKS! of %N% sites on average ^(without it: %BASE_OK%^)
echo  Speed : about %WMS% ms per page
echo =============================================
call :say "WINNER: !WN!  sites_ok=!WOKS!/%N%  avg=%WMS% ms  - finished %date% %time%"
echo Saved for network "!NETNAME!".   Ranking: results\results.csv
echo.
choice /c SN /t 15 /d N /n /m "Press S to also make it start with Windows, or wait 15 s to just start it now: "
if errorlevel 2 (
    call :start_final !WE! WA WN
    echo Running in a minimised window. Close that window to stop it.
) else (
    call :install_service !WE! WA WN
)
goto :finish

:nothing_works
call :say "No setting could open the blocked sites."
echo They are probably blocked by IP address - only a VPN or proxy can help with those.
rd /s /q "%TMPD%" 2>nul
pause
exit /b 1

:finish
rd /s /q "%TMPD%" 2>nul
echo You can start browsing now.
ping -n 6 127.0.0.1 >nul
exit /b 0

rem ======================= PER-ITEM STEPS =======================

:base_one
rem %1 = site number: mark blocked or not after the baseline probe
if !R[%1]!==1 (
    set "B[%1]=0"
    call :say "  OK       !S[%1]! (!T[%1]! ms)"
) else (
    set "B[%1]=1"
    set /a NB+=1
    call :say "  BLOCKED  !S[%1]! - !M[%1]!"
)
goto :eof

:screen_one
rem %1 = strategy number: quick test on the blocked sites
title AutoDPI - testing %1 of %NS%
call :run_engine !E[%1]! A[%1]
if !ENGINE_OK!==0 (
    call :say "  [%1/%NS%] could not start   !NM[%1]!"
    goto :eof
)
call :probe %QUICK_TIMEOUT% %SCREEN%
call :say "  [%1/%NS%] !OK!/%SCRN% ok  avg !AVG! ms   !NM[%1]!"
if !OK! gtr 0 call :addkey !OK! !AVG! "%1" screen.txt
goto :eof

:final_pick
if !F! geq %FINALISTS% goto :eof
set /a F+=1
rem %1 = strategy number: start it once, test ROUNDS times on all sites
call :run_engine !E[%1]! A[%1]
set /a SUMOK=0, SUMMS=0, NMS=0
if !ENGINE_OK!==1 for /l %%r in (1,1,%ROUNDS%) do call :final_round
set /a OKX=SUMOK*100/ROUNDS, FAVG=99999
if %NMS% gtr 0 set /a FAVG=SUMMS/NMS
call :addkey %OKX% %FAVG% "%1|%OKX%|%FAVG%" final.txt
call :pct %OKX% OKS
call :say "  !OKS!/%N% ok  avg %FAVG% ms   !NM[%1]!"
goto :eof

:final_round
call :probe %FULL_TIMEOUT% all
set /a SUMOK+=OK
if %OK% gtr 0 set /a SUMMS+=AVG, NMS+=1
goto :eof

:result_one
rem %1 strategy  %2 ok x100  %3 avg ms
set /a RK+=1
if not defined WIN (
    set "WIN=%1"
    set "WOK=%2"
    set "WMS=%3"
)
>>"%RES%results.csv" echo %RK%,%2,%3,!E[%1]!,"!NM[%1]!"
goto :eof

:addkey
rem %1 sites ok  %2 avg ms  %3 data  %4 file.  Key sorts best-first with sort /r.
set /a KEY=1000000000 + %1*100000 + 99999 - %2
set "DATA=%~3"
>>"%TMPD%%4" echo %KEY%^|!DATA!
goto :eof

:pct
rem %1 = value x100 -> %2 = "x.yy"
set /a P1=%1/100, P2=100+%1%%100
set "%2=%P1%.%P2:~1%"
goto :eof

rem ======================= READING FILES =======================

:read_sites
set /a N=0
for /f "usebackq eol=# tokens=1,* delims=|" %%a in ("%SITES%") do (
    set "u=%%a"
    set "kw=%%b"
    call :add_site
)
goto :eof

:add_site
call :trim u
call :trim kw
if not defined u goto :eof
if /i not "!u:~0,4!"=="http" set "u=https://!u!"
set /a N+=1
set "S[%N%]=!u!"
set "K[%N%]=!kw!"
rem host = 2nd part of "https://host:port/path" split on / and :
set "h=!u!"
for /f "tokens=2 delims=/:" %%h in ("!u!") do set "h=%%h"
if /i "!h:~0,4!"=="www." set "h=!h:~4!"
set "H[%N%]=!h!"
goto :eof

:read_strategies
set /a NS=0
for /f "usebackq eol=# tokens=1,2,* delims=|" %%a in ("%APP%strategies.txt") do (
    set /a NS+=1
    set "E[!NS!]=%%a"
    set "NM[!NS!]=%%b"
    set "A[!NS!]=%%c"
)
goto :eof

:load_best
rem %1 = setting file
set "SE="
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%~1") do (
    set "SE=%%a"
    set "SN=%%b"
    set "SA=%%c"
)
goto :eof

:trim
if not defined %1 goto :eof
set "t=!%1!"
:trim_l
if "!t:~0,1!"==" " (
    set "t=!t:~1!"
    goto :trim_l
)
:trim_r
if "!t:~-1!"==" " (
    set "t=!t:~0,-1!"
    goto :trim_r
)
set "%1=!t!"
goto :eof

:say
rem print a line and add it to the log
set "line=%~1"
echo !line!
>>"%LOG%" echo !line!
goto :eof

rem ======================= NETWORK =======================

:get_network
rem NETNAME = Wi-Fi name or "Wired (router ...)",  NETID = safe file name for it
set "NETNAME="
set "NETTYPE=wifi"
for /f "tokens=1,* delims=:" %%a in ('netsh wlan show interfaces 2^>nul ^| findstr /r /c:"^ *SSID"') do (
    if not defined NETNAME set "NETNAME=%%b"
)
call :trim NETNAME
if not defined NETNAME (
    set "NETTYPE=wired"
    for /f "tokens=1-3" %%a in ('route print -4 0.0.0.0 2^>nul') do (
        if "%%a"=="0.0.0.0" if "%%b"=="0.0.0.0" if not defined NETNAME set "NETNAME=%%c"
    )
)
if not defined NETNAME set "NETNAME=unknown"
set "src=!NETNAME!"
set "NETID=%NETTYPE%_"
:netid_loop
if not defined src goto :netid_done
set "c=!src:~0,1!"
set "src=!src:~1!"
set "ok="
if "!c!" geq "0" if "!c!" leq "9" set "ok=1"
if /i "!c!" geq "a" if /i "!c!" leq "z" set "ok=1"
if defined ok set "NETID=!NETID!!c!"
goto :netid_loop
:netid_done
set "NETID=!NETID:~0,48!"
if "%NETTYPE%"=="wired" set "NETNAME=Wired (router !NETNAME!)"
goto :eof

:default_sites
> "%SITES%" echo # One website per line. Lines starting with # are ignored.
>>"%SITES%" echo # Put blocked sites here, plus 1-2 normal sites as a control.
>>"%SITES%" echo # Optional: add " | word" after a URL - the page must contain that word.
>>"%SITES%" echo https://www.youtube.com
>>"%SITES%" echo https://discord.com
>>"%SITES%" echo https://www.google.com
>>"%SITES%" echo https://www.xhamster.com
>>"%SITES%" echo https://www.pornhub.com
goto :eof

rem ======================= ENGINE CONTROL =======================

:stop_engines
rem wait a moment only if something was actually stopped
set "KILLED="
for %%x in (goodbyedpi.exe winws.exe) do (
    taskkill /f /im %%x >nul 2>&1
    if not errorlevel 1 set "KILLED=1"
)
if defined KILLED ping -n 2 127.0.0.1 >nul
goto :eof

:stop_all
call :stop_engines
for %%s in (AutoDPI GoodbyeDPI zapret) do sc stop %%s >nul 2>&1
call :unload_driver
goto :eof

:unload_driver
rem GoodbyeDPI and zapret ship different WinDivert driver versions
for %%s in (WinDivert WinDivert14) do (
    sc stop %%s >nul 2>&1
    sc delete %%s >nul 2>&1
)
set "CUR_ENGINE="
ping -n 2 127.0.0.1 >nul
goto :eof

:expand_args
rem %1 = NAME of the variable with raw args -> RUNARGS with real paths
set "RUNARGS=!%1!"
set "RUNARGS=!RUNARGS:{BIN}=%ZDIR%\!"
set "RUNARGS=!RUNARGS:{LISTS}=%ZDIR%\lists\!"
goto :eof

:run_engine
rem %1 gdpi/zapret  %2 NAME of args variable.  Sets ENGINE_OK=1 if running.
call :stop_engines
if not "%1"=="!CUR_ENGINE!" call :unload_driver
set "CUR_ENGINE=%1"
call :expand_args %2
set "ENGINE_OK=0"
if "%1"=="gdpi" (
    set "EXE=goodbyedpi.exe"
    start "" /b /d "%GDIR%" "%GDPI%" !RUNARGS! >nul 2>&1
    ping -n 2 127.0.0.1 >nul
) else (
    set "EXE=winws.exe"
    start "" /b /d "%ZDIR%" "%ZEXE%" !RUNARGS! >nul 2>&1
    ping -n 3 127.0.0.1 >nul
)
tasklist /fi "imagename eq %EXE%" /nh 2>nul | findstr /i /c:"%EXE%" >nul
if not errorlevel 1 set "ENGINE_OK=1"
goto :eof

:start_final
rem %1 gdpi/zapret  %2 NAME of args variable  %3 NAME of name variable
call :stop_all
call :expand_args %2
set "WT=AutoDPI running - !%3! - close this window to stop"
if "%1"=="gdpi" (
    start "!WT!" /min /d "%GDIR%" "%GDPI%" !RUNARGS!
) else (
    start "!WT!" /min /d "%ZDIR%" "%ZEXE%" !RUNARGS!
)
goto :eof

:install_service
rem %1 gdpi/zapret  %2 NAME of args variable  %3 NAME of name variable
call :stop_all
sc delete AutoDPI >nul 2>&1
call :expand_args %2
set "SVCARGS=!RUNARGS:"=\"!"
set "SVCEXE=%ZEXE%"
if "%1"=="gdpi" set "SVCEXE=%GDPI%"
sc create AutoDPI binPath= "\"!SVCEXE!\" !SVCARGS!" DisplayName= "AutoDPI" start= auto >nul
sc description AutoDPI "DPI bypass - setting chosen by AutoDPI: !%3!" >nul
sc start AutoDPI >nul
ping -n 3 127.0.0.1 >nul
sc query AutoDPI | findstr /i /c:"RUNNING" >nul
if not errorlevel 1 (
    echo Done. It now starts automatically with Windows.
    echo Use 5_AUTOSTART_with_Windows_OFF.cmd to turn this off.
    goto :eof
)
echo Could not start the Windows service - starting it in a window instead.
sc delete AutoDPI >nul 2>&1
call :start_final %1 %2 %3
goto :eof

rem ======================= WEBSITE TESTING =======================

:probe
rem %1 timeout s  %2 all/blocked.  Sets OK, AVG and per site R[i] T[i] M[i]
set "PT=%1"
set "PMODE=%2"
ipconfig /flushdns >nul 2>&1
del /q "%TMPD%r*.txt" "%TMPD%r*.tmp" "%TMPD%b*.htm" 2>nul
set /a PN=0
for /l %%i in (1,1,%N%) do call :probe_launch %%i
set /a W=0, WMAX=PT+6
:probe_wait
set /a CNT=0
for %%f in ("%TMPD%r*.txt") do set /a CNT+=1
if %CNT% geq %PN% goto :probe_read
set /a W+=1
if %W% gtr %WMAX% (
    taskkill /f /im curl.exe >nul 2>&1
    goto :probe_read
)
ping -n 2 127.0.0.1 >nul
goto :probe_wait
:probe_read
set /a OK=0, TOT=0, AVG=99999
for /l %%i in (1,1,%N%) do call :judge %%i
if %OK% gtr 0 set /a AVG=TOT/OK
goto :eof

:probe_launch
set "R[%1]=0"
set "T[%1]="
set "M[%1]=not tested"
if "%PMODE%"=="blocked" if !B[%1]!==0 goto :eof
set "M[%1]=no connection / timeout"
set /a PN+=1
start "" /b cmd /c call "%APP%probe_site.cmd" %1
goto :eof

:judge
rem temp\r<i>.txt = "<http code> <seconds> <final url>"
if not exist "%TMPD%r%1.txt" goto :eof
set "code="
set "tt=0.0"
set "fh="
rem split on spaces and slashes: 1=code 2=seconds 3=https: 4=host
for /f "usebackq tokens=1,2,4 delims=/ " %%a in ("%TMPD%r%1.txt") do (
    set "code=%%a"
    set "tt=%%b"
    set "fh=%%c"
)
if not defined code goto :eof
if "!code!"=="000" goto :eof
if !code! geq 500 (
    set "M[%1]=HTTP !code!"
    goto :eof
)
rem the final address must still be the same site, not an ISP block page
set "core=!H[%1]!"
call set "chk=%%fh:%core%=%%"
if "!chk!"=="!fh!" (
    set "M[%1]=redirected to !fh! - block page?"
    goto :eof
)
if defined K[%1] (
    findstr /i /c:"!K[%1]!" "%TMPD%b%1.htm" >nul 2>&1
    if errorlevel 1 (
        set "M[%1]=keyword not found - block page?"
        goto :eof
    )
)
rem seconds "2.772123" -> ms
for /f "tokens=1,2 delims=.," %%a in ("!tt!") do (
    set "sec=%%a"
    set "frac=%%b000"
)
set /a ms=sec*1000 + 1!frac:~0,3! - 1000
set "R[%1]=1"
set "T[%1]=%ms%"
set "M[%1]=HTTP !code!"
set /a OK+=1, TOT+=ms
goto :eof

rem ======================= OTHER ACTIONS =======================

:act_stop
call :stop_engines
sc stop AutoDPI >nul 2>&1
echo AutoDPI stopped.
echo If autostart with Windows is on, it will start again at the next boot.
ping -n 4 127.0.0.1 >nul
exit /b 0

:act_install
if not exist "%BEST%" (
    echo No saved setting yet - run 1_START.cmd first.
    pause
    exit /b 1
)
call :load_best "%BEST%"
echo Setting "!SN!" to start with Windows...
call :install_service !SE! SA SN
pause
exit /b 0

:act_reset
choice /c YN /m "Reset AutoDPI to defaults (test sites, saved settings, results, autostart)"
if errorlevel 2 exit /b 0
call :stop_engines
sc stop AutoDPI >nul 2>&1
sc delete AutoDPI >nul 2>&1
call :unload_driver
if exist "%RES%" rd /s /q "%RES%"
if exist "%TMPD%" rd /s /q "%TMPD%"
call :default_sites
echo Done. Everything is back to defaults - run 1_START.cmd to test again.
pause
exit /b 0

:act_remove
call :stop_engines
sc stop AutoDPI >nul 2>&1
sc delete AutoDPI >nul 2>&1
call :unload_driver
echo Done. AutoDPI will no longer start with Windows.
pause
exit /b 0
