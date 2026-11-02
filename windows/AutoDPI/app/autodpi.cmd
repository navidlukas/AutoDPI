@echo off
rem ============================================================
rem  AutoDPI - finds the best DPI-bypass setting automatically
rem  Engines: GoodbyeDPI (ValdikSS), zapret winws (bol-van),
rem           presets from Flowseal/zapret-discord-youtube
rem  Usage:   autodpi.cmd [start|retest|stop|install|remove|reset]
rem ============================================================
setlocal EnableExtensions EnableDelayedExpansion
set "ACTION=%~1"
if "%ACTION%"=="_doh" goto :doh_child
if "%ACTION%"=="" set "ACTION=start"
set "APP=%~dp0"
set "SELF=%~f0"
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
rem   STOP_AFTER    = stop screening once this many settings open every blocked site
rem   FINALISTS     = settings that go to the final round
rem   ROUNDS        = times each finalist is tested
set "QUICK_TIMEOUT=3"
set "FULL_TIMEOUT=8"
set "STOP_AFTER=3"
set "FINALISTS=5"
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
rem find the fastest working encrypted DNS (DoH) server; all site tests then use it
call :dns_check
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
call :apply_dns
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
rem first with your normal DNS, then with encrypted DNS - sites that only open with
rem encrypted DNS are DNS-blocked (fixed by switching DNS, no DPI setting needed)
set "SAVEDOH=%DOHARGS%"
set "DOHARGS="
call :probe %FULL_TIMEOUT% all
for /l %%i in (1,1,%N%) do call :sys_copy %%i
set "DOHARGS=%SAVEDOH%"
if defined DOHARGS call :probe %FULL_TIMEOUT% all
set /a BASE_OK=OK, NB=0, NDNS=0
for /l %%i in (1,1,%N%) do call :base_one %%i
rem screening set S2[i]: the blocked sites (all sites if none is blocked); FB = first of them
set /a SCRN=0, FB=0
for /l %%i in (1,1,%N%) do call :screen_site %%i
if %NB%==0 call :say "  All sites load already. Testing anyway to find a setting that keeps them working."

echo.
echo [2/3] Testing one setting of each type, then more of the types that work
echo       ^(usually 2-5 minutes - avoid browsing or downloading meanwhile^):
set /a TESTED=0, PERFECT=0, NG=0
rem stage A: the first setting of every type
for /l %%j in (1,1,%NS%) do call :type_rep %%j
rem stage B: other settings of the types that worked, best type first
for /l %%g in (1,1,%NG%) do call :type_key %%g
if not exist "%TMPD%types.txt" goto :stage_c
sort /r "%TMPD%types.txt" /o "%TMPD%types_sorted.txt"
for /f "usebackq tokens=2 delims=|" %%g in ("%TMPD%types_sorted.txt") do call :expand_type %%g
goto :stage_done
:stage_c
rem stage C: no type worked at all - try everything that is left
call :say "  No type worked yet - trying the remaining settings."
for /l %%j in (1,1,%NS%) do call :screen_once %%j
:stage_done
call :say "  Tested !TESTED! of %NS% settings."
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
call :apply_dns
goto :finish

:nothing_works
call :say "No setting could open the blocked sites."
echo They are probably blocked by IP address - only a VPN or proxy can help with those.
call :apply_dns
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
    if !SYS[%1]!==1 call :say "  OK       !S[%1]! (!T[%1]! ms)"
    if !SYS[%1]!==0 (
        set /a NDNS+=1
        call :say "  DNS-BLOCKED  !S[%1]! - opens with encrypted DNS (%DOHNAME%)"
    )
) else (
    set "B[%1]=1"
    set /a NB+=1
    call :say "  BLOCKED  !S[%1]! - !M[%1]!"
)
goto :eof

:sys_copy
set "SYS[%1]=!R[%1]!"
goto :eof

:screen_site
rem %1 = site number: is it part of the screening set?
set "S2[%1]=0"
if %NB% gtr 0 if !B[%1]!==0 goto :eof
set "S2[%1]=1"
set /a SCRN+=1
if %FB%==0 set "FB=%1"
goto :eof

:type_rep
rem %1 = strategy number: test it if it is the first of its type
set "g=!G[%1]!"
if defined SEEN_!g! goto :eof
set "SEEN_!g!=1"
set /a NG+=1
set "GL[!NG!]=!g!"
call :screen_one %1
set "GOK_!g!=!OK!"
goto :eof

:type_key
rem %1 = type number: queue the type for stage B if its first setting opened any site
set "g=!GL[%1]!"
set "gok="
call set "gok=%%GOK_!g!%%"
if not defined gok goto :eof
if !gok! leq 0 goto :eof
set /a K=1000+gok
>>"%TMPD%types.txt" echo !K!^|!g!
goto :eof

