<#
.SYNOPSIS
    Checks the Windows host before the first start of the VM.

.DESCRIPTION
    Reads config.cmd (or config.example.cmd) and verifies everything
    start-arch.bat relies on: paths, QEMU features (qemu-vdagent, WHPX),
    the Windows Hypervisor Platform, disk format, RAM/CPU sizing and the
    VNC port. It changes nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\check-setup.ps1
#>
[CmdletBinding()]
param(
    [string]$Config
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Warnings = 0

function Write-Ok   ([string]$Msg) { Write-Host "  [ OK ] $Msg" -ForegroundColor Green }
function Write-Warn ([string]$Msg) { Write-Host "  [WARN] $Msg" -ForegroundColor Yellow; $script:Warnings++ }
function Write-Fail ([string]$Msg) { Write-Host "  [FAIL] $Msg" -ForegroundColor Red; $script:Failures++ }
function Write-Info ([string]$Msg) { Write-Host "         $Msg" -ForegroundColor DarkGray }
function Write-Section ([string]$Title) { Write-Host ""; Write-Host $Title -ForegroundColor Cyan }

function Read-CmdConfig {
    <# Parses  set "NAME=value"  lines and expands %NAME% references,
       the same way cmd would for a file that only contains set lines. #>
    param([Parameter(Mandatory)][string]$Path)

    $vars = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*set\s+"([A-Za-z_][A-Za-z0-9_]*)=(.*)"\s*$' -or
            $line -match '^\s*set\s+([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$') {
            $name  = $Matches[1].ToUpperInvariant()
            $value = [regex]::Replace($Matches[2], '%([A-Za-z_][A-Za-z0-9_]*)%', {
                param($m)
                $ref = $m.Groups[1].Value.ToUpperInvariant()
                if ($vars.ContainsKey($ref)) { return $vars[$ref] }
                $envValue = [Environment]::GetEnvironmentVariable($ref)
                if ($null -ne $envValue) { return $envValue }
                return ''
            })
            $vars[$name] = $value
        }
    }
    return $vars
}

function ConvertTo-MiB ([string]$Size) {
    # QEMU -m syntax: plain number = MiB, or a K/M/G/T suffix.
    if ($Size -notmatch '^\s*(\d+(?:\.\d+)?)\s*([KMGT]?)i?B?\s*$') { return $null }
    $n = [double]$Matches[1]
    switch ($Matches[2].ToUpperInvariant()) {
        'K'     { return $n / 1024 }
        'G'     { return $n * 1024 }
        'T'     { return $n * 1024 * 1024 }
        default { return $n }
    }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# --- Config ------------------------------------------------------------------
Write-Section 'Config'
if (-not $Config) {
    $local = Join-Path $PSScriptRoot 'config.cmd'
    $example = Join-Path $PSScriptRoot 'config.example.cmd'
    if (Test-Path -LiteralPath $local) {
        $Config = $local
    } else {
        $Config = $example
        Write-Warn "config.cmd not found - checking config.example.cmd instead."
        Write-Info "start-arch.bat needs config.cmd: copy config.example.cmd and edit it."
    }
}
if (-not (Test-Path -LiteralPath $Config)) {
    Write-Fail "Config file not found: $Config"
    exit 1
}
$cfg = Read-CmdConfig -Path $Config
Write-Ok "Using $Config"

function Get-Cfg ([string]$Name, [string]$Default = '') {
    if ($cfg.ContainsKey($Name) -and $cfg[$Name] -ne '') { return $cfg[$Name] }
    return $Default
}

$qemu      = Get-Cfg 'QEMU'
$firmware  = Get-Cfg 'FIRMWARE'
$disk      = Get-Cfg 'DISK'
$diskFmt   = Get-Cfg 'DISK_FORMAT' 'qcow2'
$diskIf    = Get-Cfg 'DISK_IF' 'ide'
$viewer    = Get-Cfg 'VNCVIEWER'
$ram       = Get-Cfg 'RAM' '4G'
$smp       = Get-Cfg 'SMP' '2'
$accel     = Get-Cfg 'ACCEL' 'whpx'
$vncDisp   = [int](Get-Cfg 'VNC_DISPLAY' '0')
$vncPort   = 5900 + $vncDisp
$sshPort   = Get-Cfg 'SSH_PORT'

# --- Files -------------------------------------------------------------------
Write-Section 'Files'
foreach ($item in @(
        @{ Name = 'QEMU';      Path = $qemu },
        @{ Name = 'FIRMWARE';  Path = $firmware },
        @{ Name = 'DISK';      Path = $disk },
        @{ Name = 'VNCVIEWER'; Path = $viewer })) {
    if (-not $item.Path) {
        Write-Fail "$($item.Name) is not set"
    } elseif (Test-Path -LiteralPath $item.Path -PathType Leaf) {
        Write-Ok "$($item.Name): $($item.Path)"
    } else {
        Write-Fail "$($item.Name) not found: $($item.Path)"
        if ($item.Name -eq 'FIRMWARE' -and $qemu) {
            # Recent QEMU for Windows builds keep it in share\qemu, older ones in share.
            $qemuDir = Split-Path -Parent $qemu
            $source = @('share\qemu\edk2-x86_64-code.fd', 'share\edk2-x86_64-code.fd') |
                ForEach-Object { Join-Path $qemuDir $_ } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($source) {
                Write-Info "Copy it from your QEMU install:"
                Write-Info "  copy `"$source`" `"$($item.Path)`""
            } else {
                Write-Info "edk2-x86_64-code.fd was not found under $qemuDir\share"
            }
        }
    }
}

# --- QEMU features -----------------------------------------------------------
Write-Section 'QEMU'
$qemuOk = $qemu -and (Test-Path -LiteralPath $qemu -PathType Leaf)
if ($qemuOk) {
    $version = (& $qemu --version 2>&1 | Select-Object -First 1)
    Write-Ok "$version"

    $chardevs = (& $qemu -chardev help 2>&1) -join "`n"
    if ($chardevs -match 'qemu-vdagent') {
        Write-Ok 'qemu-vdagent chardev available (clipboard sharing)'
    } else {
        Write-Fail 'qemu-vdagent chardev missing - clipboard sharing needs QEMU 6.1 or newer'
    }

    $accelName = ($accel -split ',')[0]
    $accels = (& $qemu -accel help 2>&1) -join "`n"
    if ($accels -match "(?m)^\s*$([regex]::Escape($accelName))\s*$") {
        Write-Ok "Accelerator '$accelName' is built into this QEMU"
    } else {
        Write-Fail "Accelerator '$accelName' is not available in this QEMU build"
    }

    $qemuImg = Join-Path (Split-Path -Parent $qemu) 'qemu-img.exe'
    if ($disk -and (Test-Path -LiteralPath $disk) -and (Test-Path -LiteralPath $qemuImg)) {
        $info = (& $qemuImg info --force-share $disk 2>&1) -join "`n"
        if ($info -match '(?m)^file format:\s*(\S+)') {
            $actual = $Matches[1]
            if ($actual -eq $diskFmt) {
                Write-Ok "Disk format is $actual"
            } else {
                Write-Fail "Disk is '$actual' but DISK_FORMAT is '$diskFmt'"
            }
        } else {
            Write-Warn 'Could not read the disk format with qemu-img'
        }
    }
} else {
    Write-Info 'Skipped (QEMU not found).'
}

# --- Hypervisor --------------------------------------------------------------
if ($accel -like 'whpx*') {
    Write-Section 'Windows Hypervisor Platform'
    if (Test-IsAdmin) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
        if ($feature.State -eq 'Enabled') {
            Write-Ok 'HypervisorPlatform feature is enabled'
        } else {
            Write-Fail "HypervisorPlatform feature is $($feature.State)"
            Write-Info 'Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform  (then reboot)'
        }
    } else {
        $present = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
        if ($present) {
            Write-Ok 'A hypervisor is running (run as admin to check the feature itself)'
        } else {
            Write-Fail 'No hypervisor running - enable "Windows Hypervisor Platform" and reboot'
        }
    }
}

