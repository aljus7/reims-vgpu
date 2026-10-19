#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][Alias('Qemu')][string]$QemuExecutable)
. (Join-Path (Split-Path $PSScriptRoot) 'start.ps1') -FunctionsOnly
$Qemu = (Resolve-Path -LiteralPath $QemuExecutable).Path
if (Get-Process -Name 'qemu-system-x86_64' -ErrorAction SilentlyContinue) {
    throw 'Stop other VMs before running the WHPX accelerator smoke test.'
}
$directory = Join-Path $ProjectRoot ('.work\diagnostics\whpx-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $directory | Out-Null
$env:PATH = "$(Split-Path $Qemu);$ProjectRoot\build\qemu;$env:PATH"
foreach ($case in @(
    @{ name='defaults'; options='' },
    @{ name='disabled'; options=',exit-loop-budget-ms=0' },
    @{ name='enabled'; options=',exit-loop-budget-ms=5,pin-gpa=on,high-resolution-timer=on' }
)) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $stderr = Join-Path $directory "$($case.name).stderr.log"
    $arguments = @('-machine','q35','-accel',("whpx,hyperv=off" + $case.options),
        '-cpu','Haswell-noTSX','-m','512','-nodefaults','-display','none',
        '-S','-qmp',"tcp:127.0.0.1:$port,server=on,wait=off")
    $process = Start-Process -FilePath $Qemu -ArgumentList (($arguments |
        ForEach-Object { ConvertTo-ReimsWindowsArgument $_ }) -join ' ') -PassThru `
        -RedirectStandardError $stderr -RedirectStandardOutput (Join-Path $directory "$($case.name).stdout.log")
    $runtime = @{ pid=$process.Id; start_ticks=$process.StartTime.ToUniversalTime().Ticks;
                  executable=$Qemu; qmp_port=$port }
    try {
        Start-Sleep -Milliseconds 250
        $ready = $false
        for ($i=0; $i -lt 40; $i++) {
            if ($process.HasExited) { throw "Smoke VM exited: $(Get-Content $stderr -Raw)" }
            try {
                $status = Invoke-ReimsQmp $runtime 'query-status'
                $ready = $true
                break
            } catch [System.Net.Sockets.SocketException] {
                Start-Sleep -Milliseconds 250
            }
        }
        if (!$ready -or $status.running) { throw 'Smoke VM did not reach paused startup.' }
        Invoke-ReimsQmp $runtime 'cont' | Out-Null
        Start-Sleep -Milliseconds 500
        if (!(Invoke-ReimsQmp $runtime 'query-status').running) { throw 'WHPX guest could not run.' }
        Invoke-ReimsQmp $runtime 'stop' | Out-Null
        "PASS: $($case.name) accelerator properties, partition creation, run/pause."
    } finally {
        if (!$process.HasExited) {
            Invoke-ReimsQmp $runtime 'quit' | Out-Null
            if (!$process.WaitForExit(10000)) { throw "Smoke VM PID $($process.Id) did not exit." }
        }
        $process.Dispose()
    }
}
& $Qemu -machine q35 -accel whpx,exit-loop-budget-ms=1001 -display none -S 2> (Join-Path $directory 'invalid.stderr.log')
if ($LASTEXITCODE -eq 0 -or (Get-Content (Join-Path $directory 'invalid.stderr.log') -Raw) -notmatch 'must be 0 to 1000') {
    throw 'Invalid loop budget was not rejected.'
}
"PASS: invalid loop budget refused. Logs: $directory"
