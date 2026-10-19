#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$')][string]$VMName
)
$ErrorActionPreference = 'Stop'
if ($VMName -eq 'Default') { throw 'The Default VM cannot be deleted.' }
$root = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$instances = Join-Path $root 'instances'
$target = [IO.Path]::GetFullPath((Join-Path $instances $VMName))
foreach ($path in @($instances, $target)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (!$item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to delete a linked or invalid VM folder: $path"
    }
}
if (!(Test-Path -LiteralPath (Join-Path $target 'state\config.json') -PathType Leaf)) { throw 'The selected folder is not a prepared VM.' }
if (Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
    Select-Object -First 1) { throw 'Refusing to delete a VM containing linked files or folders.' }
$savedProject = $env:REIMS_PROJECT_ROOT_OVERRIDE
$savedVm = $env:REIMS_VM_ROOT_OVERRIDE
$approved = $PSCmdlet.ShouldProcess($target, 'Permanently delete this VM and all files in its folder, including its disks')
if (!$approved) { return }
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $root
    $env:REIMS_VM_ROOT_OVERRIDE = $target
    . (Join-Path $root 'scripts\windows\start.ps1') -FunctionsOnly
    [void](Get-ReimsVmConfig)
    Assert-ReimsVmStopped
    $qemuImg = Get-ReimsTool 'qemu-img.exe'
    $otherConfigs = @((Join-Path $root 'vm\state\config.json'))
    $otherConfigs += @(Get-ChildItem -LiteralPath $instances -Directory -Force |
        Where-Object { $_.FullName -ne $target } |
        ForEach-Object { Join-Path $_.FullName 'state\config.json' })
    $prefix = $target.TrimEnd('\') + '\'
    foreach ($file in $otherConfigs) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $other = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
        foreach ($key in @('active_disk','base_disk','opencore','firmware_code','firmware_vars','rom','iso')) {
            if ($other.PSObject.Properties[$key] -and $other.$key -and
                [IO.Path]::GetFullPath($other.$key).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Another VM references files in this folder: $file"
            }
        }
        if (Test-Path -LiteralPath $other.active_disk -PathType Leaf) {
            $chain = (Invoke-ReimsTool $qemuImg @('info','--force-share','--backing-chain','--output=json',$other.active_disk)) -join "`n" | ConvertFrom-Json
            foreach ($disk in $chain) {
                if ([IO.Path]::GetFullPath($disk.filename).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Another VM's backing chain depends on this VM: $file"
                }
            }
        }
    }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    "Deleted '$VMName' and its VM folder: $target"
} finally {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $savedProject
    $env:REIMS_VM_ROOT_OVERRIDE = $savedVm
}
