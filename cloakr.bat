@echo off
setlocal
title Cloakr - Safer Internet Access
mode con: cols=80 lines=36 >nul 2>&1

rem ============ CONFIG ============
rem Folder layout (everything next to this file, avoid spaces in the path):
rem   tor\tor.exe        (Tor Expert Bundle)
rem   tun2socks.exe      (github.com/xjasonlyu/tun2socks, windows-amd64)
rem   wintun.dll         (wintun.net, amd64)
set "BASE=%~dp0"
set "TOR_EXE=%BASE%tor\tor.exe"
set "T2S_EXE=%BASE%tun2socks.exe"
set "TORRC=%BASE%torrc.generated"
set "LOG=%BASE%tor.log"
set "COOKIE=%BASE%tor-data\control_auth_cookie"
set "BRIDGES=%BASE%bridges.txt"
set "BRFLAG=%BASE%bridges.enabled"
set "TUN=torsurf"
set "TUN_IP=10.66.0.2"
set "TUN_GW=10.66.0.1"
rem Apps that keep old (non-Tor) connections open; offered to be closed on start
set "RISKY=chrome.exe msedge.exe firefox.exe brave.exe opera.exe thunderbird.exe dropbox.exe onedrive.exe skype.exe telegram.exe discord.exe steam.exe qbittorrent.exe"
rem ================================

set "ACTION=%~1"
set "MENU="
if "%ACTION%"=="" set "MENU=1"

rem --- self-elevate to Administrator ---
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator rights...
    if defined MENU (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%ACTION%' -Verb RunAs"
    )
    exit /b
)

rem --- ANSI colors (Windows 10+) ---
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "X=%ESC%[0m"
set "Y=%ESC%[93m"
set "W=%ESC%[97m"
set "G=%ESC%[92m"
set "R=%ESC%[91m"
set "D=%ESC%[90m"
set "C1=%ESC%[38;5;196m"
set "C2=%ESC%[38;5;202m"
set "C3=%ESC%[38;5;208m"
set "C4=%ESC%[38;5;214m"
set "C5=%ESC%[38;5;220m"
set "C6=%ESC%[38;5;226m"

:dispatch
if defined MENU goto menu
if /i "%ACTION%"=="start"   goto start
if /i "%ACTION%"=="stop"    goto stop
if /i "%ACTION%"=="restart" goto start
if /i "%ACTION%"=="status"  goto status
if /i "%ACTION%"=="myip"    goto myip
if /i "%ACTION%"=="change"  goto change
if /i "%ACTION%"=="kill"    goto killapps
if /i "%ACTION%"=="bridges" goto bridges
echo Usage: %~nx0 [start^|stop^|restart^|status^|myip^|change^|kill^|bridges]
exit /b 1

rem ------------------------------------------------------------
:menu
cls
call :getstatus
call :banner
echo.
if "%CONN%"=="1" (
    echo   %W%Status: %G%[+] CONNECTED%W% - traffic is routed through Tor%X%
) else (
    echo   %W%Status: %R%[-] NOT CONNECTED%W% - you are on your normal connection%X%
)
if exist "%BRFLAG%" (
    echo   %W%Bridges: %G%ON%X%
) else (
    echo   %W%Bridges: %D%off%X%
)
echo.
echo   %Y%+-- %W%(1) Start     %D%connect and route everything via Tor%X%
echo   %Y%+-- %W%(2) Stop      %D%back to your normal internet%X%
echo   %Y%+-- %W%(3) Restart%X%
echo   %Y%+-- %W%(4) Status    %D%details and exit IP%X%
echo   %Y%+-- %W%(5) My IP     %D%check your Tor exit IP%X%
echo   %Y%+-- %W%(6) Change    %D%get a new Tor identity%X%
echo   %Y%+-- %W%(7) Kill      %D%close apps that may leak%X%
echo   %Y%+-- %W%(8) Bridges   %D%add and enable Tor bridges%X%
echo   %Y%+-- %W%(0) Exit%X%
echo.
<nul set /p "=%Y%  +--> %X%"
choice /c 123456780R /n /t 15 /d R >nul
set "SEL=%errorlevel%"
echo.
if "%SEL%"=="1" goto start
if "%SEL%"=="2" goto stop
if "%SEL%"=="3" goto start
if "%SEL%"=="4" goto status
if "%SEL%"=="5" goto myip
if "%SEL%"=="6" goto change
if "%SEL%"=="7" goto killapps
if "%SEL%"=="8" goto bridges
if "%SEL%"=="10" goto menu
exit /b 0

