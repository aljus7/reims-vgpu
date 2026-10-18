# Windows build and runtime guide

This guide builds the Windows-native Reims vGPU/QEMU software, prepares and
manages a macOS virtual machine, and optionally exports a relocatable runtime
ZIP. It does not build macOS, include an installer, or copy an existing VM's
active disk.

If you use mise, see the [mise setup and task guide](windows-mise.md) for the
pinned Rust toolchain and `mise run windows:*` shortcuts.

> **Experimental:** a successful build, dry run, or VM launch does not
> guarantee that macOS will install, boot, or perform well on every host.
> Hardware boot and GPU performance must be tested on the target PC.

## Requirements

- 64-bit Windows 11 and PowerShell 7.2 or newer (`pwsh`).
- Git, Rust via rustup, and MSYS2 with the UCRT64 environment. The default
  MSYS2 location is `D:\msys64`; set `$env:REIMS_MSYS2_ROOT` if yours differs.
- Internet access for the initial QEMU submodule, build dependencies, Rust
  components, and the pinned OpenCore release.
- Windows Hypervisor Platform (WHPX), enabled in Windows Features, followed
  by a Windows restart, for normal VM execution.
- A Vulkan-capable Windows GPU and driver supported by the host build.
- A recovery or installer image you are entitled to use. The Tahoe Recovery
  image is network recovery, not a full offline installer.

Bootstrap installs the pinned build dependencies and may take several minutes.
Review the scripts before allowing it to install software.

## Get the source and build

Clone the branch, including the pinned QEMU submodule:

```powershell
git clone --branch windows-native-tahoe --recurse-submodules https://github.com/aljus7/reims-vgpu.git
cd reims-vgpu
```

If you already cloned without submodules, `bootstrap.ps1` initializes the
pinned QEMU checkout. Run the build and checks from the repository root:

```powershell
.\scripts\windows\bootstrap.ps1
.\scripts\windows\build.ps1 -Profile release
.\scripts\windows\verify.ps1
.\scripts\windows\doctor.ps1
```

`bootstrap.ps1` installs the declared MSYS2 UCRT64 packages, Rust toolchain,
`cbindgen`, and required source checkouts. `build.ps1` builds the Windows
Vulkan distribution, option ROM, and patched x86-64 QEMU with WHPX support.
`verify.ps1` runs the native Windows checks. `doctor.ps1 -RequireWhpx` also
requires the host hypervisor to be ready.

Important build outputs:

| Output | Purpose |
| --- | --- |
| `.work\target\dist-vulkan\lib\reims_vgpu_c.dll` | Reims Vulkan library |
| `.work\target\dist-vulkan\share\reims-vgpu\ReimsVgpu.rom` | PCI option ROM |
| `build\qemu\qemu-system-x86_64.exe` | Patched QEMU VM executable |
| `build\qemu\qemu-img.exe` | Virtual-disk utility |

`build\qemu` also contains intermediate files. Do not copy that directory
wholesale for distribution; use the exporter below to resolve runtime
dependencies and assemble only the required files.

## Prepare and run a VM from the source tree

First prepare the pinned OpenCore files and firmware, then inspect and attach
your own compatible x86-64 recovery/installer image:

```powershell
.\scripts\windows\prepare-opencore.ps1
.\scripts\windows\prepare-vm.ps1 -Iso 'C:\path\to\your\Recovery-or-installer.img'
.\scripts\windows\doctor.ps1 -RequireWhpx
.\scripts\windows\start.ps1 -DryRun
.\scripts\windows\start.ps1
```

The preparation script validates the image's partition format and x86-64
booter, then saves its path. It does not rewrite the original image. Supported
media formats and the optional SHA-256 inspection are described in
[Windows VM preparation and management](windows-vm.md).

Use Disk Utility only inside the VM to erase its virtual disk as APFS. Never
select a host disk. To run an already-installed guest without attaching the
installer again:

```powershell
.\scripts\windows\start.ps1 -WithoutInstaller
```

