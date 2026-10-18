#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProjectRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$marker = Join-Path $ProjectRoot '.work\portable-root.txt'
if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { return }
$oldRoot = [IO.Path]::GetFullPath((Get-Content -Raw -LiteralPath $marker).Trim())
if ([string]::Equals($oldRoot.TrimEnd('\','/'), $ProjectRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) {
    return
}
$msysRoot = if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\msys2\ucrt64\bin\python.exe')) {
    Join-Path $ProjectRoot 'runtime\msys2'
} elseif ($env:REIMS_MSYS2_ROOT) { $env:REIMS_MSYS2_ROOT } else { 'D:\msys64' }
$saved = @{}
foreach ($variableName in @('REIMS_PROJECT_ROOT_OVERRIDE','REIMS_VM_ROOT_OVERRIDE','REIMS_MSYS2_ROOT','PATH')) {
    $saved[$variableName] = [Environment]::GetEnvironmentVariable($variableName, 'Process')
}
try {
    $env:REIMS_PROJECT_ROOT_OVERRIDE = $ProjectRoot
    $env:REIMS_MSYS2_ROOT = $msysRoot
    $env:PATH = (@((Join-Path $msysRoot 'ucrt64\bin'),(Join-Path $ProjectRoot 'build\qemu'),$env:PATH) -join [IO.Path]::PathSeparator)
    $scriptsRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'start.ps1')) {
        $PSScriptRoot
    } else {
        Join-Path $ProjectRoot 'scripts\windows'
    }
    . (Join-Path $scriptsRoot 'start.ps1') -FunctionsOnly

    $vmRoots = @((Join-Path $ProjectRoot 'vm'))
    $instances = Join-Path $ProjectRoot 'instances'
    if (Test-Path -LiteralPath $instances -PathType Container) {
        $vmRoots += @(Get-ChildItem -LiteralPath $instances -Directory | ForEach-Object FullName)
    }
    $oldBackslash = $oldRoot.TrimEnd('\','/') + '\'
    $newBackslash = $ProjectRoot.TrimEnd('\','/') + '\'
    $oldEscaped = $oldBackslash.Replace('\','\\')
    $newEscaped = $newBackslash.Replace('\','\\')
    $oldForward = $oldRoot.TrimEnd('\','/') + '/'
    $newForward = $ProjectRoot.TrimEnd('\','/') + '/'
    foreach ($vmRoot in $vmRoots) {
        $state = Join-Path $vmRoot 'state'
        $configPath = Join-Path $state 'config.json'
        if (!(Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }

        $runtimePath = Join-Path $state 'runtime.json'
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
            $process = Get-Process -Id $runtime.pid -ErrorAction SilentlyContinue
            if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$runtime.start_ticks -and
                [string]::Equals($process.Path, $runtime.executable, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Stop the running VM before relocating its folder: $vmRoot"
            }
        }

        foreach ($file in Get-ChildItem -LiteralPath $state -File -Filter '*.json') {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text = $text.Replace($oldEscaped, $newEscaped, [StringComparison]::OrdinalIgnoreCase)
            $text = $text.Replace($oldForward, $newForward, [StringComparison]::OrdinalIgnoreCase)
            [IO.File]::WriteAllText($file.FullName, $text, [Text.UTF8Encoding]::new($false))
        }

        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $activeDisk = [IO.Path]::GetFullPath($config.active_disk)
        $vmPrefix = $vmRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (!$activeDisk.StartsWith($vmPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Active disk is outside its VM folder: $activeDisk"
        }
        if (!(Test-Path -LiteralPath $activeDisk -PathType Leaf)) { throw "Active disk is missing: $activeDisk" }
        $qemuImg = Get-ReimsTool 'qemu-img.exe'
        $disk = $activeDisk
        for ($depth = 0; $depth -lt 32; $depth++) {
            $info = ((Invoke-ReimsTool $qemuImg @('info','--output=json',$disk)) -join "`n") | ConvertFrom-Json
            $backingProperty = $info.PSObject.Properties['backing-filename']
            $backing = if ($backingProperty) { [string]$backingProperty.Value } else { $null }
            if ([string]::IsNullOrWhiteSpace($backing)) { break }
            $parent = if ([IO.Path]::IsPathRooted($backing)) {
                [IO.Path]::GetFullPath($backing)
            } else {
                [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $disk) $backing))
            }
            if ([IO.Path]::IsPathRooted($backing) -and
                $parent.StartsWith($oldBackslash.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $parent.Substring($oldRoot.TrimEnd('\','/').Length).TrimStart('\','/')
                $newParent = Join-Path $ProjectRoot $relative
                if (!(Test-Path -LiteralPath $newParent -PathType Leaf)) { throw "Moved backing image is missing: $newParent" }
                Invoke-ReimsTool $qemuImg @('rebase','-u','-f','qcow2','-F','qcow2','-b',$newParent,$disk) | Out-Null
                $parent = $newParent
            }
            if (!(Test-Path -LiteralPath $parent -PathType Leaf)) { throw "QCOW2 backing image is missing: $parent" }
            $disk = $parent
            if ($depth -eq 31) { throw 'QCOW2 backing chain exceeds the relocation safety limit.' }
        }
    }
    Set-Content -LiteralPath $marker -Value $ProjectRoot -Encoding utf8NoBOM
    "Updated package-local state and QCOW2 backing paths for $ProjectRoot."
} finally {
    foreach ($variableName in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $saved[$variableName], 'Process')
    }
}