:done
if defined MENU (
    echo.
    pause
    goto menu
)
exit /b 0

rem ------------------------------------------------------------
:start
for %%f in ("%TOR_EXE%" "%T2S_EXE%" "%BASE%wintun.dll") do (
    if not exist %%f (
        echo %R%[!] Missing: %%~f%X%
        echo     See the folder layout at the top of this script.
        goto done
    )
)

call :cleanup >nul 2>&1

echo.
choice /c YN /m "Close apps that may hold non-Tor connections (browsers, cloud sync, chat)"
if not errorlevel 2 call :killrisky

set "PHYIP="
set "GW="
set "BESTM=999999"
for /f "tokens=3,4,5" %%a in ('route print -4 ^| findstr /r /c:"^ *0\.0\.0\.0 *0\.0\.0\.0 "') do call :pickroute %%a %%b %%c
if not defined PHYIP (
    echo %R%[!] Could not detect your active network adapter. Are you online?%X%
    goto done
)
echo %Y%[*]%X% Physical adapter IP: %PHYIP%   gateway: %GW%

set "B=%BASE:\=/%"
(
    echo SocksPort 127.0.0.1:9050
    echo DNSPort 127.0.0.1:53
    echo ControlPort 127.0.0.1:9051
    echo CookieAuthentication 1
    echo OutboundBindAddress %PHYIP%
    echo DataDirectory %B%tor-data
    echo Log notice file %B%tor.log
) > "%TORRC%"
if exist "%BASE%data\geoip" >>"%TORRC%" echo GeoIPFile %B%data/geoip
if exist "%BASE%data\geoip6" >>"%TORRC%" echo GeoIPv6File %B%data/geoip6

rem --- bridges (optional) ---
if exist "%BRFLAG%" if exist "%BRIDGES%" (
    call :setupbridges
    if "%BRFAIL%"=="1" goto fail
    call :bridgeroutes add
)

echo %Y%[*]%X% Starting Tor...
if exist "%LOG%" del "%LOG%" >nul 2>&1
start "" /min "%TOR_EXE%" -f "%TORRC%"

set /a tries=0
:wait_tor
findstr /c:"Bootstrapped 100%%" "%LOG%" >nul 2>&1
if not errorlevel 1 goto tor_ready
set /a tries+=1
if %tries% geq 90 goto fail
timeout /t 1 /nobreak >nul
goto wait_tor

:tor_ready
echo %Y%[*]%X% Tor connected. Creating tunnel...
set "T2SLOG=%BASE%tun2socks.log"
if exist "%T2SLOG%" del "%T2SLOG%" >nul 2>&1
>"%BASE%run-t2s.cmd" echo @"%T2S_EXE%" --device tun://%TUN% --proxy socks5://127.0.0.1:9050 --loglevel info ^> "%T2SLOG%" 2^>^&1
start "" /min "%BASE%run-t2s.cmd"

set /a tries=0
:wait_tun
netsh interface show interface name="%TUN%" >nul 2>&1
if not errorlevel 1 goto tun_ready
ipconfig | find /i "%TUN%" >nul
if not errorlevel 1 goto tun_ready
set /a tries+=1
if %tries% geq 20 goto tunfail
timeout /t 1 /nobreak >nul
goto wait_tun

