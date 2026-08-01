@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: install_SigMohar_roots.bat
::
:: Downloads CA certificates from ca.sigmohar.com and, ONLY after explicit
:: confirmation at each step, trusts them using Windows' built-in
:: certutil.exe (NOT related to NSS's certutil - this is the native Windows
:: cert-store tool, bundled since Windows XP). No PowerShell is used, so
:: there is no script Execution Policy to work around.
::
:: WHAT IT DOES:
::   1. Installs into the Windows certificate store (Trusted Root
::      Certification Authorities) - covers Edge, Chrome, curl, and most
::      system tools, since they all read the Windows store directly.
::   2. Firefox keeps its own trust store. Rather than needing NSS tooling
::      that Windows doesn't ship, this offers to enable Mozilla's official
::      "ImportEnterpriseRoots" policy via the registry, so Firefox trusts
::      whatever Windows already trusts.
::
:: DESIGN PRINCIPLES (same as the Linux/macOS/PowerShell versions):
::   - No auto-discovery of cert IDs. List them below, split into categories.
::   - Nothing is installed without an explicit y/N confirmation showing
::     exactly what will be affected.
::   - Downloaded files live only in a temp folder, removed when the
::     script finishes normally.
::
:: NOTE ON CLEANUP: unlike the bash version's trap-based cleanup, plain
:: .bat has no reliable way to catch Ctrl+C. If interrupted mid-run, the
:: temp folder under %TEMP% may be left behind. It only ever contains
:: public certificate files (no secrets), and normal Windows temp-folder
:: housekeeping clears it out eventually.
::
:: NOTE ON CERT IDs: keep them simple - letters, digits, hyphens. Avoid
:: spaces or characters like %% ^^ & | since IDs are used directly in
:: URLs, filenames, and internal lookups.
::
:: USAGE:
::   install_SigMohar_roots.bat                    interactive category menu
::   install_SigMohar_roots.bat --category 2        pick a category directly
::   install_SigMohar_roots.bat C1-R C2-R           bypass categories, install exactly these
::   install_SigMohar_roots.bat -y --category 3      skip confirmations too
::
:: Right-click this file and choose "Run as administrator" for the full
:: effect (system-wide store + machine-wide Firefox policy). Running
:: without elevation still works, offering current-user-only equivalents.
:: Windows SmartScreen may show a one-time "protected your PC" prompt for
:: a downloaded .bat file - click "More info" then "Run anyway". That is
:: unrelated to, and does not require touching, any PowerShell setting.
:: ============================================================================

set "BASE_URL=https://ca.sigmohar.com/r"
if defined CA_BASE_URL set "BASE_URL=%CA_BASE_URL%"

:: ---- Category 1: Comm-Set Roots (TLS only) --------------------------------
:: Space-separated cert IDs (the "XXXX" in %BASE_URL%/XXXX.crt).
:: Example: set "COMM_SET_ROOTS=C1-R C2-R"
set "COMM_SET_ROOTS=C1-R C2-R"

:: ---- Category 2 adds: Sign-Set Roots (eSign / code signing / device ID / S-MIME)
:: Example: set "SIGN_SET_ROOTS=S1-R S2-R S3-R S4-R S5-R"
set "SIGN_SET_ROOTS=S1-R S2-R S3-R S4-R S5-R"

:: ---- Category 3 adds: PKI-Set Roots (custom/internal PKI) -----------------
:: Example: set "PKI_SET_ROOTS=P1-R"
set "PKI_SET_ROOTS=P1-R"

:: ============================== END CONFIG ==================================

set "ASSUME_YES=0"
set "CATEGORY="
set "EXPLICIT_IDS="
set "EXITCODE=0"

:: --------------------------------------------------------------------------
:: 0. Admin check
:: --------------------------------------------------------------------------
net session >nul 2>&1
if !errorlevel! EQU 0 (set "IS_ADMIN=1") else (set "IS_ADMIN=0")

