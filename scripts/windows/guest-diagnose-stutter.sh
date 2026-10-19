#!/bin/sh
# Run as your normal user while reproducing a stall; no settings are changed.
set -eu

usage() {
    echo "Usage: sh $0 [seconds: 5-300, default 60]"
}

if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -gt 1 ]; then
    usage >&2
    exit 1
fi
seconds=${1:-60}
case "$seconds" in
    ''|*[!0-9]*|0*|????*)
        usage >&2
        exit 1
        ;;
esac
if [ "$seconds" -lt 5 ] || [ "$seconds" -gt 300 ]; then
    usage >&2
    exit 1
fi
if [ "$(uname -s)" != Darwin ]; then
    echo "This diagnostic must run inside the macOS guest." >&2
    exit 1
fi

umask 077
report=$(mktemp -d "${TMPDIR:-/tmp}/reims-stutter.XXXXXX")
trap 'status=$?; if [ "$status" -ne 0 ]; then echo "Diagnostic failed; partial report: $report" >&2; fi' 0
echo "Recording to $report"
echo "Reproduce the problem now. Sampling adds CPU overhead; do not use it in a clean timing comparison."
{
    echo "Reims guest stutter diagnostic (read-only)"
    date -u '+Start UTC: %Y-%m-%dT%H:%M:%SZ'
    date '+Guest local time: %Y-%m-%d %H:%M:%S %z'
    echo "Requested top samples: $seconds (first CPU sample is not an interval measurement)"
    sysctl kern.osproductversion kern.osrelease hw.ncpu hw.memsize
    echo
    echo "Power settings (automatic guest sleep is unsupported on Windows/WHPX):"
    pmset -g custom
    echo
    echo "Virtual memory before:"
    vm_stat
} > "$report/system.txt" 2>&1

top -l "$seconds" -s 1 -n 20 -o cpu \
    -stats pid,command,cpu,mem,threads,state > "$report/processes.txt" 2>&1
{
    echo
    echo "Virtual memory after:"
    vm_stat
    date -u '+End UTC: %Y-%m-%dT%H:%M:%SZ'
} >> "$report/system.txt" 2>&1

echo "Complete: $report"
echo "Compare timestamps with the host benchmark. This report does not identify GPU waits by itself."
echo "Review process names before sharing; no report is uploaded automatically."
