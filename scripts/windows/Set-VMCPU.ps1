#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^(Default|[A-Za-z0-9][A-Za-z0-9_-]{0,31})$')][string]$VMName = 'Default',
    [Parameter(Mandatory)][ValidateRange(1,64)][int]$Cpus,
    [ValidateSet(1,2)][int]$ThreadsPerCore = 1
)
$ErrorActionPreference = 'Stop'
$root = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$savedProject = $env:REIMS_PROJECT_ROOT_OVERRIDE
$savedVm = $env:REIMS_VM_ROOT_OVERRIDE
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $root
    $env:REIMS_VM_ROOT_OVERRIDE = if ($VMName -eq 'Default') { Join-Path $root 'vm' } else { Join-Path $root "instances\$VMName" }
    . (Join-Path $root 'scripts\windows\start.ps1') -FunctionsOnly
    Assert-ReimsVmStopped
    $topology = Get-ReimsCpuTopology ([pscustomobject]@{cpus=$Cpus;cpu_threads=$ThreadsPerCore})
    if ($Cpus -gt [Environment]::ProcessorCount) { throw 'CPU count exceeds the host logical processor count.' }
    $config = Get-ReimsVmConfig
    $config.cpus = $Cpus
    $config | Add-Member -Force cpu_threads $ThreadsPerCore
    Write-ReimsJson (Join-Path $VmRoot 'state\config.json') $config
    "Saved '$VMName': $Cpus vCPUs, 1 socket, $($topology.cores) cores, $ThreadsPerCore thread(s) per core. Applies at next QEMU launch."
} finally {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $savedProject
    $env:REIMS_VM_ROOT_OVERRIDE = $savedVm
}