:: --------------------------------------------------------------------------
:: 1. Parse arguments
:: --------------------------------------------------------------------------
:PARSE_ARGS
if "%~1"=="" goto ARGS_DONE
if /I "%~1"=="-y" (
    set "ASSUME_YES=1"
    shift
    goto PARSE_ARGS
)
if /I "%~1"=="--yes" (
    set "ASSUME_YES=1"
    shift
    goto PARSE_ARGS
)
if /I "%~1"=="-c" (
    set "CATEGORY=%~2"
    shift
    shift
    goto PARSE_ARGS
)
if /I "%~1"=="--category" (
    set "CATEGORY=%~2"
    shift
    shift
    goto PARSE_ARGS
)
if /I "%~1"=="-h" goto SHOW_HELP
if /I "%~1"=="--help" goto SHOW_HELP
if /I "%~1"=="/?" goto SHOW_HELP
set "ARG=%~1"
if /I "!ARG:~0,11!"=="--category=" (
    set "CATEGORY=!ARG:~11!"
    shift
    goto PARSE_ARGS
)
set "EXPLICIT_IDS=!EXPLICIT_IDS! %~1"
shift
goto PARSE_ARGS

:SHOW_HELP
echo Usage: %~nx0 [--category 1^|2^|3] [-y] [explicit-cert-id ...]
exit /b 0

:ARGS_DONE

:: --------------------------------------------------------------------------
:: 2. Figure out CERT_IDS: explicit override, --category flag, or menu
:: --------------------------------------------------------------------------
set "CERT_IDS="

if not "!EXPLICIT_IDS!"=="" (
    set "CERT_IDS=!EXPLICIT_IDS!"
    echo [INFO] Explicit cert ID^(s^) given on the command line - skipping category selection.
) else (
    if "!CATEGORY!"=="" (
        if "!ASSUME_YES!"=="1" (
            echo ERROR: -y was given without --category or explicit cert IDs.
            echo ERROR: Refusing to guess which certificate set to install.
            exit /b 1
        )
        echo.
        echo Select which certificate set to install:
        echo   1^) Comm-Set only              - TLS certificates only
        echo   2^) Comm-Set + Sign-Set        - TLS + eSign / code signing / device ID / S-MIME
        echo   3^) Full Set ^(Comm+Sign+PKI^)   - TLS + eSign + your custom internal PKI roots
        set /p "CATEGORY=Enter choice [1-3]: "
    )

    if "!CATEGORY!"=="1" set "CERT_IDS=!COMM_SET_ROOTS!"
    if "!CATEGORY!"=="2" set "CERT_IDS=!COMM_SET_ROOTS! !SIGN_SET_ROOTS!"
    if "!CATEGORY!"=="3" set "CERT_IDS=!COMM_SET_ROOTS! !SIGN_SET_ROOTS! !PKI_SET_ROOTS!"

    if "!CERT_IDS!"=="" if not "!CATEGORY!"=="1" if not "!CATEGORY!"=="2" if not "!CATEGORY!"=="3" (
        echo ERROR: Invalid category [!CATEGORY!] - must be 1, 2, or 3.
        exit /b 1
    )
)

:: trim a leading space, if any (purely cosmetic)
for /f "tokens=* delims= " %%A in ("!CERT_IDS!") do set "CERT_IDS=%%A"

if "!CERT_IDS!"=="" (
    echo ERROR: No cert IDs configured for this selection.
    echo ERROR: Edit COMM_SET_ROOTS / SIGN_SET_ROOTS / PKI_SET_ROOTS at the top of this script,
    echo ERROR: or pass IDs directly: %~nx0 xxxx1 xxxx2
    exit /b 1
)

:: --------------------------------------------------------------------------
:: 3. Temp folder for downloads
:: --------------------------------------------------------------------------
set "WORKDIR=%TEMP%\sigmohar-roots-%RANDOM%%RANDOM%"
mkdir "!WORKDIR!" >nul 2>&1
type nul >"!WORKDIR!\nicknames.txt"

:: --------------------------------------------------------------------------
:: 4. Check for a downloader: curl.exe (ships with Windows 10 1803+ / 11)
::    or fall back to certutil's own -urlcache trick, which works on any
::    version of Windows.
:: --------------------------------------------------------------------------
where curl >nul 2>&1
if !errorlevel! EQU 0 (set "HAVE_CURL=1") else (set "HAVE_CURL=0")

echo.
echo About to download the following, into a temp folder that will be removed afterward:
for %%A in (!CERT_IDS!) do echo   !BASE_URL!/%%A.crt
call :CONFIRM "Proceed with downloading these file(s)?"
if not "!CONFIRM_RESULT!"=="YES" (
    echo [INFO] Aborted by user before any download.
    goto CLEANUP_AND_EXIT
)

