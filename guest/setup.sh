#!/usr/bin/env bash
# Guest-side setup for an Arch Linux VM running under QEMU on a Windows host.
#
# Default: installs and enables spice-vdagent (clipboard + mouse) and checks
# that the guest can actually use it. Optional steps are behind flags.
#
# Run it as your normal user from inside your desktop session (it uses sudo
# where needed, and some checks look at your session and autostart files).

set -euo pipefail

REMOVE_VBOX=0
VIRTIO_DISK=0
ENABLE_SSH=0

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Always:
  Installs spice-vdagent, enables spice-vdagentd and checks the clipboard
  channel, the session type and the agent autostart.

Options:
  --remove-vbox   Remove VirtualBox Guest Additions left over from a disk that
                  was converted from VirtualBox (fixes "VBoxClient: the
                  VirtualBox kernel service is not running" popups).
  --virtio-disk   Add virtio_blk/virtio_pci to the initramfs, so you can switch
                  DISK_IF to virtio in config.cmd (much faster disk I/O).
  --ssh           Install and enable OpenSSH (pair with SSH_PORT in config.cmd).
  -h, --help      Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --remove-vbox) REMOVE_VBOX=1 ;;
        --virtio-disk) VIRTIO_DISK=1 ;;
        --ssh)         ENABLE_SSH=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_HEAD=$'\e[36m' C_OFF=$'\e[0m'
else
    C_OK='' C_WARN='' C_ERR='' C_HEAD='' C_OFF=''
fi

WARNINGS=0
step() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$*" "$C_OFF"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*"; WARNINGS=$((WARNINGS + 1)); }
info() { printf '         %s\n' "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not root. It calls sudo itself."
command -v pacman >/dev/null || die "pacman not found - this script is for Arch Linux."
command -v sudo   >/dev/null || die "sudo not found - install it and add yourself to the wheel group."

# ---------------------------------------------------------------------------
step "Clipboard and mouse agent (spice-vdagent)"

sudo pacman -S --needed --noconfirm spice-vdagent
sudo systemctl enable --now spice-vdagentd.service
ok "spice-vdagent installed, spice-vdagentd enabled"

if [[ -e /dev/virtio-ports/com.redhat.spice.0 ]]; then
    ok "QEMU agent channel present (/dev/virtio-ports/com.redhat.spice.0)"
else
    warn "QEMU agent channel /dev/virtio-ports/com.redhat.spice.0 is missing."
    info "The VM was started without the vdagent devices. Start it with"
    info "windows/start-arch.bat, which adds virtio-serial-pci + qemu-vdagent."
fi

case "${XDG_SESSION_TYPE:-}" in
    x11)
        ok "Running in an X11 session" ;;
    wayland)
        warn "Running in a Wayland session - spice-vdagent's clipboard sync"
        info "mostly does not work there. Pick the X11 session at the login screen." ;;
    *)
        warn "Not inside a graphical session (XDG_SESSION_TYPE='${XDG_SESSION_TYPE:-}')."
        info "The agent needs a desktop session. Run this from a terminal in your desktop"
        info "to get a meaningful result for this check." ;;
esac

if [[ -f /etc/xdg/autostart/spice-vdagent.desktop ]]; then
    ok "spice-vdagent autostarts with XDG desktops (XFCE, KDE, GNOME, ...)"
else
    warn "/etc/xdg/autostart/spice-vdagent.desktop not found."
    info "If you use a bare window manager (i3, bspwm, ...), add 'spice-vdagent &'"
    info "to its startup file or ~/.xinitrc."
fi

if pgrep -x spice-vdagent >/dev/null; then
    ok "spice-vdagent is running in this session"
else
    info "spice-vdagent is not running yet - log out and back in, then check with:"
    info "  pgrep -a spice-vdagent   (expect spice-vdagentd AND spice-vdagent)"
fi

