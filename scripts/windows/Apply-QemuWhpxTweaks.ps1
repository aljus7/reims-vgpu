#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$QemuSource)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $QemuSource).Path
$patch = Join-Path $PSScriptRoot 'patches\qemu-whpx-frame-pacing.patch'
$root = & git -C $source rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($root) -ne $source) {
    throw "QemuSource must be an initialized QEMU git checkout: $source"
}
& git -C $source apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -eq 0) {
    'WHPX frame-pacing patch is already applied.'
    return
}
& git -C $source apply --check $patch
if ($LASTEXITCODE -ne 0) {
    throw 'WHPX patch does not match this QEMU source. No changes were applied.'
}
& git -C $source apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Applying the WHPX patch failed.' }
'Applied experimental WHPX frame-pacing patch.'
