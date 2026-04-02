param(
    [int]$ProxyPort = 8080
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ".run"
$toolsDir = Join-Path $root ".tools"

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

$cloudflaredExe = Join-Path $toolsDir "cloudflared.exe"
$stdoutLog = Join-Path $runDir "public-tunnel.out.log"
$stderrLog = Join-Path $runDir "public-tunnel.err.log"
$pidFile = Join-Path $runDir "public-tunnel.pid"
$urlFile = Join-Path $runDir "public-url.txt"

if (-not (Test-Path $cloudflaredExe)) {
    Invoke-WebRequest `
        -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
        -OutFile $cloudflaredExe
}

@($stdoutLog, $stderrLog, $pidFile, $urlFile) | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Force
    }
}

$process = Start-Process `
    -FilePath $cloudflaredExe `
    -ArgumentList @(
        "tunnel",
        "--url",
        "http://127.0.0.1:$ProxyPort",
        "--no-autoupdate"
    ) `
    -WorkingDirectory $root `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $pidFile -Value $process.Id -Encoding ascii

$deadline = (Get-Date).AddSeconds(90)
$publicUrl = $null

while ((Get-Date) -lt $deadline) {
    $content = ""
    if (Test-Path $stdoutLog) {
        $content += Get-Content $stdoutLog -Raw
    }
    if (Test-Path $stderrLog) {
        $content += "`n"
        $content += Get-Content $stderrLog -Raw
    }

    $match = [regex]::Match($content, "https://[-a-z0-9]+\.trycloudflare\.com")
    if ($match.Success) {
        $publicUrl = $match.Value
        break
    }

    Start-Sleep -Seconds 2
}

if (-not $publicUrl) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Nao foi possivel obter a URL publica do tunel."
}

$readyDeadline = (Get-Date).AddSeconds(90)
$isReady = $false
while ((Get-Date) -lt $readyDeadline) {
    try {
        $resp = Invoke-WebRequest -Uri "$publicUrl/" -UseBasicParsing -TimeoutSec 10
        if ($resp.StatusCode -lt 500) {
            $isReady = $true
            break
        }
    }
    catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            if ($code -lt 500) {
                $isReady = $true
                break
            }
        }
    }
    Start-Sleep -Seconds 3
}

if (-not $isReady) {
    Write-Host "Aviso: URL do tunel ainda nao estabilizou, seguindo com retry na validacao: $publicUrl"
}

Set-Content -Path $urlFile -Value $publicUrl -Encoding ascii

Write-Host "URL publica pronta: $publicUrl"