:tunfail
echo %R%[!] The tunnel adapter never appeared.%X%
tasklist /fi "imagename eq tun2socks.exe" 2>nul | find /i "tun2socks.exe" >nul
if errorlevel 1 (
    echo     tun2socks.exe exited right away. Antivirus may have blocked it.
) else (
    echo     tun2socks.exe is running but did not create the adapter.
)
echo     Its output follows:
if exist "%T2SLOG%" type "%T2SLOG%"
goto fail

:tun_ready
echo %Y%[*]%X% Configuring tunnel adapter...
netsh interface ip set address name="%TUN%" source=static addr=%TUN_IP% mask=255.255.255.0 gateway=none
if errorlevel 1 (
    echo %R%[!] Could not set the tunnel adapter address.%X%
    goto fail
)
netsh interface ipv4 set interface "%TUN%" metric=1 >nul
timeout /t 2 /nobreak >nul
set "TUNIDX="
for /f "tokens=1,5" %%a in ('netsh interface ipv4 show interfaces ^| findstr /i /c:"%TUN%"') do set "TUNIDX=%%a"
if not defined TUNIDX (
    echo %R%[!] Could not find the tunnel adapter index.%X%
    goto fail
)
route add 0.0.0.0 mask 128.0.0.0 %TUN_GW% metric 1 if %TUNIDX%
if errorlevel 1 goto routefail
route add 128.0.0.0 mask 128.0.0.0 %TUN_GW% metric 1 if %TUNIDX%
if errorlevel 1 goto routefail

echo %Y%[*]%X% Sending DNS through Tor, disabling IPv6...
powershell -NoProfile -Command "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne '%TUN%' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses 127.0.0.1 }"
powershell -NoProfile -Command "Disable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6" >nul 2>&1
ipconfig /flushdns >nul

echo %Y%[*]%X% Verifying that traffic really goes through Tor...
call :verify
if "%VERIFY%"=="leak" goto leakfail
echo.
if "%VERIFY%"=="ok" (
    echo %G%[+] CONNECTED and verified - exit IP %VR:~4%%X%
) else (
    echo %Y%[!] Connected, but could not verify. Try option 5 in a minute.%X%
)
goto done

:routefail
echo %R%[!] Adding the tunnel routes failed ^(see the message above^).%X%
goto fail

:leakfail
echo %R%[!] Tor is running but your traffic is NOT going through it. Exit IP: %VR:~5%%X%
echo     Diagnostics:
route print -4 | findstr /r /c:"^ *0\.0\.0\.0 *128\.0\.0\.0" /c:"^ *128\.0\.0\.0 *128\.0\.0\.0" /c:"10\.66\.0"
netsh interface ipv4 show interfaces | findstr /i /c:"%TUN%"
if exist "%T2SLOG%" type "%T2SLOG%"
echo %Y%[*]%X% Rolling back to your normal connection for safety...
call :cleanup >nul 2>&1
goto done

:fail
echo %R%[!] Failed to start. See %LOG%%X%
call :cleanup >nul 2>&1
goto done

rem ------------------------------------------------------------
:stop
echo %Y%[*]%X% Restoring normal networking...
call :cleanup >nul 2>&1
echo %R%[-] DISCONNECTED - back on your normal connection.%X%
goto done

rem ------------------------------------------------------------
:status
call :getstatus
if "%CONN%"=="1" (
    echo %G%[+] CONNECTED%X% - Tor running, tunnel up, routes active
) else (
    echo %R%[-] NOT CONNECTED%X%
)
call :checkip
goto done

rem ------------------------------------------------------------
:myip
call :checkip
goto done

