#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates an Ubuntu Hyper-V VM for OpenClaw.
.DESCRIPTION
    Automates Hyper-V VM creation (Steps 1-2 from the setup guide).
    Run this script as Administrator on the Windows host.
.NOTES
    After the VM boots, run setup_openclaw.sh inside Ubuntu to complete setup.
#>

# ── Configuration ──────────────────────────────────────────────────────────────
$VMName        = "OpenClaw-Ubuntu"
$SwitchName    = "Default Switch"        # Change if you use a custom vSwitch
$ISOPath       = ""                      # <-- SET THIS: path to Ubuntu Server ISO
$VHDPath       = "C:\Hyper-V\VMs\$VMName\$VMName.vhdx"
$RAM           = 4GB
$CPUs          = 2
$DiskSize      = 80GB
# ───────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Err  { param([string]$msg) Write-Host "   [ERROR] $msg" -ForegroundColor Red }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
Write-Step "Pre-flight checks"

if (-not (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq "Enabled") {
    Write-Err "Hyper-V is not enabled. Enable it first:"
    Write-Host "   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
    exit 1
}
Write-OK "Hyper-V is enabled"

if ([string]::IsNullOrWhiteSpace($ISOPath) -or -not (Test-Path $ISOPath)) {
    Write-Err "Set `$ISOPath at the top of this script to a valid Ubuntu Server ISO."
    Write-Host "   Download from: https://ubuntu.com/download/server"
    exit 1
}
Write-OK "ISO found: $ISOPath"

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Err "Virtual switch '$SwitchName' not found."
    Write-Host "   Available switches:"
    Get-VMSwitch | ForEach-Object { Write-Host "     - $($_.Name)" }
    exit 1
}
Write-OK "Virtual switch: $SwitchName"

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Err "VM '$VMName' already exists. Remove it first or change `$VMName."
    exit 1
}

# ── Create VHD directory ──────────────────────────────────────────────────────
Write-Step "Creating VHD directory"
$VHDDir = Split-Path $VHDPath
if (-not (Test-Path $VHDDir)) {
    New-Item -Path $VHDDir -ItemType Directory -Force | Out-Null
}
Write-OK $VHDDir

# ── Create VM ─────────────────────────────────────────────────────────────────
Write-Step "Creating Generation 2 VM: $VMName"
New-VM -Name $VMName `
       -MemoryStartupBytes $RAM `
       -Generation 2 `
       -NewVHDPath $VHDPath `
       -NewVHDSizeBytes $DiskSize `
       -SwitchName $SwitchName | Out-Null
Write-OK "VM created"

# ── Configure VM ──────────────────────────────────────────────────────────────
Write-Step "Configuring VM"

Set-VM -Name $VMName -ProcessorCount $CPUs -CheckpointType Disabled
Write-OK "CPUs: $CPUs"

# Disable Secure Boot (Ubuntu ISO may fail otherwise)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Write-OK "Secure Boot disabled"

# Attach Ubuntu ISO
Add-VMDvdDrive -VMName $VMName -Path $ISOPath
Write-OK "ISO attached"

# Set boot order: DVD first, then HDD
$dvd = Get-VMDvdDrive -VMName $VMName
$hdd = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -BootOrder $dvd, $hdd
Write-OK "Boot order: DVD -> HDD"

# Enable Guest Services (for file copy, etc.)
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
Write-OK "Guest Services enabled"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Yellow
Write-Host " VM '$VMName' is ready!                     " -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host " Next steps:" -ForegroundColor White
Write-Host "   1. Start the VM:  Start-VM -Name '$VMName'"
Write-Host "   2. Connect:       vmconnect localhost '$VMName'"
Write-Host "   3. Install Ubuntu Server (follow installer prompts)"
Write-Host "   4. After Ubuntu is installed, copy setup_openclaw.sh into the VM"
Write-Host "   5. Run:  chmod +x setup_openclaw.sh && sudo ./setup_openclaw.sh"
Write-Host ""

# ── Optionally start the VM ──────────────────────────────────────────────────
$start = Read-Host "Start the VM now? (y/N)"
if ($start -eq "y" -or $start -eq "Y") {
    Start-VM -Name $VMName
    Write-OK "VM started. Connect via: vmconnect localhost '$VMName'"
}
