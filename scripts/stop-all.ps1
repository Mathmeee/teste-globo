param(
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"

$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ".run"

if (-not (Test-Path $runDir)) {
    return
}

$pidFiles = @(
    "public-tunnel.pid",
    "public-tunnel-python.pid",
    "public-tunnel-powershell.pid",
    "public-tunnel-grafana.pid",
    "proxy.pid",
    "grafana.pid",
    "app-powershell.pid",
    "app-python.pid"
)

foreach ($pidFile in $pidFiles) {
    $pidPath = Join-Path $runDir $pidFile
    if (-not (Test-Path $pidPath)) {
        continue
    }

    $pidValue = Get-Content $pidPath -Raw
    if ($pidValue) {
        Stop-Process -Id ([int]$pidValue) -Force
    }

    Remove-Item $pidPath -Force
}

Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -like "grafana*" -and
        $_.Path -and
        $_.Path.StartsWith((Join-Path $root ".tools\\grafana"), [System.StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object {
        Stop-Process -Id $_.Id -Force
    }

if (-not $Quiet) {
    Write-Host "Infraestrutura encerrada."
}
