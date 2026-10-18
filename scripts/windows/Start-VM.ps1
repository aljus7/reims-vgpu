#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^(Default|[A-Za-z0-9][A-Za-z0-9_-]{0,31})$')][string]$VMName = 'Default',
    [switch]$WithoutInstaller,
    [switch]$DryRun,
    [switch]$Paused,
    [switch]$Headless,
    [switch]$DiagnosticTcg
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$VmRoot = if ($VMName -eq 'Default') { Join-Path $ProjectRoot 'vm' } else { Join-Path $ProjectRoot "instances\$VMName" }
if (!(Test-Path -LiteralPath (Join-Path $VmRoot 'state\config.json'))) { throw "VM is not prepared: $VmRoot" }
$msysRoot = if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\msys2\ucrt64\bin\python.exe')) {
    Join-Path $ProjectRoot 'runtime\msys2'
} elseif ($env:REIMS_MSYS2_ROOT) { $env:REIMS_MSYS2_ROOT } else { 'D:\msys64' }
$saved = @{}
foreach ($variableName in @('REIMS_PROJECT_ROOT_OVERRIDE','REIMS_VM_ROOT_OVERRIDE','REIMS_MSYS2_ROOT','PYTHONHOME','PATH')) {
    $saved[$variableName] = [Environment]::GetEnvironmentVariable($variableName, 'Process')
}
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $ProjectRoot
    $env:REIMS_VM_ROOT_OVERRIDE = $VmRoot
    $env:REIMS_MSYS2_ROOT = $msysRoot
    $pythonHome = Join-Path $msysRoot 'ucrt64'
    if (Test-Path -LiteralPath (Join-Path $pythonHome 'lib\python3.14')) { $env:PYTHONHOME = $pythonHome }
    $env:PATH = (@((Join-Path $msysRoot 'ucrt64\bin'),(Join-Path $ProjectRoot 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)
    $relocationMarker = Join-Path $ProjectRoot '.work\portable-root.txt'
    if (Test-Path -LiteralPath $relocationMarker) {
        & (Join-Path $ProjectRoot 'Relocate-VM.ps1')
    }
    $startParameters = @{}
    if ($WithoutInstaller) { $startParameters.WithoutInstaller = $true }
    if ($DryRun) { $startParameters.DryRun = $true }
    if ($Paused) { $startParameters.Paused = $true }
    if ($Headless) { $startParameters.Headless = $true }
    if ($DiagnosticTcg) { $startParameters.DiagnosticTcg = $true }
    & (Join-Path $ProjectRoot 'scripts\windows\start.ps1') @startParameters
} finally {
    foreach ($variableName in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $saved[$variableName], 'Process')
    }
}