:: --------------------------------------------------------------------------
:: 5. Download + validate each cert
:: --------------------------------------------------------------------------
set "FETCHED_IDS="
for %%A in (!CERT_IDS!) do call :FETCH_ONE %%A

if "!FETCHED_IDS!"=="" (
    echo ERROR: No certificates were successfully downloaded/validated. Nothing to install.
    set "EXITCODE=1"
    goto CLEANUP_AND_EXIT
)

echo.
echo Successfully fetched and validated the following:
for %%A in (!FETCHED_IDS!) do (
    call :GET_NICK %%A
    echo   - !NICK! ^(%%A^)
)

:: --------------------------------------------------------------------------
:: 6. Windows certificate store
:: --------------------------------------------------------------------------
set "STORE_SCOPE="
if "!IS_ADMIN!"=="1" (
    echo.
    echo The following cert^(s^) can be added to the SYSTEM-WIDE Trusted Root store.
    echo This affects every user and application on this machine that uses the
    echo Windows certificate store, including Edge and Chrome.
    for %%A in (!FETCHED_IDS!) do (
        call :GET_NICK %%A
        echo   - !NICK!
    )
    call :CONFIRM "Proceed with system-wide (machine) trust store installation?"
    if "!CONFIRM_RESULT!"=="YES" (
        set "STORE_SCOPE=MACHINE"
    ) else (
        echo [INFO] Skipped system-wide trust store installation.
    )
) else (
    echo.
    echo [WARNING] Not running as Administrator - cannot write to the machine-wide store.
    call :CONFIRM "Install into your CURRENT USER trust store instead (affects only your account)?"
    if "!CONFIRM_RESULT!"=="YES" (
        set "STORE_SCOPE=USER"
    ) else (
        echo [INFO] Skipped certificate store installation entirely.
    )
)

if not "!STORE_SCOPE!"=="" (
    for %%A in (!FETCHED_IDS!) do call :INSTALL_STORE_ONE %%A
)

:: --------------------------------------------------------------------------
:: 7. Firefox: enable "trust the OS store" policy via the registry, instead
::    of needing NSS tooling Windows doesn't ship with.
:: --------------------------------------------------------------------------
echo.
echo Firefox keeps its own trust store separate from Windows. Rather than
echo needing extra NSS tooling to inject certs into each profile, this can
echo enable Mozilla's official 'ImportEnterpriseRoots' policy, so Firefox
echo trusts whatever Windows already trusts - including any future certs.

set "REG_ROOT="
set "REG_SCOPE_DESC="
if "!IS_ADMIN!"=="1" (
    set "REG_ROOT=HKLM\SOFTWARE\Policies\Mozilla\Firefox"
    set "REG_SCOPE_DESC=all users on this machine (HKLM)"
) else (
    echo [WARNING] Not running as Administrator - the machine-wide ^(HKLM^) policy location isn't writable.
    call :CONFIRM "Set this policy for your user account only instead (HKCU)?"
    if "!CONFIRM_RESULT!"=="YES" (
        set "REG_ROOT=HKCU\SOFTWARE\Policies\Mozilla\Firefox"
        set "REG_SCOPE_DESC=your user account only (HKCU)"
    )
)

if not "!REG_ROOT!"=="" (
    call :CHECK_FIREFOX_ALREADY_SET "!REG_ROOT!"
    if "!ALREADY_SET!"=="1" (
        echo [INFO] Firefox 'ImportEnterpriseRoots' policy is already enabled ^(!REG_SCOPE_DESC!^).
    ) else (
        call :CONFIRM "Enable Firefox's ImportEnterpriseRoots policy for !REG_SCOPE_DESC!?"
        if "!CONFIRM_RESULT!"=="YES" (
            reg add "!REG_ROOT!" /v ImportEnterpriseRoots /t REG_DWORD /d 1 /f >nul
            echo [INFO] Enabled. Restart Firefox for it to take effect.
        ) else (
            echo [INFO] Skipped Firefox policy setup.
        )
    )
) else (
    echo [INFO] Skipped Firefox policy setup entirely.
)

