# Troubleshooting

Every entry here was hit while building this setup. Each one lists the symptom,
the actual cause, and the fix.

- [Clipboard does not sync in the QEMU GTK window](#clipboard-does-not-sync-in-the-qemu-gtk-window)
- [Clipboard does not sync over VNC either](#clipboard-does-not-sync-over-vnc-either)
- [`spice-vdagentd: An agent is already connected for this session`](#spice-vdagentd-an-agent-is-already-connected-for-this-session)
- [Boot hangs at "Starting Switch Root..."](#boot-hangs-at-starting-switch-root)
- [The VM is extremely slow](#the-vm-is-extremely-slow)
- [Mouse cursor disappears after visiting another monitor](#mouse-cursor-disappears-after-visiting-another-monitor)
- [`VBoxClient: the VirtualBox kernel service is not running`](#vboxclient-the-virtualbox-kernel-service-is-not-running)
- [RealVNC Viewer asks for an account](#realvnc-viewer-asks-for-an-account)
- [The launcher says QEMU did not start](#the-launcher-says-qemu-did-not-start)
- [Guest does not boot after switching `DISK_IF` to virtio](#guest-does-not-boot-after-switching-disk_if-to-virtio)
- [`setup.sh` fails with `$'\r': command not found`](#setupsh-fails-with-r-command-not-found)

---

## Clipboard does not sync in the QEMU GTK window

**Symptom:** `-display gtk` with `qemu-vdagent,clipboard=on` and `spice-vdagent`
running in the guest, and still no copy and paste in either direction.

**Cause:** QEMU's GTK clipboard code is a build-time option
(`--enable-gtk-clipboard`) that has been **disabled by default since late 2022**,
because it could hang the guest
([QEMU issue #1150](https://gitlab.com/qemu-project/qemu/-/issues/1150)).
Prebuilt Windows binaries do not include it, so no command-line flag can turn it
on.

**Fix:** use QEMU's VNC server instead. Its clipboard support is not behind
that option. That is why `start-arch.bat` runs QEMU headless with
`-display none -vnc 127.0.0.1:0` and opens TigerVNC.

## Clipboard does not sync over VNC either

Work through these in order inside the guest:

1. `ls /dev/virtio-ports/` must show `com.redhat.spice.0`. If not, the VM was
   not started with the vdagent devices. Use `start-arch.bat`.
2. `echo $XDG_SESSION_TYPE` must say `x11`. On Wayland, spice-vdagent's
   clipboard sync mostly does not work. Pick the X11 session at the login screen.
3. `pgrep -a spice-vdagent` must show **two** processes: `spice-vdagentd` (system
   daemon) and `spice-vdagent` (runs in your desktop session). If the session
   agent is missing, log out and back in. On bare window managers, add
   `spice-vdagent &` to your startup file.
4. Copy with Ctrl+C, not mouse selection. Only the regular clipboard is synced,
   not the X11 middle-click selection.
5. The viewer must support the extended clipboard. TigerVNC does.

`guest/setup.sh` checks points 1 to 3 for you.

## `spice-vdagentd: An agent is already connected for this session`

**Cause:** you started `spice-vdagent` by hand (for example `spice-vdagent -x -d`
for debugging) while your desktop had already started one. The daemon accepts
one agent per session.

**Fix:** nothing to fix. The autostarted agent is the one doing the work. The
`failed to call GetCurrentState from mutter` message in the same debug output is
also harmless. The agent tries GNOME's API first and falls back to X11 on other
desktops.

## Boot hangs at "Starting Switch Root..."

**Symptom:** with `ACCEL=whpx`, the boot stops right after
`Reached target Switch Root`.

**Cause:** the WHPX accelerator (Windows Hypervisor Platform) is still marked
experimental in QEMU, and some host/guest combinations hang in early boot. The
most common culprit is the in-hypervisor interrupt controller.

**Fix:**

1. Set `ACCEL=whpx,kernel-irqchip=off` in `config.cmd`. This makes QEMU emulate
   the interrupt controller itself (slightly slower, but avoids the bug).
2. If it still hangs, try `ACCEL=tcg` once to confirm that WHPX is the cause.
   If TCG boots, WHPX is the problem. If TCG hangs too, look at the guest.
3. Change one thing at a time, so you know which change fixed it.

`kernel-irqchip` defaults to `on` with WHPX. QEMU falls back automatically only
if the hypervisor reports no support, not if the support is buggy.

## The VM is extremely slow

**Cause:** `ACCEL=tcg` translates every guest instruction in software. No QEMU
setting makes that fast.

**Fix:** enable hardware acceleration (WHPX):

```powershell
# PowerShell as administrator
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform   # then reboot
```

Then set `ACCEL=whpx`. For faster disk I/O, also run `guest/setup.sh --virtio-disk`
and switch `DISK_IF=virtio`.

## Mouse cursor disappears after visiting another monitor

**Cause:** with only the emulated PS/2 mouse, the guest receives relative
movement. QEMU then has to capture the pointer, and the guest and host cursors
drift apart when you move to another monitor and back.

**Fix:** already in the launcher. `-device qemu-xhci -device usb-tablet` gives
the guest an absolute pointer from the boot screen onwards, and
`qemu-vdagent,...,mouse=on` lets the agent report exact positions once you are
logged in. With TigerVNC the pointer is never captured at all. (In QEMU's own
GTK window, Ctrl+Alt+G releases a captured pointer.)

## `VBoxClient: the VirtualBox kernel service is not running`

**Cause:** the disk was converted from VirtualBox, and the VirtualBox Guest
Additions are still installed. At login, `VBoxClient` looks for VirtualBox, does
not find it, and exits with this popup. It is harmless but annoying.

The Guest Additions can come from three places, and only the first is a pacman
package:

| Source | How to remove it |
|---|---|
| `virtualbox-guest-utils(-nox)` package | `sudo pacman -Rns virtualbox-guest-utils` |
| VirtualBox ISO (`VBoxLinuxAdditions.run`) | `sudo /opt/VBoxGuestAdditions-*/uninstall.sh` |
| XFCE saved session (`~/.cache/sessions`) | delete or rename the session file, then turn off *Automatically save session on logout* |

**Fix:** `guest/setup.sh --remove-vbox` checks all three, removes what it finds,
and cleans up dangling `vbox*` service links. If you still want to boot the
same disk in VirtualBox sometimes, keep the package and gate the autostart
instead:

```ini
# ~/.config/autostart/vboxclient.desktop  (same name as the system entry overrides it)
[Desktop Entry]
Type=Application
Name=VirtualBox User Services
Exec=sh -c '[ "$(systemd-detect-virt)" = oracle ] && exec VBoxClient-all'
```

## RealVNC Viewer asks for an account

QEMU's VNC server needs no account. That prompt is RealVNC's own sign-up.
Use [TigerVNC](https://sourceforge.net/projects/tigervnc/files/stable/): the
standalone `vncviewer64-<version>.exe` needs no installer and no account, and it
supports the extended clipboard.

## The launcher says QEMU did not start

QEMU's console window is started minimized. If QEMU exits with an error, that
window stays open with the error message and waits for a key press. Restore the
`<VM_NAME> (QEMU)` window from the taskbar to read it. Common causes:

- `WHPX: No accelerator found`: Windows Hypervisor Platform is not enabled
  (see above).
- `Could not open '...qcow2'`: wrong `DISK` path, or the disk is in use by
  another QEMU or VirtualBox.
- `Failed to find an available port`: something else is using the VNC port.
  Change `VNC_DISPLAY`.

Run `windows\check-setup.ps1` to catch most of these before starting.

## Guest does not boot after switching `DISK_IF` to virtio

**Cause:** the initramfs does not contain the virtio disk driver, or the boot
config refers to the disk as `/dev/sdX` (a virtio disk is `/dev/vdX`).

**Fix:** set `DISK_IF=ide` again, boot, run `guest/setup.sh --virtio-disk` (it
adds `virtio_blk virtio_pci` to `MODULES` and warns about `/dev/sdX` entries in
`/etc/fstab` and the kernel command line), then switch back to virtio.

## `setup.sh` fails with `$'\r': command not found`

**Cause:** the script got Windows line endings (CRLF), for example by copying it
through a Windows editor.

**Fix:** clone the repo inside the guest instead, or convert the file:
`sed -i 's/\r$//' guest/setup.sh`. The repo's `.gitattributes` keeps `*.sh` files
LF-only on every checkout.
