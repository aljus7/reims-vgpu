#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$QemuExecutable)
. (Join-Path (Split-Path $PSScriptRoot) 'start.ps1') -FunctionsOnly
$executable = (Resolve-Path -LiteralPath $QemuExecutable).Path
if (Get-Process -Name 'qemu-system-x86_64' -ErrorAction SilentlyContinue) { throw 'Stop other VMs before testing WHPX topology.' }
$directory = Join-Path $ProjectRoot ('.work\diagnostics\cpu-topology-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $directory | Out-Null
$env:PATH = "$(Split-Path $executable);$env:PATH"
foreach ($case in @(
    @{cpus=1;cpu_threads=1}, @{cpus=3;cpu_threads=1},
    @{cpus=4;cpu_threads=2}, @{cpus=8;cpu_threads=1}, @{cpus=8;cpu_threads=2}
)) {
    $topology = Get-ReimsCpuTopology ([pscustomobject]$case)
    $name = "$($topology.cpus)-vcpu-$($topology.threads)-threads"
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $stderr = Join-Path $directory "$name.stderr.log"
    $arguments = @('-machine','q35','-accel','whpx,hyperv=off','-cpu','Haswell-noTSX',
        '-smp',$topology.argument,'-m','512','-nodefaults','-display','none','-S',
        '-qmp',"tcp:127.0.0.1:$port,server=on,wait=off")
    $process = Start-Process -FilePath $executable -ArgumentList (($arguments |
        ForEach-Object { ConvertTo-ReimsWindowsArgument $_ }) -join ' ') -PassThru `
        -RedirectStandardError $stderr -RedirectStandardOutput (Join-Path $directory "$name.stdout.log")
    $runtime = @{pid=$process.Id;start_ticks=$process.StartTime.ToUniversalTime().Ticks;executable=$executable;qmp_port=$port}
    try {
        Start-Sleep -Milliseconds 250
        $ready = $false
        for ($attempt=0; $attempt -lt 40; $attempt++) {
            if ($process.HasExited) { throw "Topology VM exited: $(Get-Content $stderr -Raw)" }
            try { Invoke-ReimsQmp $runtime 'query-status' | Out-Null; $ready=$true; break }
            catch [System.Net.Sockets.SocketException] { Start-Sleep -Milliseconds 250 }
        }
        if (!$ready) { throw 'Topology VM did not become ready.' }
        $cpus = Invoke-ReimsQmp $runtime 'query-cpus-fast'
        if ($cpus.Count -ne $topology.cpus) { throw "Wrong vCPU count: $name" }
        $ids = @{}
        foreach ($cpu in $cpus) {
            $props = $cpu.props
            $id = "$($props.'socket-id'):$($props.'core-id'):$($props.'thread-id')"
            if ($props.'socket-id' -ne 0 -or $props.'core-id' -ge $topology.cores -or
                $props.'thread-id' -ge $topology.threads -or $ids.ContainsKey($id)) {
                throw "Invalid or duplicate socket/core/thread identity: $name $id"
            }
            $ids[$id] = $true
        }
        Write-ReimsJson (Join-Path $directory "$name.json") $cpus
        Invoke-ReimsQmp $runtime 'cont' | Out-Null
        Start-Sleep -Milliseconds 250
        if (!(Invoke-ReimsQmp $runtime 'query-status').running) { throw "WHPX could not run: $name" }
        "PASS: $($topology.argument), unique topology IDs, WHPX partition runs."
    } finally {
        if (!$process.HasExited) {
            Invoke-ReimsQmp $runtime 'quit' | Out-Null
            if (!$process.WaitForExit(10000)) { throw "Topology VM PID $($process.Id) did not exit." }
        }
        $process.Dispose()
    }
}
"Topology evidence: $directory"