goto CLEANUP_AND_EXIT

:: ============================================================================
:: Subroutines
:: All of these run as standalone, non-nested code (reached via call/goto),
:: which keeps their quoting/escaping simple and predictable regardless of
:: where they're called from.
:: ============================================================================

:CONFIRM
:: %~1 = prompt text. Sets CONFIRM_RESULT to YES or NO.
if "!ASSUME_YES!"=="1" (
    echo [INFO] (auto-confirmed via -y) %~1
    set "CONFIRM_RESULT=YES"
    goto :eof
)
set "REPLY="
set /p "REPLY=%~1 [y/N]: "
if /I "!REPLY!"=="Y" (
    set "CONFIRM_RESULT=YES"
) else if /I "!REPLY!"=="YES" (
    set "CONFIRM_RESULT=YES"
) else (
    set "CONFIRM_RESULT=NO"
)
goto :eof

:FETCH_ONE
:: %~1 = cert id
set "ID=%~1"
set "URL=!BASE_URL!/!ID!.crt"
set "RAWFILE=!WORKDIR!\!ID!.crt"
set "DUMPFILE=!WORKDIR!\!ID!.dump.txt"

echo [INFO] Downloading !URL!
if "!HAVE_CURL!"=="1" (
    curl -fsSL "!URL!" -o "!RAWFILE!" >nul 2>&1
) else (
    certutil -urlcache -split -f "!URL!" "!RAWFILE!" >nul 2>&1
)

if not exist "!RAWFILE!" (
    echo [WARNING] Failed to download '!ID!' - skipping.
    goto :eof
)

certutil -dump "!RAWFILE!" >"!DUMPFILE!" 2>nul
findstr /C:"Serial Number" "!DUMPFILE!" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] '!ID!' does not look like a valid certificate - skipping.
    del /q "!RAWFILE!" >nul 2>&1
    del /q "!DUMPFILE!" >nul 2>&1
    goto :eof
)

set "NICK="
for /f "tokens=1* delims==" %%K in ('findstr /C:"CN=" "!DUMPFILE!"') do (
    if not defined NICK set "NICK=%%L"
)
if not defined NICK set "NICK=!ID!"

echo !ID!=!NICK!>>"!WORKDIR!\nicknames.txt"
set "FETCHED_IDS=!FETCHED_IDS! !ID!"
echo [INFO]   -^> OK: '!NICK!' (!ID!)
goto :eof

:GET_NICK
:: %~1 = cert id. Sets NICK from the nicknames.txt lookup file (falls back
:: to the id itself if not found, which shouldn't normally happen).
set "NICK=%~1"
for /f "tokens=1,2 delims==" %%K in ('findstr /B /C:"%~1=" "!WORKDIR!\nicknames.txt"') do set "NICK=%%L"
goto :eof

:INSTALL_STORE_ONE
:: %~1 = cert id
set "ID=%~1"
set "RAWFILE=!WORKDIR!\!ID!.crt"
call :GET_NICK "!ID!"

if "!STORE_SCOPE!"=="MACHINE" (
    certutil -addstore -f "Root" "!RAWFILE!" >nul
) else (
    certutil -addstore -user -f "Root" "!RAWFILE!" >nul
)

if !errorlevel! EQU 0 (
    echo [INFO]   -^> trusted: '!NICK!' (!STORE_SCOPE!)
) else (
    echo [WARNING]   -^> failed to install '!NICK!' into the !STORE_SCOPE! store
)
goto :eof

:CHECK_FIREFOX_ALREADY_SET
:: %~1 = registry root path. Sets ALREADY_SET to 1 or 0.
set "ALREADY_SET=0"
set "REGDUMP=!WORKDIR!\regquery.txt"
reg query "%~1" /v ImportEnterpriseRoots >"!REGDUMP!" 2>nul
for /f "tokens=3" %%V in ('findstr /C:"ImportEnterpriseRoots" "!REGDUMP!"') do (
    if /I "%%V"=="0x1" set "ALREADY_SET=1"
)
goto :eof

:CLEANUP_AND_EXIT
echo.
echo [INFO] Finished. Removing temp folder: !WORKDIR!
if exist "!WORKDIR!" rmdir /s /q "!WORKDIR!" >nul 2>&1
exit /b !EXITCODE!