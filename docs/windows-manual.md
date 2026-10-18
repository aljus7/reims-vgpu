# Windows user manual

Step-by-step guide to running macOS Tahoe in a VM on Windows with this
repository. Build details and the full script list are in
[windows-build.md](windows-build.md).

> **Status: beta, and your hardware is untested here.** The steps below were
> exercised on one PC (Ryzen host, RX 6600, 12 logical CPUs). A Vulkan-capable
> GPU and Windows Hypervisor Platform are required. Nothing here guarantees
> that a VM will boot or run smoothly on your PC.

## 1. The short version

```powershell
.\scripts\windows\bootstrap.ps1                  # once: build dependencies
.\scripts\windows\build.ps1                      # release build, no debug info
.\scripts\windows\doctor.ps1 -RequireWhpx        # check the host
.\scripts\windows\prepare-opencore.ps1           # OpenCore + firmware
.\scripts\windows\prepare-vm.ps1 -Iso 'C:\path\Recovery.img'
.\scripts\windows\start.ps1                      # boot the installer, install macOS
.\scripts\windows\prepare-tools.ps1              # (VM stopped) builds the REIMSTOOLS disk
# Start the VM, open OpenCore's Recovery entry, run guest script 1 (section 4)
.\scripts\windows\start.ps1 -WithoutInstaller    # day to day
```

## 2. Build

`build.ps1` defaults to the **release** profile: no debug symbols in the Rust
library or in QEMU, and the QEMU executables are stripped. Use
`-Profile dev` or `-Profile checked` only when developing. The outputs land in
`build\qemu` (`qemu-system-x86_64.exe`, `reims_vgpu_c.dll`, `ReimsVgpu.rom`).

## 3. Install macOS

1. `prepare-vm.ps1 -Iso <your Recovery or installer image>` validates the image
   and creates the VM (128 GiB sparse disk, 8 vCPUs, 8 GiB RAM, 1920x1080).
2. `start.ps1` boots it. In OpenCore's picker choose the macOS installer.
3. In Disk Utility, erase the VM's own virtual disk as APFS (never a host
   disk) and install macOS. The VM restarts several times; pick the macOS
   installer or "macOS Installer" entry each time until the install finishes.
4. Shut the VM down from the guest (or `.\scripts\windows\stop.ps1`).

## 4. Required once: the Metal fix (guest script 1, in Recovery)

Without `METAL_ERROR_MODE=5` the icon service keeps crashing: you get a
wallpaper, no Dock and blank icons. It can only be set before the first desktop
session, from Recovery, because the installed volume does not exist earlier.

1. With the VM stopped, run `.\scripts\windows\prepare-tools.ps1`. It builds
   `vm\tools\ReimsTools.img`, which `start.ps1` attaches automatically.
2. `start.ps1 -WithoutInstaller`, and in OpenCore's picker choose **Recovery**
   (any arrow key stops the countdown).
3. Utilities → Terminal:

   ```sh
   sh /Volumes/REIMSTOOLS/1-recovery-setup.sh
   reboot
   ```

   If that path does not exist, use `sh /Volumes/*/1-recovery-setup.sh`.

4. Pick the installed macOS entry and finish setup.

## 5. After the desktop works (guest script 2, in macOS)

Run once in macOS Terminal:

```sh
sh /Volumes/REIMSTOOLS/2-macos-optimize.sh
```

It sets the Metal key (if you skipped step 4) and turns off Dock, window and
Mission Control animations in your account. Reboot afterwards. The effect of
the animation part is small (measured Mission Control 9.3 → 9.7 fps); the
settings in section 6 matter more.

`setup.command` on the same disk additionally enables SSH for VM control and
sets keyboard, time zone and sleep options. Open it from Finder if you use the
Windows manager application.

## 6. Make it faster: reduce animations, blur and Liquid Glass

Tahoe's translucent, blurred "Liquid Glass" surfaces and animations are drawn
partly in software inside the guest. A paravirtual GPU cannot hide that. Turn
them down in **System Settings** (these cannot be set from a script):

1. **Accessibility → Display → Reduce Transparency: on.** Removes the blur
   and translucency from menus, the Dock, sidebars and Control Center, which is
   the largest single saving.
2. **Accessibility → Display → Reduce Motion: on.** Replaces zoom and slide
   animations with fades.
3. **Desktop & Dock:** turn off *Animate opening applications*, turn off
   *Automatically rearrange Spaces based on most recent use*, and keep the Dock
   small without magnification.
4. **Wallpaper:** use a static picture, not a dynamic or video wallpaper, and
   keep Widgets off the desktop.
5. **Mission Control and full-screen Spaces** are the heaviest animations here
   (about 6–20 fps in measurements). Prefer ordinary windows.
6. **Do not run other heavy work on the host** while using the VM. Compiling on
   the host made the guest drop below 40 fps for a third of a test run.
7. **First launch of an app is slow** (icons are rendered once, then cached on
   the guest disk and kept across reboots). Open System Settings and your usual
   apps once after installing and let them finish; later launches are faster.
8. Apps that use OpenGL (for example Chess and old games) run on a software
   renderer in the guest. Metal apps are accelerated; OpenGL is not.

## 7. Day to day

| Task | Command |
|---|---|
| Start (installed macOS) | `.\scripts\windows\start.ps1 -WithoutInstaller` |
| Preview the launch plan | `.\scripts\windows\start.ps1 -DryRun` |
| Shut down | `.\scripts\windows\stop.ps1` |
| Another independent VM | `.\scripts\windows\New-VM.ps1 -Name test`, `Start-VM.ps1 -VMName test` |
| Check the host | `.\scripts\windows\doctor.ps1 -RequireWhpx` |
| Collect logs for a bug report | `.\scripts\windows\collect-logs.ps1` |

VM state (disks, NVRAM, logs, SSH key) lives under `vm\` and is not part of the
Git repository. Do not move or copy a VM while QEMU is running.

## 8. Troubleshooting

- **Wallpaper only / no Dock / blank icons:** guest script 1 was not run, or ran
  before macOS was installed. Run it again from Recovery (section 4), or run
  guest script 2 from macOS and reboot.
- **"You shut down because of a problem" after killing QEMU:** the guest was
  stopped abruptly. Let it restart; it recovers by itself. Shut down from the
  guest or with `stop.ps1` next time.
- **WHPX or Vulkan errors:** see [windows-build.md](windows-build.md),
  "Troubleshooting and limitations".
- **Stutter now and then (vsync dips, 250 ms to multi-second freezes):** a known
  limitation. Measurements point to guest-side work (software rendering, icon
  generation) and host CPU contention, not to the host GPU. Findings:
  [windows-ui-stall-findings.md](windows-ui-stall-findings.md).
