#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RuntimeRoot = (Join-Path $PSScriptRoot '..\..\final'),
    [string]$Destination = (Join-Path $PSScriptRoot '..\..\artifacts\reims-vgpu-windows-runtime.zip')
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$Destination = [IO.Path]::GetFullPath($Destination)
$ChecksumPath = [IO.Path]::ChangeExtension($Destination, '.sha256')
if (!(Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
    throw "Runtime folder does not exist: $RuntimeRoot"
}
if (Test-Path -LiteralPath $Destination) {
    throw "Destination exists; refusing to overwrite it: $Destination"
}
if (Test-Path -LiteralPath $ChecksumPath) {
    throw "Checksum file exists; refusing to overwrite it: $ChecksumPath"
}
$runtimePrefix = $RuntimeRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if ($Destination.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a ZIP destination outside the runtime folder.'
}
$requiredFiles = @(
    'README.txt',
    'install.ps1',
    'ReimsLauncher.exe',
    'New-VM.ps1',
    'Start-VM.ps1',
    'Stop-VM.ps1',
    'Relocate-VM.ps1',
    'vm\state\config.json',
    'vm\disks\base.qcow2',
    'vm\disks\current.qcow2',
    'runtime\msys2\ucrt64\bin\7z.exe',
    'scripts\windows\prepare-opencore.ps1',
    'scripts\windows\prepare-vm.ps1'
)
foreach ($relativePath in $requiredFiles) {
    if (!(Test-Path -LiteralPath (Join-Path $RuntimeRoot $relativePath) -PathType Leaf)) {
        throw "Runtime is incomplete; required file is missing: $relativePath"
    }
}

$stage = Join-Path $ProjectRoot ('.work\package-runtime-' + [guid]::NewGuid().ToString('N'))
$sevenZip = Join-Path $RuntimeRoot 'runtime\msys2\ucrt64\bin\7z.exe'
$sevenZipDll = Join-Path $RuntimeRoot 'runtime\msys2\ucrt64\bin\7z.dll'
if (!(Test-Path -LiteralPath $sevenZipDll -PathType Leaf)) {
    throw "Bundled 7-Zip runtime library is missing: $sevenZipDll"
}
$recoveryRelativePath = 'vm\media\Tahoe-Recovery-GPT.img'
$excludedFiles = @(
    $recoveryRelativePath,
    'vm\state\opencore-identity.json',
    'vm\state\runtime.json'
)
$savedEnvironment = @{}
foreach ($name in @('REIMS_PROJECT_ROOT_OVERRIDE','REIMS_VM_ROOT_OVERRIDE','REIMS_MSYS2_ROOT','PYTHONHOME','PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $rootPrefix = $RuntimeRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($file in Get-ChildItem -LiteralPath $RuntimeRoot -Force -Recurse -File) {
        $relative = $file.FullName.Substring($rootPrefix.Length)
        if ($relative -match '^(?:\.work[\\/](?:diagnostics|tmp)|vm[\\/](?:logs|media[\\/]inspection))(?:[\\/]|$)' -or
            $excludedFiles -contains $relative) {
            continue
        }
        $destinationPath = Join-Path $stage $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath
    }

    $varsTemplate = Join-Path $stage 'vm\firmware\OVMF_VARS.template.fd'
    $varsFile = Join-Path $stage 'vm\firmware\OVMF_VARS.fd'
    if (Test-Path -LiteralPath $varsTemplate -PathType Leaf) {
        Copy-Item -LiteralPath $varsTemplate -Destination $varsFile -Force
    }
    @'
Reims vGPU portable Windows runtime
===================================

This ZIP contains the Windows runtime, QEMU data, OpenCore/OVMF firmware,
scripts, and a fresh blank default VM. It does not contain Apple Recovery or
installer media, local diagnostic logs, or the source project's active disk.
You must provide recovery/installer media that you are entitled to use.

Requirements: 64-bit Windows 11, PowerShell 7.2+, Windows Hypervisor Platform
(WHPX), and a compatible Vulkan-capable GPU/driver for accelerated graphics.
Actual guest boot and GPU performance must be tested on your host.

1. Extract the whole ZIP to any folder; preserve its directory layout.
2. Run the installer in PowerShell 7.2+:

   .\install.ps1

   It asks for a base folder (Enter = %USERPROFILE%\ReimsVM), copies the
   runtime there, creates the VM folders and firmware, generates this VM's
   own OpenCore identity, builds the guest-tools disk and, if you give it a
   macOS Recovery image, prepares the default VM. Options: -InstallPath,
   -RecoveryImage, -NoPrompt.
3. Open ReimsLauncher.exe from the install folder (a Start Menu shortcut is
   created), or use the scripts:

   .\Start-VM.ps1
   .\Start-VM.ps1 -WithoutInstaller      (after macOS is installed)
   .\Stop-VM.ps1 -Exit
   .\New-VM.ps1 -Name test -DiskGiB 256 -Cpus 8 -MemoryMiB 8192

After installing macOS, follow docs\windows-manual.md: run the two guest
scripts (Metal fix from Recovery, then optional speed-ups). Without the Metal
fix there is no Dock and icons stay blank.

Without a Recovery image the installer still completes; put one at
vm\media\Tahoe-Recovery-GPT.img and run
.\scripts\windows\prepare-vm.ps1 -Iso .\vm\media\Tahoe-Recovery-GPT.img

The default VM disk is a sparse 128 GiB QCOW2 disk. New VMs have independent
disk chains, NVRAM, OpenCore configuration, identities, and loopback ports.
No VM is guaranteed to boot on every host. Do not move a runtime while QEMU is
running. After moving the entire folder, the first wrapper start/stop updates
saved paths and QCOW2 backing links.

For full source-build, VM-management, and troubleshooting instructions, see
docs\windows-build.md in the source repository:
https://github.com/aljus7/reims-vgpu/blob/windows-native-tahoe/docs/windows-build.md

macOS use is subject to Apple's terms. This project does not supply or grant
rights to an operating system.
'@ | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding utf8NoBOM

    $env:REIMS_PROJECT_ROOT_OVERRIDE = $stage
    $env:REIMS_VM_ROOT_OVERRIDE = Join-Path $stage 'vm'
    $env:REIMS_MSYS2_ROOT = Join-Path $stage 'runtime\msys2'
    $env:PYTHONHOME = Join-Path $env:REIMS_MSYS2_ROOT 'ucrt64'
    $env:PATH = (@((Join-Path $env:REIMS_MSYS2_ROOT 'ucrt64\bin'),(Join-Path $stage 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    New-Item -ItemType Directory -Force -Path (Join-Path $stage '.work\diagnostics') | Out-Null
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'Relocate-VM.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not rebase runtime state into the archive staging folder.' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'scripts\windows\prepare-opencore.ps1') `
        -Version 1.0.8 -FirmwareDirectory (Join-Path $env:REIMS_MSYS2_ROOT 'ucrt64\share\qemu') `
        -GenerateIdentity -Rebuild | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare an archive-local OpenCore identity.' }
    Remove-Item -LiteralPath (Join-Path $stage 'vm\state\opencore-identity.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stage '.work\diagnostics') -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Push-Location $stage
    try {
        & $sevenZip a -tzip -mx=5 $Destination '*' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '7-Zip could not create the runtime archive.' }
    } finally {
        Pop-Location
    }
    & $sevenZip t $Destination | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The generated runtime archive failed its integrity test.' }

    $listing = & $sevenZip l -slt $Destination
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the runtime archive contents.' }
    if ($listing | Where-Object { $_ -match 'Path = vm[\\/]media[\\/]Tahoe-Recovery-GPT\.img$' }) {
        throw 'The archive unexpectedly contains Apple Recovery media.'
    }
    $archive = Get-Item -LiteralPath $Destination
    $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($archive.Name)" | Set-Content -LiteralPath $ChecksumPath -Encoding ascii
    "Created verified runtime ZIP at $Destination ($([math]::Round($archive.Length / 1MB)) MiB); checksum: $ChecksumPath. Apple Recovery media is excluded."
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