:expand_type
rem %1 = type: test its other settings (until STOP_AFTER perfect settings were found)
for /l %%j in (1,1,%NS%) do call :expand_one %%j %1
goto :eof

:expand_one
if "!G[%1]!"=="%2" call :screen_once %1
goto :eof

:screen_once
if defined DONE[%1] goto :eof
if %PERFECT% geq %STOP_AFTER% goto :eof
call :screen_one %1
goto :eof

:screen_one
rem %1 = strategy number: first blocked site only; the rest only if that one opened
set "DONE[%1]=1"
set /a TESTED+=1
title AutoDPI - testing setting %TESTED% ^(%1 of %NS%^)
call :run_engine !E[%1]! A[%1]
if !ENGINE_OK!==0 (
    set "OK=0"
    call :say "  [%1] could not start   !NM[%1]!"
    goto :eof
)
call :probe %QUICK_TIMEOUT% first
set /a OK1=OK, TOT1=TOT, OK=0, TOT=0
if %OK1% gtr 0 if %SCRN% gtr 1 call :probe %QUICK_TIMEOUT% rest
set /a OK+=OK1, TOT+=TOT1, AVG=99999
if %OK% gtr 0 set /a AVG=TOT/OK
if %OK% geq %SCRN% set /a PERFECT+=1
call :say "  [%1] !OK!/%SCRN% ok  avg !AVG! ms   !NM[%1]!"
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
for /f "usebackq eol=# tokens=1,2,3,* delims=|" %%a in ("%APP%strategies.txt") do (
    set /a NS+=1
    set "E[!NS!]=%%a"
    set "G[!NS!]=%%b"
    set "NM[!NS!]=%%c"
    set "A[!NS!]=%%d"
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
rem modes: all = every site, first = first screening site, rest = the other screening sites
if "%PMODE%"=="first" if not "%1"=="%FB%" goto :eof
if "%PMODE%"=="rest" if not "!S2[%1]!"=="1" goto :eof
if "%PMODE%"=="rest" if "%1"=="%FB%" goto :eof
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
call :to_ms
set "R[%1]=1"
set "T[%1]=%ms%"
set "M[%1]=HTTP !code!"
set /a OK+=1, TOT+=ms
goto :eof

:to_ms
rem tt = seconds like "2.772123" -> ms
set "sec=0"
set "frac=000"
for /f "tokens=1,2 delims=.," %%a in ("!tt!") do (
    set "sec=%%a"
    set "frac=%%b000"
)
set /a ms=sec*1000 + 1!frac:~0,3! - 1000
goto :eof

rem ======================= ENCRYPTED DNS =======================

:dns_check
rem Asks every DoH server at once; the fastest one that answers is used for every site test.
rem The same server is then set as the computer's DNS (apply_dns).
set "DOHARGS="
set "DOHNAME="
set "DOHIP="
set /a BESTMS=99999, NDNS=0, NP=0
rem curl older than 7.62 cannot use DoH: "unknown option" gives exit code 2
"%CURL%" -s -m 2 --doh-url https://127.0.0.1/ -o NUL http://127.0.0.1:9/ >nul 2>&1
if errorlevel 2 if not errorlevel 3 (
    echo Encrypted DNS: not supported by this curl version - using normal DNS.
    goto :eof
)
echo Checking encrypted DNS servers:
rem name | DoH address | DoH IP | DNS 1 | DNS 2 | DNS IPv6     ("-" = none)
for %%p in (
    "Quad9|https://dns.quad9.net/dns-query|9.9.9.9|9.9.9.9|149.112.112.112|2620:fe::fe"
    "Cloudflare|https://cloudflare-dns.com/dns-query|1.1.1.1|1.1.1.1|1.0.0.1|2606:4700:4700::1111"
    "Google|https://dns.google/dns-query|8.8.8.8|8.8.8.8|8.8.4.4|2001:4860:4860::8888"
    "AdGuard|https://dns.adguard-dns.com/dns-query|94.140.14.14|94.140.14.14|94.140.15.15|2a10:50c0::ad1:ff"
    "Yandex|https://common.dot.dns.yandex.net/dns-query|77.88.8.8|77.88.8.8|77.88.8.1|2a02:6b8::feed:0ff"
    "OpenDNS|https://doh.opendns.com/dns-query|146.112.41.2|208.67.222.222|208.67.220.220|2620:119:35::35"
    "Control D|https://freedns.controld.com/p0|76.76.2.0|76.76.2.0|76.76.10.0|2606:1a40::"
    "DNS4EU|https://unfiltered.joindns4.eu/dns-query|86.54.11.100|86.54.11.100|86.54.11.200|2a13:1001::86:54:11:100"
    "DNS.SB|https://doh.dns.sb/dns-query|185.222.222.222|185.222.222.222|45.11.45.11|2a09::"
    "CIRA Shield|https://private.canadianshield.cira.ca/dns-query|149.112.121.10|149.112.121.10|149.112.122.10|2620:10a:80bb::10"
    "CleanBrowsing|https://doh.cleanbrowsing.org/doh/security-filter/|185.228.168.9|185.228.168.9|185.228.169.9|2a0d:2a00:1::2"
    "Hurricane Electric|https://ordns.he.net/dns-query|74.82.42.42|74.82.42.42|-|2001:470:20::2"
    "Switch|https://dns.switch.ch/dns-query|130.59.31.248|130.59.31.248|-|2001:620:0:ff::2"
    "AliDNS|https://dns.alidns.com/dns-query|223.5.5.5|223.5.5.5|223.6.6.6|2400:3200::1"
    "LibreDNS|https://doh.libredns.gr/dns-query|116.202.176.26|88.198.92.222|-|-"
) do call :dns_launch %%p
rem wait up to 10 seconds for the answers
set /a W=0
:dns_wait
set /a W+=1, ND=0
for /l %%i in (1,1,%NP%) do if exist "%TMPD%d%%i.txt" set /a ND+=1
if %ND% lss %NP% if %W% leq 10 (
    ping -n 2 127.0.0.1 >nul
    goto :dns_wait
)
for /l %%i in (1,1,%NP%) do call :dns_read %%i
if not defined DOHNAME (
    echo   No encrypted DNS server answered - using normal DNS.
    goto :eof
)
set "DOHARGS=--doh-url %DOHURL% %DOHPIN%"
echo   Using %DOHNAME% ^(%BESTMS% ms^)
goto :eof

:dns_launch
rem %1 = one provider line; DP_*[n] are passed to the background query (:doh_child)
set /a NP+=1
for /f "tokens=1-6 delims=|" %%a in (%1) do (
    set "DP_N[!NP!]=%%a"
    set "DP_U[!NP!]=%%b"
    set "DP_I[!NP!]=%%c"
    set "DP_1[!NP!]=%%d"
    set "DP_2[!NP!]=%%e"
    set "DP_6[!NP!]=%%f"
)
rem host name = the part between "https://" and the next "/"
set "h=!DP_U[%NP%]:https://=!"
set "rest=!h:*/=!"
call set "DP_H[%NP%]=%%h:/!rest!=%%"
del "%TMPD%d%NP%.txt" "%TMPD%d%NP%.tmp" >nul 2>&1
start "" /b cmd /c call "%SELF%" _doh %NP%
goto :eof

:doh_child
rem background: one DoH query for example.com, first with the server address fixed
rem (immune to fake DNS), then via normal lookup. Writes temp\d<n>.txt:
rem line 1 = "<http code> <seconds>", line 2 = the --resolve pin that worked (if any)
set "n=%~2"
set "Q=?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
set "pin=--resolve !DP_H[%n%]!:443:!DP_I[%n%]!"
"%CURL%" -s -o NUL -m 4 !pin! -H "accept: application/dns-message" -w "%%{http_code} %%{time_total}" "!DP_U[%n%]!!Q!" > "%TMPD%d%n%.tmp" 2>nul
set "code="
for /f "usebackq tokens=1" %%a in ("%TMPD%d%n%.tmp") do set "code=%%a"
if not "!code!"=="200" (
    set "pin="
    "%CURL%" -s -o NUL -m 4 -H "accept: application/dns-message" -w "%%{http_code} %%{time_total}" "!DP_U[%n%]!!Q!" > "%TMPD%d%n%.tmp" 2>nul
)
>> "%TMPD%d%n%.tmp" echo.
if defined pin >> "%TMPD%d%n%.tmp" echo !pin!
move /y "%TMPD%d%n%.tmp" "%TMPD%d%n%.txt" >nul
exit /b 0

:dns_read
set "code="
set "tt=0.0"
set "pin="
if not exist "%TMPD%d%1.txt" goto :dns_none
for /f "usebackq tokens=1,*" %%a in ("%TMPD%d%1.txt") do (
    if "%%a"=="--resolve" (set "pin=%%a %%b") else if not defined code (
        set "code=%%a"
        set "tt=%%b"
    )
)
:dns_none
if not "!code!"=="200" (
    echo   !DP_N[%1]!: no answer
    goto :eof
)
call :to_ms
echo   !DP_N[%1]!: !ms! ms
if !ms! geq !BESTMS! goto :eof
set /a BESTMS=ms
set "DOHNAME=!DP_N[%1]!"
set "DOHURL=!DP_U[%1]!"
set "DOHPIN=!pin!"
set "DOHIP=!DP_1[%1]!"
set "DOHIP2=!DP_2[%1]!"
set "DOHIP6=!DP_6[%1]!"
goto :eof

:apply_dns
rem The fastest encrypted DNS server becomes the computer's DNS (always; 6_RESET puts the old one back).
if not defined DOHIP goto :eof
if not exist "%RES%dns_backup.txt" call :backup_dns
rem every network adapter that has a default route (column 5 = interface number)
for /f "tokens=4,5" %%a in ('netsh interface ipv4 show route 2^>nul ^| findstr /c:"0.0.0.0/0"') do (
    netsh interface ipv4 set dnsservers name=%%b static %DOHIP% primary validate=no >nul 2>&1
    if not "%DOHIP2%"=="-" netsh interface ipv4 add dnsservers name=%%b %DOHIP2% index=2 validate=no >nul 2>&1
    rem no IPv6 address for this server: clear IPv6 DNS so all lookups go to it
    if "%DOHIP6%"=="-" (netsh interface ipv6 set dnsservers name=%%b static none validate=no >nul 2>&1) else (netsh interface ipv6 set dnsservers name=%%b static %DOHIP6% primary validate=no >nul 2>&1)
)
rem Windows 11: encrypt system DNS for these servers (ignored on Windows 10)
for %%s in (%DOHIP% %DOHIP2% %DOHIP6%) do if not "%%s"=="-" netsh dns add encryption server=%%s dohtemplate=%DOHURL% autoupgrade=yes udpfallback=no >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v DoHPolicy /t REG_DWORD /d 2 /f >nul 2>&1
ipconfig /flushdns >nul 2>&1
echo Encrypted DNS: %DOHNAME% is now your DNS.
goto :eof

:backup_dns
rem saves how each adapter got its DNS before AutoDPI changed it
> "%RES%dns_backup.txt" echo # interface^|dhcp   or   interface^|static^|address list
for /f "tokens=4,5" %%a in ('netsh interface ipv4 show route 2^>nul ^| findstr /c:"0.0.0.0/0"') do call :backup_one %%b
set "POL=none"
for /f "tokens=3" %%v in ('reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v DoHPolicy 2^>nul ^| findstr /i "DoHPolicy"') do set "POL=%%v"
>> "%RES%dns_backup.txt" echo POLICY^|!POL!
goto :eof

:backup_one
netsh interface ipv4 show dnsservers name=%1 2>nul | findstr /i "DHCP" >nul
if not errorlevel 1 (
    >> "%RES%dns_backup.txt" echo %1^|dhcp
    goto :eof
)
set "ips="
for /f "tokens=1,2 delims=:" %%x in ('netsh interface ipv4 show dnsservers name^=%1 2^>nul ^| findstr /r "[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"') do (
    if "%%y"=="" (set "ips=!ips! %%x") else (set "ips=!ips! %%y")
)
>> "%RES%dns_backup.txt" echo %1^|static^|!ips!
goto :eof

:restore_dns
if not exist "%RES%dns_backup.txt" goto :eof
for /f "usebackq eol=# tokens=1-3 delims=|" %%a in ("%RES%dns_backup.txt") do call :restore_one %%a %%b "%%c"
ipconfig /flushdns >nul 2>&1
echo DNS settings restored.
goto :eof

:restore_one
if "%1"=="POLICY" (
    if "%2"=="none" (
        reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v DoHPolicy /f >nul 2>&1
    ) else (
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" /v DoHPolicy /t REG_DWORD /d %2 /f >nul 2>&1
    )
    goto :eof
)
netsh interface ipv6 set dnsservers name=%1 source=dhcp >nul 2>&1
if "%2"=="dhcp" (
    netsh interface ipv4 set dnsservers name=%1 source=dhcp >nul 2>&1
    goto :eof
)
set "n=0"
for %%i in (%~3) do (
    set /a n+=1
    if !n!==1 (netsh interface ipv4 set dnsservers name=%1 static %%i primary validate=no >nul 2>&1) else (netsh interface ipv4 add dnsservers name=%1 %%i index=!n! validate=no >nul 2>&1)
)
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
choice /c YN /m "Reset AutoDPI to defaults (test sites, saved settings, results, autostart, DNS)"
if errorlevel 2 exit /b 0
call :restore_dns
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