The default VM uses a sparse 128 GiB QCOW2 disk, 8 vCPUs, 8 GiB RAM, and a
1920x1080 display. The disk file grows as guest data is written; the requested
capacity is not preallocated. The source project's VM state is under the
ignored `vm\` directory and is not part of the Git repository.

## PowerShell script reference

Run commands from the repository root unless noted.

| Script | What it does |
| --- | --- |
| `bootstrap.ps1` | Fetches/initializes pinned build sources and installs build dependencies. |
| `build.ps1 -Profile release` | Builds the Windows Reims Vulkan distribution, ROM, and QEMU. |
| `verify.ps1` | Runs the native Windows build checks. |
| `doctor.ps1 [-RequireWhpx]` | Reports Windows tools, Vulkan, firmware, and optional WHPX readiness. |
| `prepare-opencore.ps1` | Downloads/verifies the pinned OpenCore release and prepares OpenCore/OVMF files. |
| `prepare-vm.ps1 -Iso <path>` | Validates recovery/installer media and creates or updates VM configuration and blank disks. |
| `start.ps1 [-DryRun] [-WithoutInstaller]` | Starts the default source-tree VM; `-DryRun` prints the launch plan without starting QEMU. |
| `stop.ps1` | Requests a guest shutdown through the local QMP control endpoint. |
| `New-VM.ps1 -Name <name> [-DiskGiB <size>]` | Creates an independent named VM with a blank disk and fresh VM identity. |
| `Start-VM.ps1 [-VMName <name>]` | Starts the default or named VM using the portable-script wrapper. |
| `Stop-VM.ps1 [-VMName <name>] [-Exit]` | Requests shutdown; `-Exit` also closes QEMU after guest shutdown. |
| `Export-Runtime.ps1 [-Destination <path>]` | Builds a separate runtime-only folder; refuses to overwrite a destination. |
| `Package-Runtime.ps1 [-RuntimeRoot <path>] [-Destination <path>]` | Creates a relocatable ZIP outside the runtime folder, without Apple Recovery media. |

Create another VM without touching the default VM's disk:

```powershell
.\scripts\windows\New-VM.ps1 -Name test -DiskGiB 256
.\scripts\windows\Start-VM.ps1 -VMName test
.\scripts\windows\Stop-VM.ps1 -VMName test -Exit
```

Names may contain ASCII letters, numbers, `_`, and `-`. Disk sizes are
64–2048 GiB. Each VM has its own disk chain, NVRAM, OpenCore configuration,
identity, and loopback ports. The creation script will not overwrite an
existing VM directory.

The wrappers `Start-VM.ps1` and `Stop-VM.ps1` temporarily configure paths for
the selected VM and restore the caller's environment when they finish. Set
`REIMS_MSYS2_ROOT` in the current PowerShell process when MSYS2 is not in its
default location. Do not move or copy a VM while QEMU is running.

## Export and use a portable runtime

After building QEMU and preparing a recovery image in the source VM, export a
runtime-only directory:

```powershell
.\scripts\windows\Export-Runtime.ps1 `
  -RecoveryImage 'C:\path\to\your\Recovery-or-installer.img' `
  -DiskGiB 128 `
  -Destination '.\final'
```

The exporter copies the runtime binaries and their resolved DLL dependencies,
QEMU data, Python/7-Zip runtime files, pinned OpenCore tools, matching OVMF
firmware, scripts, and the recovery image supplied to it. It creates a fresh
blank disk and VM identity. It never copies or modifies the source tree's
active disk (`vm\disks\current.qcow2`). It refuses to overwrite an existing
destination.

Create the distributable ZIP outside `final\`:

```powershell
.\scripts\windows\Package-Runtime.ps1 `
  -RuntimeRoot '.\final' `
  -Destination '.\artifacts\reims-vgpu-windows-runtime.zip'
```

The ZIP intentionally excludes Apple Recovery/installer media and local
diagnostic logs. It contains the runtime, OpenCore/OVMF files, a fresh blank
default VM, and scripts. This avoids publishing Apple installation media; it
also means first-run installation requires that you provide compatible media.
The packager writes an adjacent `.sha256` file; compare it with
`Get-FileHash .\artifacts\reims-vgpu-windows-runtime.zip -Algorithm SHA256`
after copying or downloading the ZIP.

### Set up the packaged runtime

Extract the ZIP to a writable folder and preserve its directory structure.
Before the first boot, make a private OpenCore identity for this VM:

```powershell
.\scripts\windows\prepare-opencore.ps1 `
  -Version 1.0.8 `
  -FirmwareDirectory '.\runtime\msys2\ucrt64\share\qemu' `
  -GenerateIdentity -Rebuild
```

Provide a compatible recovery or installer image you are licensed to use.
For the default VM, copy it to
`vm\media\Tahoe-Recovery-GPT.img`, then have the packaged scripts validate it:

```powershell
.\scripts\windows\prepare-vm.ps1 -Iso '.\vm\media\Tahoe-Recovery-GPT.img'
.\Start-VM.ps1 -DryRun
.\Start-VM.ps1
```

`prepare-vm.ps1` updates the default VM's media selection while retaining its
existing blank disk, NVRAM, and settings. To create another VM, keep the
recovery image at that package path so `New-VM.ps1` can use it:

```powershell
.\New-VM.ps1 -Name test -DiskGiB 256
.\Start-VM.ps1 -VMName test
```

After installation, start without the Recovery media:

```powershell
.\Start-VM.ps1 -WithoutInstaller
```

Use `.\Stop-VM.ps1 -Exit` for a guest shutdown followed by closing QEMU.
After moving the complete runtime folder, the first start/stop/VM creation
updates saved paths and QCOW2 backing links. Keep the full folder layout and
never relocate it while a VM is running.

## Troubleshooting and limitations

- **WHPX unavailable:** enable *Windows Hypervisor Platform* in Windows
  Features, restart Windows, and rerun `.\scripts\windows\doctor.ps1
  -RequireWhpx`.
- **Vulkan device/driver error:** update the host GPU driver and run the
  non-required checks in `doctor.ps1`. A Vulkan-capable GPU is required for
  accelerated graphics; this project does not silently fall back to TCG for a
  normal start.
- **Recovery image rejected:** confirm it is x86-64 media in a supported
  APM/HFS+, GPT/HFS+, or ISO9660 format. A compressed Apple `BaseSystem.dmg`
  may need conversion to a separate raw image using `qemu-img`; do not rename
  a DMG and treat it as a raw disk.
- **VM path changed:** stop QEMU, copy the entire runtime folder, then run the
  wrapper again. The relocation helper refuses to change state when it
  detects the VM process still running.
- **Build or preparation fails:** retain the complete error output and run
  `.\scripts\windows\doctor.ps1`; generated logs and guest state belong in the
  ignored local `.work\` and `vm\` directories, not in a public issue.

WHPX, GPU support, available RAM/storage, and compatible installer media are
host requirements. macOS installation and use are subject to Apple's terms;
the project does not supply or grant rights to an operating system.
