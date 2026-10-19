#Requires -Version 7.2
# Prints every VM (the default one and instances\*) as a JSON array for the launcher app.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\cpu.ps1"
$ProjectRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.work\downloads')) {
    [IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$roots = [ordered]@{}
if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'vm\state\config.json')) { $roots['Default'] = Join-Path $ProjectRoot 'vm' }
$instances = Join-Path $ProjectRoot 'instances'
if (Test-Path -LiteralPath $instances) {
    foreach ($directory in Get-ChildItem -LiteralPath $instances -Directory | Sort-Object Name) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'state\config.json')) { $roots[$directory.Name] = $directory.FullName }
    }
}
$result = foreach ($name in $roots.Keys) {
    $config = Get-Content -Raw -LiteralPath (Join-Path $roots[$name] 'state\config.json') | ConvertFrom-Json
    $running = $false
    $runtimePath = Join-Path $roots[$name] 'state\runtime.json'
    if (Test-Path -LiteralPath $runtimePath) {
        $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
        $process = Get-Process -Id $runtime.pid -ErrorAction SilentlyContinue
        $running = $process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$runtime.start_ticks
    }
    $topology = Get-ReimsCpuTopology $config
    [pscustomobject]@{ name = $name; cpus = $topology.cpus; cpu_cores = $topology.cores; cpu_threads = $topology.threads; memory_mib = $config.memory_mib; disk_gib = $config.disk_gib; running = [bool]$running }
}
ConvertTo-Json -InputObject @($result) -Compress
