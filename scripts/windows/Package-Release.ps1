#Requires -Version 7.2
# Builds the GitHub release ZIP from an existing build: launcher app, runtime,
# firmware and scripts, plus install.ps1. Apple Recovery media is never
# included. Needs the QEMU/Reims build (build.ps1), a prepared default VM
# (prepare-opencore.ps1 and prepare-vm.ps1) and the .NET 10 SDK.
[CmdletBinding()]
param(
    [string]$Version = (Get-Date -Format 'yyyy.MM.dd'),
    [string]$RecoveryImage,
    [string]$Destination
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (!$Destination) { $Destination = Join-Path $ProjectRoot "artifacts\reims-vgpu-windows-$Version.zip" }
$runtime = Join-Path $ProjectRoot '.work\release-runtime'
if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }

& (Join-Path $PSScriptRoot 'build-launcher.ps1')
$exportArguments = @{ Destination = $runtime }
if ($RecoveryImage) { $exportArguments.RecoveryImage = $RecoveryImage }
& (Join-Path $PSScriptRoot 'Export-Runtime.ps1') @exportArguments
try {
    & (Join-Path $PSScriptRoot 'Package-Runtime.ps1') -RuntimeRoot $runtime -Destination $Destination
} finally {
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
}
