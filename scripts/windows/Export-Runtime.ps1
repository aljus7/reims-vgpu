#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\..\final'),
    [string]$RecoveryImage,
    [ValidateRange(64,2048)][int]$DiskGiB = 128,
    [ValidateRange(1024,65535)][int]$QmpPort = 4544,
    [ValidateRange(1024,65535)][int]$SshPort = 2322
)
. (Join-Path $PSScriptRoot 'start.ps1') -FunctionsOnly
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$MsysRoot = if ($env:REIMS_BUILD_MSYS2_ROOT) { $env:REIMS_BUILD_MSYS2_ROOT } else { $MsysRoot }
if (!(Test-Path -LiteralPath (Join-Path $MsysRoot 'ucrt64\bin\objdump.exe'))) {
    if (Test-Path -LiteralPath 'D:\msys64\ucrt64\bin\objdump.exe') {
        $MsysRoot = 'D:\msys64'
    } else {
        throw 'MSYS2 build tools are missing; set REIMS_BUILD_MSYS2_ROOT to the build MSYS2 installation.'
    }
}
if ($QmpPort -eq $SshPort) { throw 'QMP and SSH ports must differ.' }
$Destination = [IO.Path]::GetFullPath($Destination)
$partial = "$Destination.partial"
if (Test-Path -LiteralPath $Destination) { throw "Destination exists; refusing to overwrite it: $Destination" }
if (Test-Path -LiteralPath $partial) { throw "Temporary export folder exists; inspect it before retrying: $partial" }
$sourcePrefix = $ProjectRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if ($Destination.StartsWith($ProjectRoot, [StringComparison]::OrdinalIgnoreCase) -and
    !$Destination.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose an export destination inside the project (such as final) or outside the project root.'
}
$RecoveryImage = if ($RecoveryImage) { [IO.Path]::GetFullPath($RecoveryImage) } else {
    Join-Path $ProjectRoot 'vm\media\Tahoe-Recovery-GPT.img'
}
foreach ($file in @(
    (Join-Path $ProjectRoot 'build\qemu\qemu-system-x86_64.exe'),
    (Join-Path $ProjectRoot 'build\qemu\qemu-img.exe'),
    (Join-Path $ProjectRoot 'build\qemu\reims_vgpu_c.dll'),
    (Join-Path $ProjectRoot '.work\target\dist-vulkan\share\reims-vgpu\ReimsVgpu.rom'),
    (Join-Path $ProjectRoot 'vendor\qemu\pc-bios'),
    (Join-Path $ProjectRoot 'vm\firmware\OVMF_CODE.fd'),
    (Join-Path $ProjectRoot 'vm\firmware\OVMF_VARS.template.fd'),
    (Join-Path $ProjectRoot 'vm\firmware\opencore-1.0.8\root\EFI\OC\config.plist'),
    (Join-Path $ProjectRoot '.work\downloads\OpenCore-1.0.8-RELEASE.zip'),
    (Join-Path $ProjectRoot '.work\downloads\OpenCore-1.0.8-release.json'),
    $RecoveryImage
)) {
    if (!(Test-Path -LiteralPath $file)) { throw "Required built or prepared input is missing: $file" }
}
$msysBin = Join-Path $MsysRoot 'ucrt64\bin'
$python = Join-Path $msysBin 'python.exe'
$pythonLib = Join-Path $MsysRoot 'ucrt64\lib\python3.14'
$pythonDynload = Join-Path $pythonLib 'lib-dynload'
$objdump = Join-Path $msysBin 'objdump.exe'
foreach ($file in @($python,$pythonLib,$pythonDynload,$objdump)) {
    if (!(Test-Path -LiteralPath $file)) { throw "Missing MSYS2 runtime/build tool: $file" }
}
$sevenZip = Get-ReimsTool '7z.exe'
$sevenZipCandidates = @(
    $sevenZip,
    (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
    (Join-Path $env:USERPROFILE 'scoop\apps\7zip\current\7z.exe')
)
$sevenZip = $null
$sevenZipDll = $null
foreach ($candidate in $sevenZipCandidates) {
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $candidateDll = Join-Path (Split-Path -Parent $candidate) '7z.dll'
    if (Test-Path -LiteralPath $candidateDll -PathType Leaf) {
        $sevenZip = $candidate
        $sevenZipDll = $candidateDll
        break
    }
}
if (!$sevenZip) { throw 'Could not find 7z.exe alongside its required 7z.dll.' }
$vars = @{}
foreach ($variableName in @('REIMS_PROJECT_ROOT_OVERRIDE','REIMS_VM_ROOT_OVERRIDE','REIMS_MSYS2_ROOT','PYTHONHOME','PATH')) {
    $vars[$variableName] = [Environment]::GetEnvironmentVariable($variableName, 'Process')
}
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $ProjectRoot
    $env:REIMS_MSYS2_ROOT = $MsysRoot
    $env:PYTHONHOME = Join-Path $MsysRoot 'ucrt64'
    $env:PATH = (@($msysBin,(Join-Path $ProjectRoot 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)

    New-Item -ItemType Directory -Path $partial | Out-Null
    $directories = @(
        'build\qemu','vendor\qemu\pc-bios','.work\downloads',
        '.work\target\dist-vulkan\share\reims-vgpu',
        'runtime\msys2\ucrt64\bin','runtime\msys2\ucrt64\lib',
        'runtime\msys2\ucrt64\share\qemu','scripts\windows',
        'vm\media','vm\firmware'
    )
    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Force -Path (Join-Path $partial $directory) | Out-Null
    }
    function Copy-TreeContents([string]$Source, [string]$Target) {
        New-Item -ItemType Directory -Force -Path $Target | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Target -Recurse -Force
    }
    $buildOut = Join-Path $partial 'build\qemu'
    Copy-Item -LiteralPath `
        (Join-Path $ProjectRoot 'build\qemu\qemu-system-x86_64.exe'), `
        (Join-Path $ProjectRoot 'build\qemu\qemu-img.exe'), `
        (Join-Path $ProjectRoot 'build\qemu\reims_vgpu_c.dll') `
        -Destination $buildOut
    Copy-TreeContents (Join-Path $ProjectRoot 'vendor\qemu\pc-bios') (Join-Path $partial 'vendor\qemu\pc-bios')
    Copy-Item -LiteralPath (Join-Path $ProjectRoot '.work\target\dist-vulkan\share\reims-vgpu\ReimsVgpu.rom') `
        -Destination (Join-Path $partial '.work\target\dist-vulkan\share\reims-vgpu')
    Copy-Item -LiteralPath $RecoveryImage -Destination (Join-Path $partial 'vm\media\Tahoe-Recovery-GPT.img')
    Copy-Item -LiteralPath (Join-Path $ProjectRoot '.work\downloads\OpenCore-1.0.8-RELEASE.zip'), `
        (Join-Path $ProjectRoot '.work\downloads\OpenCore-1.0.8-release.json') `
        -Destination (Join-Path $partial '.work\downloads')
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'vm\firmware\OVMF_CODE.fd') `
        -Destination (Join-Path $partial 'runtime\msys2\ucrt64\share\qemu\edk2-x86_64-code.fd')
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'vm\firmware\OVMF_VARS.template.fd') `
        -Destination (Join-Path $partial 'runtime\msys2\ucrt64\share\qemu\edk2-i386-vars.fd')
    Copy-Item -LiteralPath $python -Destination (Join-Path $partial 'runtime\msys2\ucrt64\bin')
    Copy-TreeContents $pythonLib (Join-Path $partial 'runtime\msys2\ucrt64\lib\python3.14')
    Copy-Item -LiteralPath $sevenZip,$sevenZipDll -Destination (Join-Path $partial 'runtime\msys2\ucrt64\bin')

    $runtimeBin = Join-Path $partial 'runtime\msys2\ucrt64\bin'
    $searchRoots = @(
        (Join-Path $ProjectRoot 'build\qemu'),
        $msysBin,
        (Join-Path $MsysRoot 'mingw64\bin')
    )
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($binary in @(
        (Join-Path $ProjectRoot 'build\qemu\qemu-system-x86_64.exe'),
        (Join-Path $ProjectRoot 'build\qemu\qemu-img.exe'),
        (Join-Path $ProjectRoot 'build\qemu\reims_vgpu_c.dll'),
        $python
    ) + @(Get-ChildItem -LiteralPath $pythonDynload -Filter '*.pyd' | ForEach-Object FullName)) {
        $queue.Enqueue($binary)
    }
    $seen = @{}
    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue()
        $imports = @(& $objdump -p $binary 2>$null | ForEach-Object {
            if ($_ -match 'DLL Name:\s*(\S+)') { $Matches[1] }
        })
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect native dependencies: $binary" }
        foreach ($name in $imports) {
            $key = $name.ToLowerInvariant()
            if ($key -like 'api-ms-win-*' -or $key -like 'ext-ms-win-*' -or
                (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$name"))) { continue }
            if ($seen.ContainsKey($key)) { continue }
            $dependency = $null
            foreach ($directory in $searchRoots) {
                $candidate = Join-Path $directory $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $dependency = $candidate; break }
            }
            if (!$dependency) { throw "Unresolved runtime dependency '$name' imported by $binary" }
            $seen[$key] = $true
            $sourceBuild = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'build\qemu')).TrimEnd('\') + '\'
            if (![IO.Path]::GetFullPath($dependency).StartsWith($sourceBuild, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $dependency -Destination $runtimeBin -Force
            }
            $queue.Enqueue($dependency)
        }
    }

    $operationalScripts = @(
        'environment.ps1','usb.ps1','prepare-opencore.ps1','prepare-vm.ps1',
        'start.ps1','stop.ps1','qmp.ps1'
    )
    foreach ($name in $operationalScripts) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $partial 'scripts\windows')
    }
    foreach ($name in @('New-VM.ps1','Start-VM.ps1','Stop-VM.ps1','Relocate-VM.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $partial
    }
    $ocTemplate = Join-Path $partial 'vm\firmware\opencore-1.0.8\root'
    Copy-TreeContents (Join-Path $ProjectRoot 'vm\firmware\opencore-1.0.8\root') $ocTemplate

    $pythonCode = @'
import pathlib, plistlib, sys, uuid
p = pathlib.Path(sys.argv[1])
c = plistlib.loads(p.read_bytes())
g = c["PlatformInfo"]["Generic"]
g.update(SystemSerialNumber="F00000000000", MLB="00000000000000000",
         SystemUUID=str(uuid.uuid4()).upper(), ROM=bytes.fromhex("025245494D53"))
p.write_bytes(plistlib.dumps(c, sort_keys=False))
'@
    $config = Join-Path $ocTemplate 'EFI\OC\config.plist'
    $pythonCode | & $python - $config
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare a clean OpenCore template.' }

    $readme = @'
Reims vGPU Windows VM runtime
=============================

This relocatable runtime bundle contains compiled Reims/QEMU files, runtime
libraries, QEMU data, OpenCore preparation files, OVMF firmware, Windows VM
scripts, and Tahoe network-Recovery media. It omits project source, build
toolchains, intermediate build files, and the source project's active VM disk.

The default VM has a fresh blank virtual disk; no macOS installation is
included. Recovery needs internet access. Normal starts require Windows
Hypervisor Platform (WHPX) and a compatible Vulkan GPU/driver. Boot and
graphics performance still need to be tested on the target host. Follow the
license supplied with the installer you use.

Run from PowerShell 7.2 or newer in this folder:

    .\Start-VM.ps1
    .\Start-VM.ps1 -WithoutInstaller
    .\Stop-VM.ps1 -Exit
    .\New-VM.ps1 -Name test -DiskGiB 256

The default blank VM is 128 GiB. New VMs have independent blank disks, NVRAM,
OpenCore configuration, machine identity and local ports. Start or stop a
named VM with -VMName test. Copy the whole folder to relocate it, and do not
move a VM while it is running. After moving the folder, the first start, stop,
or VM creation automatically updates saved paths and disk backing links.
'@
    $readme | Set-Content -LiteralPath (Join-Path $partial 'README.txt') -Encoding utf8NoBOM

    Set-Content -LiteralPath (Join-Path $partial '.work\portable-root.txt') -Value $partial -Encoding utf8NoBOM
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $partial
    $env:REIMS_VM_ROOT_OVERRIDE = Join-Path $partial 'vm'
    $env:REIMS_MSYS2_ROOT = Join-Path $partial 'runtime\msys2'
    $env:PYTHONHOME = Join-Path $env:REIMS_MSYS2_ROOT 'ucrt64'
    $env:PATH = (@((Join-Path $env:REIMS_MSYS2_ROOT 'ucrt64\bin'),(Join-Path $partial 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)
    $prepareOpenCore = Join-Path $partial 'scripts\windows\prepare-opencore.ps1'
    $prepareVm = Join-Path $partial 'scripts\windows\prepare-vm.ps1'
    $pswh = Join-Path $PSHOME 'pwsh.exe'
    $firmwareDirectory = Join-Path $partial 'runtime\msys2\ucrt64\share\qemu'
    & $pswh -NoProfile -ExecutionPolicy Bypass -File $prepareOpenCore -Version 1.0.8 -FirmwareDirectory $firmwareDirectory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'OpenCore preparation failed in the runtime bundle.' }
    & $pswh -NoProfile -ExecutionPolicy Bypass -File $prepareVm -Iso (Join-Path $partial 'vm\media\Tahoe-Recovery-GPT.img') `
        -DiskGiB $DiskGiB -QmpPort $QmpPort -SshPort $SshPort | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Blank VM preparation failed in the runtime bundle.' }
    & $pswh -NoProfile -ExecutionPolicy Bypass -File $prepareOpenCore -Version 1.0.8 `
        -FirmwareDirectory $firmwareDirectory -GenerateIdentity -Rebuild | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unique OpenCore identity generation failed in the runtime bundle.' }
    & $pswh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $partial 'Start-VM.ps1') -DryRun | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Packaged VM dry-run validation failed.' }
    & (Join-Path $partial 'build\qemu\qemu-system-x86_64.exe') -version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Packaged QEMU runtime could not start.' }

    Move-Item -LiteralPath $partial -Destination $Destination
    & $pswh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Destination 'Start-VM.ps1') -DryRun | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Relocated package dry-run validation failed.' }
    "Runtime package created at $Destination. The source project's active disk was not copied."
} finally {
    foreach ($variableName in $vars.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $vars[$variableName], 'Process')
    }
}
