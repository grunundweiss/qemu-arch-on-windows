@echo off
rem ===========================================================================
rem  VM configuration for start-arch.bat and check-setup.ps1
rem
rem  Copy this file to config.cmd (same folder) and edit the values.
rem  config.cmd is git-ignored, so your local paths never end up on GitHub.
rem
rem  Keep this file to plain  set "NAME=value"  lines and rem comments:
rem  check-setup.ps1 parses it without running cmd.
rem ===========================================================================

rem --- Paths -----------------------------------------------------------------
set "QEMU_DIR=C:\Program Files\qemu"
set "QEMU=%QEMU_DIR%\qemu-system-x86_64.exe"

rem UEFI firmware. Copy it out of the QEMU install once, next to your disk,
rem so a QEMU update cannot swap the firmware under an installed guest:
rem   copy "C:\Program Files\qemu\share\qemu\edk2-x86_64-code.fd" "C:\VMs\bios.fd"
rem It is opened read-only, so the guest must boot from the fallback path
rem \EFI\BOOT\BOOTX64.EFI (see docs\migrating-from-virtualbox.md).
set "FIRMWARE=C:\VMs\bios.fd"

rem The guest disk image.
set "DISK=C:\VMs\Arch.qcow2"
set "DISK_FORMAT=qcow2"

rem ide    = works with any Arch install (same as QEMU's -hda).
rem virtio = much faster disk I/O, but run  guest/setup.sh --virtio-disk  first,
rem          or the guest will not find its root disk.
set "DISK_IF=ide"

rem TigerVNC viewer (standalone vncviewer64-x.y.z.exe, no account needed).
set "VNCVIEWER=C:\Tools\vncviewer64.exe"
rem Extra options for the viewer, e.g. -FullScreen. Leave empty for none.
set "VIEWER_ARGS="

rem --- Hardware --------------------------------------------------------------
set "VM_NAME=Arch"

rem RAM for the guest. Keep it at or below half of the host's RAM.
set "RAM=8G"

rem vCPUs. Up to half of the host's logical processors is a good default.
rem Example for an 8-core/16-thread CPU:
rem   set "SMP=8,sockets=1,cores=4,threads=2"
set "SMP=4"

rem whpx                     = Windows Hypervisor Platform (fast, needs the
rem                            "Windows Hypervisor Platform" feature enabled)
rem whpx,kernel-irqchip=off  = use this if the guest hangs at "Switch Root"
rem tcg                      = pure software emulation (works everywhere, slow)
set "ACCEL=whpx"

rem Guest screen resolution.
set "XRES=1920"
set "YRES=1080"

rem --- Access ----------------------------------------------------------------
rem VNC display number. The VNC port is 5900 + VNC_DISPLAY.
set "VNC_DISPLAY=0"

rem Forward this host port to the guest's SSH port 22 (127.0.0.1 only).
rem Empty = no forwarding. Needs  guest/setup.sh --ssh  in the guest.
set "SSH_PORT="

rem Anything else you want to pass to QEMU. Leave empty for none.
set "EXTRA_ARGS="
