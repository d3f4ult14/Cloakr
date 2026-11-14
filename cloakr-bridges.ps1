# Cloakr helper: load Tor's built-in obfs4 bridges, test which ones answer
# from this network, and save the fastest ones to bridges.txt.
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Top = 5
)

$ErrorActionPreference = 'Stop'

# 1. Find pt_config.json shipped inside the Tor Expert Bundle
$cfg = Join-Path $Base 'tor\pluggable_transports\pt_config.json'
if (-not (Test-Path $cfg)) {
    $found = Get-ChildItem -Path $Base -Recurse -Filter 'pt_config.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $cfg = $found.FullName }
}
if (-not (Test-Path $cfg)) {
    Write-Host '[!] pt_config.json not found. It ships with the Tor Expert Bundle'
    Write-Host '    (usually tor\pluggable_transports\pt_config.json). Re-download the bundle.'
    exit 2
}
Write-Host "[*] Reading built-in bridges from: $cfg"

try {
    $json = Get-Content -Path $cfg -Raw | ConvertFrom-Json
    $lines = @($json.bridges.obfs4)
} catch {
    Write-Host '[!] Could not read the obfs4 bridge list from pt_config.json.'
    exit 2
}

# 2. Keep IPv4 obfs4 lines only
$cands = @()
foreach ($l in $lines) {
    if ($l -match '^obfs4\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d+)\s') {
        $cands += [pscustomobject]@{ Line = $l.Trim(); Ip = $Matches[1]; Port = [int]$Matches[2] }
    }
}
if ($cands.Count -eq 0) {
    Write-Host '[!] No usable IPv4 obfs4 bridges in the built-in list.'
    exit 2
}
Write-Host "[*] Testing $($cands.Count) built-in bridges (3 second limit)..."

# 3. Connect to all at once and time each one
$jobs = @()
foreach ($b in $cands) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $iar = $c.BeginConnect($b.Ip, $b.Port, $null, $null)
    $jobs += [pscustomobject]@{ B = $b; C = $c; I = $iar; SW = $sw; Done = $false; Ok = $false; Ms = 99999 }
}
$deadline = [DateTime]::UtcNow.AddSeconds(3)
while ([DateTime]::UtcNow -lt $deadline -and (@($jobs | Where-Object { -not $_.Done }).Count -gt 0)) {
    foreach ($j in $jobs) {
        if (-not $j.Done -and $j.I.IsCompleted) {
            $j.Done = $true
            $j.Ms = [int]$j.SW.ElapsedMilliseconds
            try { $j.C.EndConnect($j.I); $j.Ok = $true } catch { $j.Ok = $false }
        }
    }
    Start-Sleep -Milliseconds 10
}
foreach ($j in $jobs) { try { $j.C.Close() } catch {} }

# 4. Report
$good = @($jobs | Where-Object { $_.Ok } | Sort-Object Ms)
foreach ($j in ($jobs | Sort-Object Ms)) {
    $addr = '{0}:{1}' -f $j.B.Ip, $j.B.Port
    if ($j.Ok) { Write-Host ('    {0,-22} {1,5} ms' -f $addr, $j.Ms) }
    else       { Write-Host ('    {0,-22} unreachable' -f $addr) }
}
if ($good.Count -eq 0) {
    Write-Host '[!] None of the built-in bridges answered from this network.'
    Write-Host '    They may be down or blocked. Get fresh ones from https://bridges.torproject.org'
    exit 1
}

# 5. Save the fastest ones (skip duplicates already in bridges.txt)
$existing = @()
if (Test-Path $Out) { $existing = @(Get-Content -Path $Out | ForEach-Object { $_.Trim() }) }
$added = 0
foreach ($j in ($good | Select-Object -First $Top)) {
    if ($existing -notcontains $j.B.Line) {
        Add-Content -Path $Out -Value $j.B.Line
        $added++
    }
}
Write-Host "[+] Saved $added new bridge(s) to bridges.txt (fastest $Top reachable)."
exit 0
