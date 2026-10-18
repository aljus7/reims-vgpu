#Requires -Version 7.2
<#
.SYNOPSIS
  Installs the Reims macOS VM runtime into a folder you choose.
.DESCRIPTION
  Run it from the extracted release ZIP. It asks for a base folder (press Enter
  for the default), copies the runtime there, creates the VM folder structure
  and firmware, gives the VM its own OpenCore identity, builds the guest-tools
  disk and, if you give it a macOS Recovery image, prepares the default VM.
  Re-running it on an existing install updates the program files and keeps your
  VMs (vm\ and instances\).
.PARAMETER InstallPath
  Base folder. Default: %USERPROFILE%\ReimsVM
.PARAMETER RecoveryImage
  Optional macOS Recovery/installer image (raw GPT or APM image) to attach to the default VM.
.PARAMETER NoPrompt
  Never ask questions; use the defaults and the given parameters.
#>
[CmdletBinding()]
param(
    [string]$InstallPath,
    [string]$RecoveryImage,
    [switch]$NoPrompt,
    [switch]$NoShortcuts
)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($PSScriptRoot)
$defaultPath = Join-Path $env:USERPROFILE 'ReimsVM'

function Ask([string]$Question, [string]$Default) {
    if ($NoPrompt) { return $Default }
    $label = if ($Default) { "$Question [$Default]" } else { $Question }
    $answer = (Read-Host $label).Trim().Trim('"')
    if ($answer) { $answer } else { $Default }
}

foreach ($required in @('build\qemu\qemu-system-x86_64.exe', 'scripts\windows\prepare-opencore.ps1', 'runtime\msys2\ucrt64\bin\python.exe')) {
    if (!(Test-Path -LiteralPath (Join-Path $source $required))) {
        throw "This does not look like the extracted release ZIP (missing $required). Extract the whole ZIP first."
    }
}
if (!(Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Warning 'The Windows hypervisor is not running. Enable "Windows Hypervisor Platform" in Windows Features and restart before starting a VM.'
}

if (!$InstallPath) { $InstallPath = Ask 'Install folder' $defaultPath }
$target = [IO.Path]::GetFullPath($InstallPath)
if ($target.TrimEnd('\') -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) { throw 'Choose a folder, not a drive root.' }
$sameFolder = [string]::Equals($target.TrimEnd('\'), $source.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
if (!$sameFolder -and $target.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The install folder cannot be inside the extracted ZIP folder.'
}
$existing = Test-Path -LiteralPath (Join-Path $target 'vm\state\config.json')
if (!$sameFolder -and !$existing -and (Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)) {
    throw "The folder is not empty and holds no previous install: $target"
}
$drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($target).Substring(0, 1)) -ErrorAction SilentlyContinue
if ($drive -and $drive.Free -lt 40GB) { Write-Warning "Only $([math]::Round($drive.Free / 1GB)) GB free on that drive; macOS and its VM disk need about 40 GB or more." }

"Installing to $target"
if (!$sameFolder) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $arguments = @($source, $target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($existing) { $arguments += @('/XD', (Join-Path $source 'vm'), (Join-Path $source 'instances')) }
    & robocopy.exe @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy exit code $LASTEXITCODE)." }
}

$msys = Join-Path $target 'runtime\msys2'
$saved = @{}
foreach ($name in @('REIMS_PROJECT_ROOT_OVERRIDE', 'REIMS_VM_ROOT_OVERRIDE', 'REIMS_MSYS2_ROOT', 'PYTHONHOME', 'PATH')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$pwsh = Join-Path $PSHOME 'pwsh.exe'
function Invoke-Step([string]$Description, [string]$Script, [string[]]$ScriptArguments = @()) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $target $Script) @ScriptArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Description failed." }
}
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $target
    $env:REIMS_VM_ROOT_OVERRIDE = Join-Path $target 'vm'
    $env:REIMS_MSYS2_ROOT = $msys
    $env:PYTHONHOME = Join-Path $msys 'ucrt64'
    $env:PATH = (@((Join-Path $msys 'ucrt64\bin'), (Join-Path $target 'build\qemu'), $env:PATH) -join [IO.Path]::PathSeparator)

    if (Test-Path -LiteralPath (Join-Path $target '.work\portable-root.txt')) {
        Invoke-Step 'Updating saved paths' 'Relocate-VM.ps1'
    }
    $identity = Join-Path $target 'vm\state\opencore-identity.json'
    if (!(Test-Path -LiteralPath $identity)) {
        'Creating this VM''s own OpenCore identity and firmware...'
        Invoke-Step 'OpenCore preparation' 'scripts\windows\prepare-opencore.ps1' @(
            '-Version', '1.0.8', '-FirmwareDirectory', (Join-Path $msys 'ucrt64\share\qemu'), '-GenerateIdentity', '-Rebuild')
    }
    'Building the guest-tools disk...'
    Invoke-Step 'Guest-tools disk' 'scripts\windows\prepare-tools.ps1'

    $media = Join-Path $target 'vm\media\Tahoe-Recovery-GPT.img'
    if (!$RecoveryImage -and !(Test-Path -LiteralPath $media)) {
        $RecoveryImage = Ask 'macOS Recovery image to attach (blank to skip for now)' ''
    }
    if ($RecoveryImage) {
        $image = [IO.Path]::GetFullPath($RecoveryImage.Trim('"'))
        if (!(Test-Path -LiteralPath $image -PathType Leaf)) { throw "Recovery image not found: $image" }
        New-Item -ItemType Directory -Force -Path (Split-Path $media) | Out-Null
        if (![string]::Equals($image, $media, [StringComparison]::OrdinalIgnoreCase)) {
            'Copying the Recovery image...'
            Copy-Item -LiteralPath $image -Destination $media -Force
        }
        Invoke-Step 'Recovery image validation' 'scripts\windows\prepare-vm.ps1' @('-Iso', $media)
    }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}

$launcher = Join-Path $target 'ReimsLauncher.exe'
if (!$NoShortcuts -and (Test-Path -LiteralPath $launcher)) {
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Programs'))
    if ((Ask 'Add a desktop shortcut? (y/n)' 'y') -match '^[yY]') { $places += [Environment]::GetFolderPath('Desktop') }
    foreach ($place in $places) {
        $link = $shell.CreateShortcut((Join-Path $place 'Reims macOS VM Launcher.lnk'))
        $link.TargetPath = $launcher
        $link.WorkingDirectory = $target
        $link.Save()
    }
}

""
"Installed: $target"
if (Test-Path -LiteralPath (Join-Path $target 'vm\media\Tahoe-Recovery-GPT.img')) {
    'Next: open ReimsLauncher.exe (or run Start-VM.ps1) and install macOS. See docs\windows-manual.md.'
} else {
    'No Recovery image attached yet. Put one at vm\media\Tahoe-Recovery-GPT.img and run:'
    "  .\scripts\windows\prepare-vm.ps1 -Iso .\vm\media\Tahoe-Recovery-GPT.img   (from $target)"
}
'The Windows hypervisor, a Vulkan GPU and your own Recovery image are required; boot and speed must be tested on your PC.'