rem ------------------------------------------------------------
:change
if not exist "%COOKIE%" (
    echo %R%[!] Tor is not running, or no control cookie found. Start first.%X%
    goto done
)
powershell -NoProfile -Command "try { $c=[IO.File]::ReadAllBytes('%COOKIE%'); $h=($c | ForEach-Object { $_.ToString('x2') }) -join ''; $t=New-Object Net.Sockets.TcpClient('127.0.0.1',9051); $s=$t.GetStream(); $w=New-Object IO.StreamWriter($s); $r=New-Object IO.StreamReader($s); $w.Write('AUTHENTICATE ' + $h + [char]13 + [char]10); $w.Flush(); $a=$r.ReadLine(); $w.Write('SIGNAL NEWNYM' + [char]13 + [char]10); $w.Flush(); $n=$r.ReadLine(); $t.Close(); 'Auth: ' + $a + '  NewNym: ' + $n } catch { 'Could not talk to Tor control port.' }"
echo %Y%[*]%X% New identity requested. Waiting a few seconds for a new circuit...
timeout /t 5 /nobreak >nul
call :checkip
goto done

rem ------------------------------------------------------------
:killapps
call :killrisky
goto done

rem ------------------------------------------------------------
:bridges
cls
call :banner
echo.
set "BCOUNT=0"
if exist "%BRIDGES%" for /f "usebackq eol=# delims=" %%L in ("%BRIDGES%") do set /a BCOUNT+=1
echo   %W%Tor bridges help when Tor is blocked or you want to hide Tor use.%X%
echo   %D%Get obfs4 bridges at https://bridges.torproject.org then paste them here.%X%
echo.
if exist "%BRFLAG%" (
    echo   %W%Bridges: %G%ENABLED%W%   saved: %BCOUNT%%X%
) else (
    echo   %W%Bridges: %R%DISABLED%W%   saved: %BCOUNT%%X%
)
echo.
echo   %Y%+-- %W%(A) Add a bridge line%X%
echo   %Y%+-- %W%(D) Auto-add fastest built-in bridges%X%
echo   %Y%+-- %W%(E) Enable / disable bridges%X%
echo   %Y%+-- %W%(L) List saved bridges%X%
echo   %Y%+-- %W%(C) Clear all bridges%X%
echo   %Y%+-- %W%(O) Edit bridges.txt in Notepad%X%
echo   %Y%+-- %W%(B) Back%X%
echo.
<nul set /p "=%Y%  +--> %X%"
choice /c ADELCOB /n >nul
set "BSEL=%errorlevel%"
echo.
if "%BSEL%"=="1" goto bridge_add
if "%BSEL%"=="2" goto bridge_auto
if "%BSEL%"=="3" goto bridge_toggle
if "%BSEL%"=="4" goto bridge_list
if "%BSEL%"=="5" goto bridge_clear
if "%BSEL%"=="6" goto bridge_edit
if defined MENU goto menu
exit /b 0

:bridge_add
set "NEWB="
set /p "NEWB=  Paste bridge line: "
if not defined NEWB goto bridges
echo %NEWB%| find ":" >nul
if errorlevel 1 (
    echo %R%[!] That does not look like a bridge line.%X%
    pause
    goto bridges
)
>>"%BRIDGES%" echo %NEWB%
echo %G%[+] Bridge saved.%X%
if not exist "%BRFLAG%" (
    echo %Y%[*]%X% Bridges are still disabled. Choose E to enable them.
)
pause
goto bridges

