@echo off
rem Loads test site %1 with curl (called by autodpi.cmd).
rem Writes "<http code> <seconds> <final url>" to temp\r<n>.txt.
rem Only the first 16 KB are fetched (enough to know the site opened) - unless the
rem site has a keyword to check, then the page is saved and searched.
rem DOHARGS (set by autodpi.cmd) makes curl look the site up with encrypted DNS.
setlocal EnableDelayedExpansion
set "OUT=NUL"
set "LIMIT=--max-filesize 16384"
if defined K[%1] (
    set "OUT=%TMPD%b%1.htm"
    set "LIMIT="
)
"%CURL%" -s -L --max-redirs 5 --ssl-no-revoke !LIMIT! %DOHARGS% --connect-timeout %PT% -m %PT% -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36" -H "Accept: text/html,*/*" -H "Accept-Language: en-US,en;q=0.9" -o "!OUT!" -w "%%{http_code} %%{time_total} %%{url_effective}" "!S[%1]!" >"%TMPD%r%1.tmp" 2>nul
move /y "%TMPD%r%1.tmp" "%TMPD%r%1.txt" >nul
