function Get-ReimsCpuTopology($Config) {
    if ([string]$Config.cpus -notmatch '^\d+$' -or [long]$Config.cpus -lt 1 -or [long]$Config.cpus -gt 64) {
        throw 'CPU count must be an integer from 1 to 64 (total vCPUs).'
    }
    $threads = if ($Config.PSObject.Properties['cpu_threads']) { $Config.cpu_threads } else { 1 }
    if ([string]$threads -notmatch '^[12]$') { throw 'Threads per core must be 1 or 2.' }
    $cpus = [int]$Config.cpus
    $threads = [int]$threads
    if ($cpus % $threads -ne 0) { throw 'Total vCPUs must be divisible by threads per core; SMT requires an even CPU count.' }
    $cores = [int]($cpus / $threads)
    [pscustomobject]@{
        cpus = $cpus; sockets = 1; cores = $cores; threads = $threads
        argument = "$cpus,sockets=1,cores=$cores,threads=$threads"
    }
}
