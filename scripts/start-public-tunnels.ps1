param(
    [int]$PythonPort = 8001,
    [int]$PowerShellPort = 8002,
    [int]$GrafanaPort = 3000,
    [switch]$IncludeGrafana
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ".run"
$toolsDir = Join-Path $root ".tools"

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

$cloudflaredExe = Join-Path $toolsDir "cloudflared.exe"

if (-not (Test-Path $cloudflaredExe)) {
    Invoke-WebRequest `
        -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
        -OutFile $cloudflaredExe
}

function Start-Tunnel {
    param(
        [string]$Name,
        [string]$TargetUrl
    )

    $stdoutLog = Join-Path $runDir "$Name.out.log"
    $stderrLog = Join-Path $runDir "$Name.err.log"
    $pidFile = Join-Path $runDir "$Name.pid"
    $urlFile = Join-Path $runDir "$Name.url.txt"

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
            $TargetUrl,
            "--no-autoupdate"
        ) `
        -WorkingDirectory $root `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    Set-Content -Path $pidFile -Value $process.Id -Encoding ascii

    $deadline = (Get-Date).AddSeconds(120)
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
        throw "Nao foi possivel obter a URL publica do tunel $Name."
    }

    # Quick tunnel pode retornar 502 nos primeiros segundos; aguardamos estabilizar.
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
        Write-Host "Aviso: URL do tunel $Name ainda nao estabilizou, seguindo com retry na validacao: $publicUrl"
    }

    Set-Content -Path $urlFile -Value $publicUrl -Encoding ascii
    return $publicUrl
}

$pythonUrl = Start-Tunnel -Name "public-tunnel-python" -TargetUrl "http://127.0.0.1:$PythonPort"
$powershellUrl = Start-Tunnel -Name "public-tunnel-powershell" -TargetUrl "http://127.0.0.1:$PowerShellPort"

Write-Host "URL publica Python: $pythonUrl"
Write-Host "URL publica PowerShell: $powershellUrl"

if ($IncludeGrafana) {
    $grafanaUrl = Start-Tunnel -Name "public-tunnel-grafana" -TargetUrl "http://127.0.0.1:$GrafanaPort"
    Write-Host "URL publica Grafana: $grafanaUrl"
}
