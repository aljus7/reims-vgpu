# reims-vgpu for Windows

[![License: GPL-2.0-or-later OR LGPL-3.0-or-later](https://img.shields.io/badge/License-GPL--2.0--or--later%20OR%20LGPL--3.0--or--later-blue.svg)](LICENSE)

> **Beta, tested on one PC.** Run an x86-64 **macOS Tahoe** VM natively on **Windows 11**
> (QEMU + WHPX) with GPU acceleration through a Vulkan host GPU. Whether it boots and how fast
> it runs depends on your hardware; test it on yours. Nothing here is guaranteed to work.

This is a Windows-focused fork of [`reims-vgpu`](https://github.com/tqmane/reims-vgpu), a virtual
GPU that lets macOS use the GPU driver it already ships with (Metal commands are translated to
Vulkan on the host). There is nothing to install in the guest except two small optional scripts.

![An x86-64 macOS guest desktop](assets/readme/reims-vgpu-macos-x86-desktop.png)

## Install (recommended): the release ZIP

1. Download `reims-vgpu-windows-<version>.zip` from the
   [Releases page](https://github.com/aljus7/reims-vgpu/releases) and extract it.
2. In PowerShell 7.2+ run `.\install.ps1`. It asks for a **base folder** (press Enter for
   `%USERPROFILE%\ReimsVM`), copies the runtime there, creates the VM folders and firmware, and
   gives the VM its own OpenCore identity. It can attach a macOS Recovery image you provide.
3. Open **ReimsLauncher** (Start Menu) to create and start VMs, then follow the
   [manual](docs/windows-manual.md) to install macOS and run the two guest scripts.

You need: 64-bit Windows 11, *Windows Hypervisor Platform* enabled (then restart), a
Vulkan-capable GPU with a current driver, and a macOS Recovery/installer image you are entitled to
use. The release does not contain Apple media. No build tools and no .NET install are needed.

## The launcher app

`ReimsLauncher.exe` creates a VM (name, CPU cores, RAM, disk size; graphics acceleration is
always on), lists your VMs and starts or shuts them down. It is only a front end for the
PowerShell scripts in `scripts\windows`, so it must stay inside the install (or source) folder.

## The VM window

- **Ctrl+Alt+F** switches the VM window to full screen on its monitor and back. The F key is
  not passed to macOS; Ctrl and Alt are.
- Click into the window to capture the keyboard and mouse; **Ctrl+Alt+Win** releases them.
- To always start full screen, set `REIMS_VGPU_WINDOW_BORDERLESS=1` before `start.ps1`
  (Ctrl+Alt+F then leaves full screen).

## Two guest scripts (required once, optional afterwards)

Without `METAL_ERROR_MODE=5` a fresh install shows no Dock and blank icons. `prepare-tools.ps1`
(run by the installer) puts the scripts on a `REIMSTOOLS` disk that the VM attaches:

| Script | Run it | Purpose |
|---|---|---|
| `1-recovery-setup.sh` | once, from macOS **Recovery** Terminal after installing, before the first desktop boot | sets `METAL_ERROR_MODE=5` on the installed volume |
| `2-macos-optimize.sh` | in macOS Terminal, any time | sets the same key and trims animations |

**Make it faster:** turn on *Reduce Transparency* and *Reduce Motion*
(System Settings → Accessibility → Display), disable the Dock's opening animation and use a static
wallpaper. Liquid Glass blur and Mission Control are partly drawn in software in the guest and are
the main cause of low frame rates
([details](docs/windows-manual.md#6-make-it-faster-reduce-animations-blur-and-liquid-glass)).

## Build from source

Only needed to develop or to produce a release. Requirements: Git, PowerShell 7.2+, rustup,
MSYS2 (UCRT64, default `D:\msys64`, override with `REIMS_MSYS2_ROOT`) and the .NET 10 SDK
(`winget install Microsoft.DotNet.SDK.10`, for the launcher).

```powershell
git clone --branch main https://github.com/aljus7/reims-vgpu.git
cd reims-vgpu
.\scripts\windows\bootstrap.ps1                  # once: MSYS2 packages, Rust, cbindgen, QEMU source
.\scripts\windows\build.ps1                      # release build, no debug info
.\scripts\windows\build-launcher.ps1             # build\launcher\ReimsLauncher.exe
.\scripts\windows\doctor.ps1 -RequireWhpx        # check the host
.\scripts\windows\prepare-opencore.ps1
.\scripts\windows\prepare-vm.ps1 -Iso 'C:\path\Recovery.img'
.\scripts\windows\start.ps1
```

Make a release ZIP (after the build and a prepared default VM; Recovery media is never included):

```powershell
.\scripts\windows\Package-Release.ps1 -Version 0.1.0     # artifacts\reims-vgpu-windows-0.1.0.zip (+ .sha256)
```

Do not clone with `--recurse-submodules`; `bootstrap.ps1` fetches the one QEMU checkout needed.

## Documentation

| | |
|---|---|
| [docs/windows-manual.md](docs/windows-manual.md) | Step-by-step user manual |
| [docs/windows-build.md](docs/windows-build.md) | Requirements, build, script reference, release packaging |
| [docs/windows-vm.md](docs/windows-vm.md) | Recovery media and VM management |
| [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | Limitations (OpenGL is software in the guest; Mission Control is slow) |
| [docs/README.md](docs/README.md) | Full index, incl. the upstream design docs |

## Repository layout

| Path | Contents |
|---|---|
| `crates/` | The vGPU library (Rust): core, Vulkan platform, window, C API |
| `firmware/` | The PCI option ROM (UEFI driver, C) |
| `vendor/qemu` | Patched QEMU (submodule, `windows-native-tahoe`) |
| `scripts/windows/` | Build, VM, install and packaging scripts and the two guest scripts |
| `apps/vm-launcher/` | The launcher (WPF, .NET 10) |
| `xtask/`, `tests/` | Build tooling and the behaviour-lock test suite |
| `docs/` | Documentation |

Linux and Apple-silicon host tooling from the upstream project (`reims-ctl`, install and
`vmapple` scripts, the Makefile) was removed from this fork; the upstream repository still has it.

## License

The repository is free software under the GNU General Public License, version 2 or later, or the
GNU Lesser General Public License, version 3 or later, at the recipient's choice:
`GPL-2.0-or-later OR LGPL-3.0-or-later`, the workspace's `license` in `Cargo.toml`.
[LICENSE](LICENSE) says so, and `LICENSES/` holds the texts, the GPL's version 3 among them, since
the LGPL's version 3 adds its permissions to it.

QEMU (`vendor/qemu`) keeps QEMU's licenses. The crates the build takes keep their own:
metal2vulkan's, which the Vulkan platform links, and SDL3's sources, which the window crate builds
and links statically, among them.

## Legal

Metal and macOS are trademarks of Apple Inc. reims-vgpu is an independent project and is not
affiliated with, sponsored by, or endorsed by Apple Inc.
