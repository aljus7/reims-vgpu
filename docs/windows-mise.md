# Use mise with the Windows project

[mise](https://mise.jdx.dev/) works well as a project-aware Rust toolchain
selector and task runner for the Windows-native build. This repository includes
`mise.toml`, which pins the Rust version used by the Windows build and exposes
common PowerShell scripts as named mise tasks.

mise does **not** replace MSYS2 UCRT64, Vulkan, WHPX, or the project's
PowerShell bootstrap. `windows:bootstrap` still installs the pinned native
dependencies and the build scripts keep their isolated per-checkout Cargo and
Rust caches under `.work\`. Use mise to select the Rust toolchain when hacking
on Rust code and to invoke the documented Windows workflows consistently.

## One-time setup

Install mise using one of the [official Windows installation methods](https://mise.jdx.dev/installing-mise.html#windows-winget)
if it is not already available, then clone the Windows branch without
recursively cloning QEMU's nested optional submodules:

```powershell
git clone --branch windows-native-tahoe https://github.com/aljus7/reims-vgpu.git G:\reims-vgpu
Set-Location G:\reims-vgpu
```

The project bootstrap initializes the pinned QEMU checkout needed for its
build. Open PowerShell 7.2 or newer in the repository root:

```powershell
mise --version
mise trust
mise install
mise tasks ls
```

`mise install` installs Rust 1.98.1 with `rustfmt`, `clippy`, and the
`x86_64-pc-windows-gnu` target. This is the Rust toolchain used for development
and editing. The Windows build scripts separately initialize an isolated
toolchain in `.work\`; this keeps build caches local to the checkout.

Shell activation is optional when using `mise run`. To have mise activate
automatically as you enter project directories, follow the official
[PowerShell activation guide](https://mise.jdx.dev/installing-mise.html#powershell).

## Build and verify

Run the mise tasks from the repository root:

```powershell
mise run windows:bootstrap
mise run windows:build
mise run windows:verify
mise run windows:doctor
```

Bootstrap is a one-time (and repeatable) setup step. It initializes the pinned
QEMU submodule, installs MSYS2 packages, and prepares the build toolchain. Build
compiles the Vulkan library, option ROM, and Windows QEMU. Verification checks
the native build; the doctor reports host capabilities. Add `-RequireWhpx` to
the direct doctor script when you also want to require WHPX readiness:

```powershell
.\scripts\windows\doctor.ps1 -RequireWhpx
```

The runtime export and ZIP packaging tasks require a prepared VM and a
compatible recovery image at `vm\media\Tahoe-Recovery-GPT.img`:

```powershell
mise run windows:vm-dry-run
mise run windows:export
mise run windows:package
```

The packaged ZIP is written to `artifacts\reims-vgpu-windows-runtime.zip`,
outside `final\`, and does not include Apple Recovery/installer media. Supply
your own licensed media as described in the
[Windows build and usage guide](windows-build.md).
The packager also writes an adjacent `.sha256` checksum file.

## Work on the Rust code

mise selects the pinned toolchain for commands run in this checkout:

```powershell
mise exec -- rustc --version
mise exec -- cargo --version
mise exec -- cargo fmt --all -- --check
mise exec -- cargo xtask check
```

For changes to the Windows native backend, use the repository scripts rather
than a plain `cargo build`; they configure the UCRT64 C/C++ toolchain,
`pkg-config`, firmware build, and patched QEMU environment. Before opening a
pull request, read [AGENTS.md](../AGENTS.md) and the relevant contributor
guidance for the code being changed.

## Troubleshooting

- **mise says the project is not trusted:** inspect `mise.toml`, then run
  `mise trust` in the repository root.
- **Rust version differs:** run `mise ls --current` and `mise exec -- rustup show
  active-toolchain`. The Windows build scripts select their isolated toolchain
  explicitly; do not remove the pin in `rust-toolchain.toml`.
- **`pwsh` is missing:** install PowerShell 7.2 or newer and ensure `pwsh.exe`
  is on `PATH`.
- **MSYS2 is installed outside `D:\msys64`:** set
  `$env:REIMS_MSYS2_ROOT = 'C:\path\to\msys64'` in the current PowerShell
  process before running the Windows scripts.
- **WHPX or Vulkan is unavailable:** mise cannot supply these host features.
  Enable WHPX, restart Windows, install a compatible GPU driver, and run the
  Windows doctor script.
