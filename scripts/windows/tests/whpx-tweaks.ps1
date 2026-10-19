#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$QemuSource)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot))
$test = Join-Path $root ('.work\tmp\whpx-patch-test-' + [guid]::NewGuid())
$apply = Join-Path (Split-Path $PSScriptRoot) 'Apply-QemuWhpxTweaks.ps1'
$files = @('accel/whpx/whpx-common.c', 'include/system/whpx-internal.h',
           'target/i386/whpx/whpx-all.c')
New-Item -ItemType Directory $test | Out-Null
try {
    & git -C $test init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize test checkout.' }
    foreach ($file in $files) {
        $content = & git -C $QemuSource show "HEAD:$file"
        if ($LASTEXITCODE -ne 0) { throw "Could not read pinned source: $file" }
        $path = Join-Path $test $file
        New-Item -ItemType Directory (Split-Path $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, ($content -join "`n") + "`n")
    }
    & $apply -QemuSource $test
    $first = @($files | ForEach-Object { (Get-FileHash (Join-Path $test $_)).Hash })
    & $apply -QemuSource $test
    $second = @($files | ForEach-Object { (Get-FileHash (Join-Path $test $_)).Hash })
    if (($first -join ',') -ne ($second -join ',')) { throw 'Repeated application changed files.' }
    $patch = Join-Path (Split-Path $PSScriptRoot) 'patches\qemu-whpx-frame-pacing.patch'
    & git -C $test apply --reverse $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch could not be reversed.' }
    [IO.File]::WriteAllText((Join-Path $test $files[0]), 'incompatible source')
    $before = @($files | ForEach-Object { (Get-FileHash (Join-Path $test $_)).Hash })
    $refused = $false
    try { & $apply -QemuSource $test } catch {
        if ($_.Exception.Message -notmatch 'does not match') { throw }
        $refused = $true
    }
    if (!$refused) { throw 'Incompatible source was accepted.' }
    $after = @($files | ForEach-Object { (Get-FileHash (Join-Path $test $_)).Hash })
    if (($before -join ',') -ne ($after -join ',')) { throw 'Incompatible source was partially modified.' }
    'PASS: fresh application, idempotence, reversal and atomic refusal of incompatible QEMU source.'
} finally {
    Remove-Item -LiteralPath $test -Recurse -Force
}
