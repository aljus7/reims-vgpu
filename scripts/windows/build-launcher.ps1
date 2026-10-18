#Requires -Version 7.2
# Builds the VM launcher app (apps\vm-launcher) into build\launcher\ReimsLauncher.exe.
# Needs the .NET 10 SDK to build. The result is a self-contained single file, so
# the machine that runs it needs no .NET install. The app finds the project by
# walking up from its own folder, so keep it inside the repository or the
# installed runtime folder.
[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (!$Output) { $Output = Join-Path $ProjectRoot 'build\launcher' }
if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'The .NET 10 SDK is required: winget install Microsoft.DotNet.SDK.10' }
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Recurse -Force }
dotnet publish (Join-Path $ProjectRoot 'apps\vm-launcher\ReimsLauncher.csproj') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o $Output --nologo
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
"Built: $(Join-Path $Output 'ReimsLauncher.exe')"