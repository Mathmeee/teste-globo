param(
    [int]$PythonPort = 8001,
    [int]$PowerShellPort = 8002,
    [int]$ProxyPort = 8080,
    [switch]$SkipProxy
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ".run"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item $Path -Force
    }
}

function Save-Pid {
    param(
        [string]$Name,
        [int]$ProcessId
    )

    Set-Content -Path (Join-Path $runDir "$Name.pid") -Value $ProcessId -Encoding ascii
}

& (Join-Path $PSScriptRoot "stop-all.ps1") -Quiet
Start-Sleep -Milliseconds 500

$pythonOut = Join-Path $runDir "app-python.out.log"
$pythonErr = Join-Path $runDir "app-python.err.log"
$powershellOut = Join-Path $runDir "app-powershell.out.log"
$powershellErr = Join-Path $runDir "app-powershell.err.log"
$proxyOut = Join-Path $runDir "proxy.out.log"
$proxyErr = Join-Path $runDir "proxy.err.log"

@(
    $pythonOut,
    $pythonErr,
    $powershellOut,
    $powershellErr,
    $proxyOut,
    $proxyErr
) | ForEach-Object { Remove-IfExists $_ }

$pythonProcess = Start-Process `
    -FilePath "python" `
    -ArgumentList @("app-python/server.py", "--port", $PythonPort) `
    -WorkingDirectory $root `
    -RedirectStandardOutput $pythonOut `
    -RedirectStandardError $pythonErr `
    -PassThru

Save-Pid -Name "app-python" -ProcessId $pythonProcess.Id

$psExe = (Get-Command powershell -ErrorAction SilentlyContinue)
if (-not $psExe) {
    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
}
if (-not $psExe) {
    throw "Nao foi possivel localizar powershell ou pwsh no PATH."
}

$powershellProcess = Start-Process `
    -FilePath $psExe.Source `
    -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $root "app-powershell\server.ps1"),
        "-Port",
        $PowerShellPort
    ) `
    -WorkingDirectory $root `
    -RedirectStandardOutput $powershellOut `
    -RedirectStandardError $powershellErr `
    -PassThru

Save-Pid -Name "app-powershell" -ProcessId $powershellProcess.Id
Start-Sleep -Seconds 2
if ($powershellProcess.HasExited) {
    Write-Host "Processo PowerShell encerrou imediatamente."
    if (Test-Path $powershellErr) { Get-Content $powershellErr }
    if (Test-Path $powershellOut) { Get-Content $powershellOut }
    throw "Falha ao iniciar a aplicacao PowerShell."
}

if (-not $SkipProxy) {
    $proxyProcess = Start-Process `
        -FilePath "python" `
        -ArgumentList @(
            "proxy/server.py",
            "--port",
            $ProxyPort,
            "--python-backend-port",
            $PythonPort,
            "--powershell-backend-port",
            $PowerShellPort
        ) `
        -WorkingDirectory $root `
        -RedirectStandardOutput $proxyOut `
        -RedirectStandardError $proxyErr `
        -PassThru

    Save-Pid -Name "proxy" -ProcessId $proxyProcess.Id
}

try {
    $urls = @(
        "http://127.0.0.1:$PythonPort/",
        "http://127.0.0.1:$PowerShellPort/"
    )
    if (-not $SkipProxy) {
        $urls += "http://127.0.0.1:$ProxyPort/"
    }

    python (Join-Path $PSScriptRoot "wait_for_http.py") $urls --timeout 60
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao validar URLs locais."
    }
}
catch {
    Write-Host "Falha ao iniciar. Logs locais (se existirem):"
    @(
        $pythonOut,
        $pythonErr,
        $powershellOut,
        $powershellErr,
        $proxyOut,
        $proxyErr
    ) | ForEach-Object {
        if (Test-Path $_) {
            Write-Host "=== $_ ==="
            Get-Content $_
        }
    }
    & (Join-Path $PSScriptRoot "stop-all.ps1") -Quiet
    throw
}

$pythonDirectUrl = "http://localhost:$PythonPort"
$powershellDirectUrl = "http://localhost:$PowerShellPort"

if (-not $SkipProxy) {
    $proxyBaseUrl = "http://localhost:$ProxyPort"
    Set-Content -Path (Join-Path $runDir "proxy-base-url.txt") -Value $proxyBaseUrl -Encoding ascii
}

Write-Host ""
Write-Host "Infraestrutura iniciada com sucesso."
if (-not $SkipProxy) {
    Write-Host "Proxy local:"
    Write-Host "  $proxyBaseUrl/"
    Write-Host "  $proxyBaseUrl/python"
    Write-Host "  $proxyBaseUrl/python/time"
    Write-Host "  $proxyBaseUrl/powershell"
    Write-Host "  $proxyBaseUrl/powershell/time"
    Write-Host ""
}
Write-Host "Backends diretos:"
Write-Host "  Python: $pythonDirectUrl/"
Write-Host "  PowerShell: $powershellDirectUrl/"
Write-Host ""
Write-Host "Para encerrar, execute: .\\stop-all.ps1"
