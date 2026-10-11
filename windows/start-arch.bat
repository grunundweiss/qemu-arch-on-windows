@echo off
rem ===========================================================================
rem  Starts the Arch Linux VM in QEMU (headless, VNC on 127.0.0.1) and opens
rem  TigerVNC. If the VM is already running, it only opens the viewer, so
rem  the same disk image is never booted twice.
rem
rem  All settings live in config.cmd next to this file.
rem ===========================================================================
setlocal
set "HERE=%~dp0"

if exist "%HERE%config.cmd" goto have_config
echo [ERROR] No config.cmd found in "%HERE%"
echo         Copy config.example.cmd to config.cmd and edit the paths in it.
pause
exit /b 1

:have_config
call "%HERE%config.cmd"

rem --- Defaults for anything config.cmd left out -----------------------------
if not defined VM_NAME     set "VM_NAME=Arch"
if not defined RAM         set "RAM=4G"
if not defined SMP         set "SMP=2"
if not defined ACCEL       set "ACCEL=whpx"
if not defined DISK_FORMAT set "DISK_FORMAT=qcow2"
if not defined DISK_IF     set "DISK_IF=ide"
if not defined XRES        set "XRES=1920"
if not defined YRES        set "YRES=1080"
if not defined VNC_DISPLAY set "VNC_DISPLAY=0"
set /a VNC_PORT=5900+VNC_DISPLAY

rem --- Already running? Just reconnect. --------------------------------------
call :port_open && goto viewer

rem --- Check that every file exists before starting anything -----------------
call :require QEMU      || exit /b 1
call :require FIRMWARE  || exit /b 1
call :require DISK      || exit /b 1
call :require VNCVIEWER || exit /b 1

rem --- Build the QEMU command line -------------------------------------------
rem Guest basics
set "ARGS=-name "%VM_NAME%" -m %RAM% -smp %SMP% -accel %ACCEL%"
set "ARGS=%ARGS% -drive "if=pflash,format=raw,readonly=on,file=%FIRMWARE%""
set "ARGS=%ARGS% -drive "file=%DISK%,format=%DISK_FORMAT%,if=%DISK_IF%""

rem Display: no local window, VNC on localhost only (no password needed)
set "ARGS=%ARGS% -device virtio-vga,xres=%XRES%,yres=%YRES%"
set "ARGS=%ARGS% -display none -vnc 127.0.0.1:%VNC_DISPLAY%"

rem Absolute pointer, so the cursor moves freely in and out of the viewer
set "ARGS=%ARGS% -device qemu-xhci -device usb-tablet"

rem Clipboard + mouse agent channel (talks to spice-vdagent in the guest)
set "ARGS=%ARGS% -device virtio-serial-pci"
set "ARGS=%ARGS% -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on,mouse=on"
set "ARGS=%ARGS% -device virtserialport,chardev=vdagent,name=com.redhat.spice.0"

rem Optional extras
if defined SSH_PORT   set "ARGS=%ARGS% -nic user,model=e1000,hostfwd=tcp:127.0.0.1:%SSH_PORT%-:22"
if defined EXTRA_ARGS set "ARGS=%ARGS% %EXTRA_ARGS%"

rem --- Start QEMU ------------------------------------------------------------
rem The cmd /c wrapper keeps the window open with QEMU's error message if
rem QEMU exits with an error. On a normal shutdown the window just closes.
start "%VM_NAME% (QEMU)" /min cmd /c ""%QEMU%" %ARGS% || pause"

rem --- Wait up to 30 s for the VNC server ------------------------------------
set /a tries=0
:wait
call :port_open && goto viewer
set /a tries+=1
if %tries% geq 30 goto timed_out
timeout /t 1 /nobreak >nul
goto wait

:timed_out
echo [ERROR] QEMU did not open VNC port %VNC_PORT% within 30 seconds.
echo         Restore the minimized "%VM_NAME% (QEMU)" window to see QEMU's error.
pause
exit /b 1

:viewer
start "" "%VNCVIEWER%" %VIEWER_ARGS% localhost::%VNC_PORT%
exit /b 0

rem ===========================================================================
rem  Subroutines
rem ===========================================================================

:port_open
rem Exit code 0 if something is listening on the VNC port.
powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort %VNC_PORT% -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
exit /b %errorlevel%

:require
rem Usage: call :require VARNAME  -  fails if the path in VARNAME is missing.
call set "REQ_PATH=%%%~1%%"
if not defined REQ_PATH goto require_unset
if exist "%REQ_PATH%" exit /b 0
echo [ERROR] %~1 not found: "%REQ_PATH%"
echo         Fix the path in "%HERE%config.cmd"
pause
exit /b 1

:require_unset
echo [ERROR] %~1 is not set in "%HERE%config.cmd"
pause
exit /b 1