# --- Sizing ------------------------------------------------------------------
Write-Section 'Sizing'
$hostMiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$vmMiB = ConvertTo-MiB $ram
if ($null -eq $vmMiB) {
    Write-Warn "Could not parse RAM='$ram'"
} elseif ($vmMiB -gt $hostMiB * 0.75) {
    Write-Warn ("RAM={0} is more than 75% of the host's {1:N1} GiB - Windows will start paging" -f $ram, ($hostMiB / 1024))
} else {
    Write-Ok ("RAM={0} of {1:N1} GiB host memory" -f $ram, ($hostMiB / 1024))
}

$hostThreads = [Environment]::ProcessorCount
$vcpus = [int](($smp -split ',')[0])
if ($vcpus -gt $hostThreads) {
    Write-Fail "SMP=$vcpus is more than the host's $hostThreads logical processors"
} elseif ($vcpus -gt [math]::Floor($hostThreads * 0.75)) {
    Write-Warn "SMP=$vcpus of $hostThreads logical processors leaves little for Windows"
} else {
    Write-Ok "SMP=$vcpus of $hostThreads logical processors"
}

# --- Ports -------------------------------------------------------------------
Write-Section 'Ports'
$vncListener = Get-NetTCPConnection -LocalPort $vncPort -State Listen -ErrorAction SilentlyContinue
if ($vncListener) {
    $owner = (Get-Process -Id ($vncListener | Select-Object -First 1).OwningProcess -ErrorAction SilentlyContinue).ProcessName
    if ($owner -like 'qemu-system*') {
        Write-Ok "VNC port $vncPort is in use by QEMU (VM is running)"
    } else {
        Write-Fail "VNC port $vncPort is in use by '$owner' - change VNC_DISPLAY"
    }
} else {
    Write-Ok "VNC port $vncPort is free"
}

if ($sshPort) {
    $sshListener = Get-NetTCPConnection -LocalPort ([int]$sshPort) -State Listen -ErrorAction SilentlyContinue
    if ($sshListener) {
        $owner = (Get-Process -Id ($sshListener | Select-Object -First 1).OwningProcess -ErrorAction SilentlyContinue).ProcessName
        if ($owner -like 'qemu-system*') {
            Write-Ok "SSH port $sshPort is forwarded by QEMU (VM is running)"
        } else {
            Write-Fail "SSH port $sshPort is in use by '$owner' - pick another SSH_PORT"
        }
    } else {
        Write-Ok "SSH port $sshPort is free"
    }
}

if ($diskIf -eq 'virtio') {
    Write-Info 'DISK_IF=virtio: the guest initramfs must contain virtio_blk (guest/setup.sh --virtio-disk).'
}

# --- Summary -----------------------------------------------------------------
Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) problem(s), $($script:Warnings) warning(s). Fix the [FAIL] items before starting the VM." -ForegroundColor Red
    exit 1
}
Write-Host "No problems found ($($script:Warnings) warning(s)). Run start-arch.bat." -ForegroundColor Green
exit 0
