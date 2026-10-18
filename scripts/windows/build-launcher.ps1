#Requires -Version 7.2
# Builds the VM launcher app (apps\vm-launcher) into build\launcher\ReimsLauncher.exe.
# Needs the .NET 10 SDK. The app finds the project by walking up from its own folder,
# so keep it inside the repository (or the exported runtime folder).
[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (!$Output) { $Output = Join-Path $ProjectRoot 'build\launcher' }
if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'The .NET 10 SDK is required: https://dotnet.microsoft.com/download' }
dotnet publish (Join-Path $ProjectRoot 'apps\vm-launcher\ReimsLauncher.csproj') -c Release -o $Output --nologo
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
"Built: $(Join-Path $Output 'ReimsLauncher.exe')"