:bridge_auto
if not exist "%BASE%cloakr-bridges.ps1" (
    echo %R%[!] cloakr-bridges.ps1 not found. Keep it in the same folder as this script.%X%
    pause
    goto bridges
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%cloakr-bridges.ps1" -Base "%BASE:~0,-1%" -Out "%BRIDGES%" -Top 5
if errorlevel 1 (
    echo.
    echo %R%[!] No bridges were added.%X%
) else (
    >"%BRFLAG%" echo on
    echo.
    echo %G%[+] Bridges enabled. Choose Start ^(or Restart^) to use them.%X%
)
pause
goto bridges

:bridge_toggle
if exist "%BRFLAG%" (
    del "%BRFLAG%" >nul 2>&1
    echo %R%[-] Bridges disabled.%X%
) else (
    if not exist "%BRIDGES%" (
        echo %R%[!] No bridges saved yet. Add one first.%X%
        pause
        goto bridges
    )
    >"%BRFLAG%" echo on
    echo %G%[+] Bridges enabled.%X%
)
call :getstatus
if "%CONN%"=="1" echo %Y%[*]%X% Restart Cloakr to apply the change.
pause
goto bridges

:bridge_list
echo.
if exist "%BRIDGES%" (type "%BRIDGES%") else (echo   No bridges saved.)
echo.
pause
goto bridges

:bridge_clear
choice /c YN /m "Delete ALL saved bridges"
if not errorlevel 2 (
    del "%BRIDGES%" >nul 2>&1
    del "%BRFLAG%" >nul 2>&1
    echo %Y%[*]%X% Bridges cleared.
    pause
)
goto bridges

:bridge_edit
if not exist "%BRIDGES%" >"%BRIDGES%" echo # One bridge per line. Example: obfs4 1.2.3.4:443 FINGERPRINT cert=... iat-mode=0
start /wait notepad "%BRIDGES%"
goto bridges

rem ============ subroutines ============
:banner
echo.
echo %C1%    mmmm   mmmm                          mm%X%
echo %C2%  ##""""#  ""##                          ##%X%
echo %C3% ##"         ##       m####m    m#####m  ## m##"    ##m####%X%
echo %C4% ##          ##      ##"  "##   " mmm##  ##m##      ##"%X%
echo %C5% ##m         ##      ##    ##  m##"""##  ##"##m     ##%X%
echo %C6%  ##mmmm#    ##mmm   "##mm##"  ##mmm###  ##  "#m    ##%X%
echo %C6%    """"      """"     """"     """" ""  ""   """   ""%X%
echo %D%                 Anonymity starts with you%X%
exit /b 0

:getstatus
set "CONN=0"
tasklist /fi "imagename eq tor.exe" 2>nul | find /i "tor.exe" >nul
if errorlevel 1 exit /b 0
netsh interface show interface name="%TUN%" >nul 2>&1
if errorlevel 1 exit /b 0
route print -4 2>nul | findstr /r /c:"^ *128\.0\.0\.0 *128\.0\.0\.0 *10\.66\.0\.1" >nul
if errorlevel 1 exit /b 0
set "CONN=1"
exit /b 0

:pickroute
if "%~3"=="" exit /b 0
if /i "%~1"=="On-link" exit /b 0
echo %~1| find "." >nul
if errorlevel 1 exit /b 0
echo %~2| find "." >nul
if errorlevel 1 exit /b 0
if %~3 lss %BESTM% (
    set "GW=%~1"
    set "PHYIP=%~2"
    set "BESTM=%~3"
)
exit /b 0

:killrisky
echo %Y%[*]%X% Closing risky apps...
for %%a in (%RISKY%) do taskkill /f /im %%a >nul 2>&1
exit /b 0

:verify
set "VERIFY=unknown"
set "VR="
powershell -NoProfile -Command "try { $r=Invoke-RestMethod 'https://check.torproject.org/api/ip' -TimeoutSec 25; if ($r.IsTor) { 'TOR ' + $r.IP } else { 'LEAK ' + $r.IP } } catch { 'ERR' }" > "%TEMP%\cloakr_v.txt" 2>&1
set /p VR=<"%TEMP%\cloakr_v.txt"
if "%VR:~0,3%"=="TOR" set "VERIFY=ok"
if "%VR:~0,4%"=="LEAK" set "VERIFY=leak"
exit /b 0

:checkip
powershell -NoProfile -Command "try { $r=Invoke-RestMethod 'https://check.torproject.org/api/ip' -TimeoutSec 20; 'Exit IP: ' + $r.IP + '   Using Tor: ' + $r.IsTor } catch { 'Could not reach check.torproject.org' }"
exit /b 0

rem --- write bridge settings into torrc ---
:setupbridges
set "BRFAIL=0"
set "BRN=0"
set "NEEDPT=0"
set "PTEXE="
if exist "%BASE%tor\pluggable_transports\lyrebird.exe" set "PTEXE=%BASE%tor\pluggable_transports\lyrebird.exe"
if not defined PTEXE if exist "%BASE%tor\pluggable_transports\obfs4proxy.exe" set "PTEXE=%BASE%tor\pluggable_transports\obfs4proxy.exe"
>>"%TORRC%" echo UseBridges 1
for /f "usebackq eol=# delims=" %%L in ("%BRIDGES%") do (
    set "BLINE=%%L"
    call :bridgeadd
)
if "%BRN%"=="0" (
    echo %R%[!] Bridges are enabled but no usable bridge lines were found.%X%
    set "BRFAIL=1"
    exit /b 0
)
if "%NEEDPT%"=="1" (
    if not defined PTEXE (
        echo %R%[!] obfs4 bridges need lyrebird.exe or obfs4proxy.exe in tor\pluggable_transports\%X%
        set "BRFAIL=1"
        exit /b 0
    )
    call :writept
)
echo %Y%[*]%X% Using %BRN% bridge^(s^).
exit /b 0

:writept
set "PTF=%PTEXE:\=/%"
>>"%TORRC%" echo ClientTransportPlugin obfs4 exec %PTF%
exit /b 0

:bridgeadd
set "BLINE=%BLINE:Bridge =%"
set "BTYPE="
for /f "tokens=1" %%a in ("%BLINE%") do set "BTYPE=%%a"
echo %BTYPE%| find "." >nul
if errorlevel 1 (
    if /i "%BTYPE%"=="obfs4" (
        set "NEEDPT=1"
    ) else (
        echo %R%[!] Skipping unsupported bridge type: %BTYPE%%X%
        exit /b 0
    )
)
>>"%TORRC%" echo Bridge %BLINE%
set /a BRN+=1
exit /b 0

rem --- host routes so bridge traffic bypasses the tunnel (usage: call :bridgeroutes add or del) ---
:bridgeroutes
set "BMODE=%~1"
if not exist "%BRIDGES%" exit /b 0
for /f "usebackq eol=# delims=" %%L in ("%BRIDGES%") do (
    set "BLINE=%%L"
    call :bridgeroute1
)
exit /b 0

:bridgeroute1
set "BLINE=%BLINE:Bridge =%"
set "BADDR="
for /f "tokens=1,2" %%a in ("%BLINE%") do (
    echo %%a| find "." >nul
    if errorlevel 1 (set "BADDR=%%b") else (set "BADDR=%%a")
)
if not defined BADDR exit /b 0
echo %BADDR%| find "[" >nul
if not errorlevel 1 exit /b 0
set "BIP="
for /f "delims=:" %%i in ("%BADDR%") do set "BIP=%%i"
if not defined BIP exit /b 0
if /i "%BMODE%"=="add" if defined GW route add %BIP% mask 255.255.255.255 %GW% metric 1 >nul 2>&1
if /i "%BMODE%"=="del" route delete %BIP% mask 255.255.255.255 >nul 2>&1
exit /b 0

:cleanup
route delete 0.0.0.0 mask 128.0.0.0 %TUN_GW%
route delete 128.0.0.0 mask 128.0.0.0 %TUN_GW%
call :bridgeroutes del
taskkill /f /im tun2socks.exe
taskkill /f /im tor.exe
powershell -NoProfile -Command "Get-NetAdapter | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }"
powershell -NoProfile -Command "Enable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6"
ipconfig /flushdns
exit /b 0