# ---------------------------------------------------------------------------
if (( REMOVE_VBOX )); then
    step "Removing VirtualBox Guest Additions leftovers"

    mapfile -t vbox_pkgs < <(pacman -Qq | grep -E '^virtualbox-guest' || true)
    if (( ${#vbox_pkgs[@]} )); then
        info "Removing packages: ${vbox_pkgs[*]}"
        sudo pacman -Rns "${vbox_pkgs[@]}"
        ok "Packages removed"
    else
        ok "No virtualbox-guest packages installed"
    fi

    shopt -s nullglob
    vbox_uninstallers=(/opt/VBoxGuestAdditions-*/uninstall.sh)
    shopt -u nullglob
    if (( ${#vbox_uninstallers[@]} )); then
        for u in "${vbox_uninstallers[@]}"; do
            info "Running $u (Guest Additions installed from the VirtualBox ISO)"
            sudo "$u"
        done
        ok "ISO-installed Guest Additions removed"
    else
        ok "No ISO-installed Guest Additions in /opt"
    fi

    # Enable links left behind after the unit files were removed.
    mapfile -t dangling < <(sudo find /etc/systemd/system -xtype l -iname '*vbox*' 2>/dev/null || true)
    if (( ${#dangling[@]} )); then
        sudo rm -f -- "${dangling[@]}"
        sudo systemctl daemon-reload
        ok "Removed ${#dangling[@]} dangling VirtualBox service link(s)"
    fi

    # Autostart entries: disabled by renaming (*.desktop -> *.desktop.disabled), not deleted.
    mapfile -t autostarts < <(grep -rlis vboxclient /etc/xdg/autostart "$HOME/.config/autostart" 2>/dev/null || true)
    for f in "${autostarts[@]}"; do
        [[ $f == *.desktop ]] || continue
        if pacman -Qoq "$f" >/dev/null 2>&1; then
            warn "$f belongs to package $(pacman -Qoq "$f") - remove that package instead."
            continue
        fi
        if [[ $f == "$HOME"/* ]]; then
            mv -- "$f" "$f.disabled"
        else
            sudo mv -- "$f" "$f.disabled"
        fi
        ok "Disabled autostart entry $f"
    done

    # XFCE "save session on logout" can keep relaunching VBoxClient.
    mapfile -t sessions < <(grep -lis vboxclient "$HOME"/.cache/sessions/* 2>/dev/null || true)
    for f in "${sessions[@]}"; do
        mv -- "$f" "$f.bak"
        ok "Moved saved desktop session $f to $f.bak"
    done
    if (( ${#sessions[@]} )); then
        info "Turn off Settings > Session and Startup > General > 'Automatically save"
        info "session on logout', or XFCE may save VBoxClient into the session again."
    fi

    if command -v VBoxClient >/dev/null; then
        warn "VBoxClient still exists at $(command -v VBoxClient)."
        info "Owner: $(pacman -Qo "$(command -v VBoxClient)" 2>/dev/null || echo 'no package (manual install)')"
    else
        ok "VBoxClient is gone"
    fi
    info "Log out and back in to get rid of the popups."
fi

# ---------------------------------------------------------------------------
if (( VIRTIO_DISK )); then
    step "Preparing the initramfs for a virtio disk"

    conf=/etc/mkinitcpio.conf
    [[ -f $conf ]] || die "$conf not found."

    # A virtio disk is /dev/vda, not /dev/sda. Device-name based boot config breaks.
    if grep -Eq '^[[:space:]]*/dev/sd' /etc/fstab; then
        warn "/etc/fstab mounts by /dev/sdX name. With virtio the disk becomes /dev/vdX."
        info "Switch those entries to UUID= (see 'lsblk -f') before changing DISK_IF."
    fi
    if grep -Eq 'root=/dev/sd' /proc/cmdline; then
        warn "The kernel command line uses root=/dev/sdX. Change your bootloader entry"
        info "to root=UUID=... before changing DISK_IF."
    fi

    if grep -Eq '^MODULES=\(.*\bvirtio_blk\b' "$conf"; then
        ok "virtio_blk is already in MODULES"
    else
        backup="$conf.bak.$(date +%Y%m%d-%H%M%S)"
        sudo cp -- "$conf" "$backup"
        sudo sed -i -E 's/^MODULES=\(/MODULES=(virtio_blk virtio_pci /' "$conf"
        grep -Eq '^MODULES=\(.*\bvirtio_blk\b' "$conf" \
            || die "Could not add virtio_blk to MODULES in $conf (backup: $backup)."
        ok "Added virtio_blk virtio_pci to MODULES (backup: $backup)"
    fi

    sudo mkinitcpio -P
    ok "Initramfs rebuilt"
    info "Now shut down the VM, set DISK_IF=virtio in windows\\config.cmd and start it again."
fi

# ---------------------------------------------------------------------------
if (( ENABLE_SSH )); then
    step "OpenSSH server"
    sudo pacman -S --needed --noconfirm openssh
    sudo systemctl enable --now sshd.service
    ok "sshd enabled"
    info "Set SSH_PORT=2222 in windows\\config.cmd, restart the VM, then from Windows:"
    info "  ssh -p 2222 $USER@localhost"
fi

# ---------------------------------------------------------------------------
printf '\n'
if (( WARNINGS )); then
    printf '%sDone with %d warning(s) - see above.%s\n' "$C_WARN" "$WARNINGS" "$C_OFF"
else
    printf '%sDone.%s\n' "$C_OK" "$C_OFF"
fi
