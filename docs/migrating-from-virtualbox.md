# Migrating an existing VirtualBox VM

You can keep your existing Arch install. Only the disk format and the guest
tools change.

## 1. Convert the disk

Shut the VM down in VirtualBox first (a real shutdown, not a saved state). Then,
in a Windows terminal:

```bat
"C:\Program Files\qemu\qemu-img.exe" convert -p -O qcow2 E:\VirtualBox\Arch.vdi E:\VirtualBox\Arch.qcow2
```

The `.vdi` stays untouched, so you can go back to VirtualBox at any time. Point
`DISK` in `windows\config.cmd` at the new `.qcow2`.

## 2. UEFI firmware

If the VM booted with EFI in VirtualBox, QEMU needs UEFI firmware too. QEMU for
Windows ships one. Copy it next to your disk image:

```bat
copy "C:\Program Files\qemu\share\qemu\edk2-x86_64-code.fd" "E:\VirtualBox\bios.fd"
```

and set `FIRMWARE` to the copy (`E:\VirtualBox\bios.fd` here). The copy pins the
firmware version: a QEMU update can replace the file in `Program Files`, but
your VM keeps booting the firmware it was installed with. (Older QEMU builds
keep the file directly in `share\` instead of `share\qemu\`;
`check-setup.ps1` finds either and prints the right command.) The launcher opens it
**read-only** and without a separate variables file, so UEFI boot entries are
not saved between boots. The firmware then boots the fallback path
`\EFI\BOOT\BOOTX64.EFI` on the EFI partition. Most Arch installs that used
VirtualBox EFI already have it. If yours does not, boot once with a working
setup and copy your bootloader there, for example for systemd-boot:

```bash
sudo bootctl install          # also installs the fallback BOOTX64.EFI
```

or for GRUB:

```bash
sudo grub-install --target=x86_64-efi --efi-directory=/boot --removable
```

(Adjust `--efi-directory` to where your EFI partition is mounted.)

## 3. Swap the guest tools

Boot the converted disk with `windows\start-arch.bat`, then inside the guest:

```bash
git clone https://github.com/grunundweiss/qemu-arch-on-windows.git
cd qemu-arch-on-windows
bash guest/setup.sh --remove-vbox
```

This installs `spice-vdagent` (clipboard and mouse for QEMU) and removes the
VirtualBox Guest Additions, which otherwise show
`VBoxClient: the VirtualBox kernel service is not running` at every login.

## 4. Optional: faster disk

```bash
bash guest/setup.sh --virtio-disk
```

Shut down, set `DISK_IF=virtio` in `config.cmd`, start again.

## VirtualBox and WHPX on the same machine

QEMU's WHPX accelerator needs the *Windows Hypervisor Platform* feature. While
it is enabled, VirtualBox has to run on top of Hyper-V (green turtle icon),
which is noticeably slower. For full-speed VirtualBox you would have to disable
the feature again, which drops QEMU back to slow TCG. In practice you pick
one or the other.
