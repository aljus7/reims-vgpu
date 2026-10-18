#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$')][string]$Name,
    [ValidateRange(64,2048)][int]$DiskGiB = 128,
    [switch]$Start
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$instanceRoot = Join-Path $ProjectRoot "instances\$Name"
if (Test-Path -LiteralPath $instanceRoot) { throw "VM folder already exists; refusing to overwrite it: $instanceRoot" }
$templateRoot = Join-Path $ProjectRoot 'vm\firmware\opencore-1.0.8\root'
if (!(Test-Path -LiteralPath (Join-Path $templateRoot 'EFI\OC\config.plist'))) {
    throw 'Prepare the default VM first; its OpenCore configuration is the safe template.'
}
$relocationMarker = Join-Path $ProjectRoot '.work\portable-root.txt'
if (Test-Path -LiteralPath $relocationMarker) {
    & (Join-Path $ProjectRoot 'Relocate-VM.ps1')
}
$recovery = Join-Path $ProjectRoot 'vm\media\Tahoe-Recovery-GPT.img'
if (!(Test-Path -LiteralPath $recovery -PathType Leaf)) { throw "Recovery media is missing: $recovery" }
$msysRoot = if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\msys2\ucrt64\bin\python.exe')) {
    Join-Path $ProjectRoot 'runtime\msys2'
} elseif ($env:REIMS_MSYS2_ROOT) { $env:REIMS_MSYS2_ROOT } else { 'D:\msys64' }
$vars = @{}
foreach ($variableName in @('REIMS_PROJECT_ROOT_OVERRIDE','REIMS_VM_ROOT_OVERRIDE','REIMS_MSYS2_ROOT','PYTHONHOME','PATH')) {
    $vars[$variableName] = [Environment]::GetEnvironmentVariable($variableName, 'Process')
}
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $ProjectRoot
    $env:REIMS_VM_ROOT_OVERRIDE = $instanceRoot
    $env:REIMS_MSYS2_ROOT = $msysRoot
    $pythonHome = Join-Path $msysRoot 'ucrt64'
    if (Test-Path -LiteralPath (Join-Path $pythonHome 'lib\python3.14')) { $env:PYTHONHOME = $pythonHome }
    $env:PATH = (@((Join-Path $msysRoot 'ucrt64\bin'),(Join-Path $ProjectRoot 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)

    $qmpPort = 4444
    $sshPort = 2222
    $portsFound = $false
    for ($offset = 0; $offset -lt 2000; $offset++) {
        $candidateQmp = 4444 + $offset
        $candidateSsh = 2222 + $offset
        $listeners = @()
        $available = $true
        foreach ($port in @($candidateQmp,$candidateSsh)) {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            try { $listener.Start(); $listeners += $listener } catch { $available = $false }
        }
        foreach ($listener in $listeners) { $listener.Stop() }
        if ($available) { $qmpPort = $candidateQmp; $sshPort = $candidateSsh; $portsFound = $true; break }
    }
    if (!$portsFound) { throw 'Could not find two free local VM ports.' }

    New-Item -ItemType Directory -Path $instanceRoot | Out-Null
    $ocRoot = Join-Path $instanceRoot 'firmware\opencore-1.0.8\root'
    New-Item -ItemType Directory -Force -Path $ocRoot | Out-Null
    Get-ChildItem -LiteralPath $templateRoot -Force | Copy-Item -Destination $ocRoot -Recurse -Force
    $python = Join-Path $msysRoot 'ucrt64\bin\python.exe'
    $identityReset = @'
import pathlib, plistlib, sys, uuid
p = pathlib.Path(sys.argv[1])
c = plistlib.loads(p.read_bytes())
c["PlatformInfo"]["Generic"].update(SystemSerialNumber="F00000000000",
    MLB="00000000000000000", SystemUUID=str(uuid.uuid4()).upper(),
    ROM=bytes.fromhex("025245494D53"))
p.write_bytes(plistlib.dumps(c, sort_keys=False))
'@
    $config = Join-Path $ocRoot 'EFI\OC\config.plist'
    $identityReset | & $python - $config
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize a unique VM identity.' }
    $firmwareDirectory = Join-Path $msysRoot 'ucrt64\share\qemu'
    $scripts = Join-Path $ProjectRoot 'scripts\windows'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $opencore = Join-Path $scripts 'prepare-opencore.ps1'
    $prepareVm = Join-Path $scripts 'prepare-vm.ps1'

    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $opencore -Version 1.0.8 -FirmwareDirectory $firmwareDirectory
    if ($LASTEXITCODE -ne 0) { throw 'OpenCore preparation failed.' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $prepareVm -Iso $recovery -DiskGiB $DiskGiB -QmpPort $qmpPort -SshPort $sshPort
    if ($LASTEXITCODE -ne 0) { throw 'Blank VM disk and configuration preparation failed.' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $opencore -Version 1.0.8 -FirmwareDirectory $firmwareDirectory -GenerateIdentity -Rebuild
    if ($LASTEXITCODE -ne 0) { throw 'Unique OpenCore identity generation failed.' }
    "Created '$Name' with a fresh blank $DiskGiB GiB virtual disk. The source VM disk was not copied."
    if ($Start) {
        & (Join-Path $ProjectRoot 'Start-VM.ps1') -VMName $Name
        if ($LASTEXITCODE -ne 0) { throw 'VM creation succeeded but starting it failed.' }
    }
} finally {
    foreach ($variableName in $vars.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $vars[$variableName], 'Process')
    }
}
