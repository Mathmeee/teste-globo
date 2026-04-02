param(
    [int]$GrafanaPort = 3000,
    [string]$RootUrl = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ".run"
$toolsDir = Join-Path $root ".tools"
$grafanaDir = Join-Path $toolsDir "grafana"
$grafanaZip = Join-Path $toolsDir ("grafana-" + [guid]::NewGuid().ToString("N") + ".zip")

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
New-Item -ItemType Directory -Path $grafanaDir -Force | Out-Null

function Get-GrafanaExe {
    $exe = Get-ChildItem -Path $grafanaDir -Recurse -Filter "grafana-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Test-GrafanaArchive {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $entries = & tar -tf $Path 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return [bool]($entries | Select-String -SimpleMatch "grafana-server.exe")
    }
    catch {
        return $false
    }
}

$grafanaExe = Get-GrafanaExe

if (-not $grafanaExe) {
    $archive = Get-ChildItem -Path $toolsDir -Filter "grafana*.zip" -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 -and (Test-GrafanaArchive -Path $_.FullName) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $archive) {
        Write-Host "Baixando Grafana portavel..."
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/grafana/grafana/releases/latest"
        $version = ($release.tag_name -replace "^v", "")
        $downloadUrl = "https://dl.grafana.com/oss/release/grafana-$version.windows-amd64.zip"

        if (Test-Path $grafanaZip) {
            Remove-Item -Path $grafanaZip -Force -ErrorAction SilentlyContinue
        }

        & curl.exe -L --fail --retry 5 --retry-all-errors --output $grafanaZip $downloadUrl
        if ($LASTEXITCODE -ne 0 -or -not (Test-GrafanaArchive -Path $grafanaZip)) {
            Remove-Item -Path $grafanaZip -Force -ErrorAction SilentlyContinue
            throw "Falha ao baixar um pacote valido do Grafana."
        }
        $archive = Get-Item $grafanaZip
    }
    else {
        Write-Host "Reutilizando pacote local do Grafana: $($archive.Name)"
    }

    Remove-Item -Path (Join-Path $grafanaDir "*") -Recurse -Force -ErrorAction SilentlyContinue
    & tar -xf $archive.FullName -C $grafanaDir
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao extrair o pacote do Grafana."
    }

    $manifestPath = Get-ChildItem -Path $grafanaDir -Recurse -Filter "assets-manifest.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $manifestPath) {
        $manifestEntry = & tar -tf $archive.FullName | Select-String "public/build/assets-manifest.json$" | Select-Object -First 1
        if (-not $manifestEntry) {
            throw "Falha ao restaurar assets-manifest.json do Grafana."
        }

        & tar -xf $archive.FullName -C $grafanaDir $manifestEntry.ToString()
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao restaurar assets-manifest.json do Grafana."
        }

        $manifestPath = Get-ChildItem -Path $grafanaDir -Recurse -Filter "assets-manifest.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $manifestPath) {
            throw "assets-manifest.json nao foi encontrado apos a restauracao."
        }
    }

    if ($archive.FullName -eq $grafanaZip) {
        Remove-Item -Path $grafanaZip -Force -ErrorAction SilentlyContinue
    }

    $grafanaExe = Get-GrafanaExe
    if (-not $grafanaExe) {
        throw "Grafana baixado, mas grafana-server.exe nao foi encontrado."
    }
}

$grafanaHome = Split-Path (Split-Path $grafanaExe -Parent) -Parent

$provisioningDir = Join-Path $runDir "grafana-provisioning"
$dashboardsProviderDir = Join-Path $provisioningDir "dashboards"
$dashboardFilesDir = Join-Path $runDir "grafana-dashboards"

@($provisioningDir, $dashboardsProviderDir, $dashboardFilesDir) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

$dashboardsProvisioningFile = Join-Path $dashboardsProviderDir "default.yml"
@"
apiVersion: 1
providers:
  - name: 'Globo Dashboards'
    orgId: 1
    folder: 'Globo'
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 10
    options:
      path: '$dashboardFilesDir'
"@ | Set-Content -Path $dashboardsProvisioningFile -Encoding ascii

$overviewDashboardPath = Join-Path $dashboardFilesDir "overview.json"
@"
{
  "id": null,
  "uid": "globo-overview",
  "title": "Globo - Overview",
  "tags": ["globo", "observability"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "5s",
  "panels": [
    {
      "id": 1,
      "type": "text",
      "title": "Acessos Rapidos",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "options": {
        "mode": "markdown",
        "content": "## Aplicacoes\\n- [Python texto fixo](/python)\\n- [Python horario](/python/time)\\n- [Python observabilidade](/python/observability)\\n- [PowerShell texto fixo](/powershell)\\n- [PowerShell horario](/powershell/time)\\n- [PowerShell observabilidade](/powershell/observability)\\n\\n## Validacao de cache\\nAs paginas de observabilidade geram trafego inicial em `/` e `/time` para evidenciar `MISS/HIT`."
      }
    }
  ]
}
"@ | Set-Content -Path $overviewDashboardPath -Encoding ascii

$grafanaIni = Join-Path $runDir "grafana.ini"
$rootUrlConfig = ""
$subPathConfig = ""
$readyPath = "/login"
if (-not [string]::IsNullOrWhiteSpace($RootUrl)) {
    $rootUrlConfig = "root_url = $RootUrl"
    $subPathConfig = "serve_from_sub_path = true"
    try {
        $rootUri = [Uri]$RootUrl
        $basePath = $rootUri.AbsolutePath.TrimEnd("/")
        if (-not [string]::IsNullOrWhiteSpace($basePath)) {
            $readyPath = "$basePath/login"
        }
    }
    catch {
        $readyPath = "/login"
    }
}
@"
[server]
http_addr = 127.0.0.1
http_port = $GrafanaPort
$rootUrlConfig
$subPathConfig

[paths]
provisioning = $provisioningDir

[dashboards]
default_home_dashboard_path = $overviewDashboardPath

[auth]
disable_login_form = false

[auth.anonymous]
enabled = false
org_role = Viewer

[security]
admin_user = admin
admin_password = admin
"@ | Set-Content -Path $grafanaIni -Encoding ascii

$stdoutLog = Join-Path $runDir "grafana.out.log"
$stderrLog = Join-Path $runDir "grafana.err.log"
$pidFile = Join-Path $runDir "grafana.pid"

Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -like "grafana*" -and
        $_.Path -and
        $_.Path.StartsWith($grafanaDir, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1

@($stdoutLog, $stderrLog, $pidFile) | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Force }
}

$process = Start-Process `
    -FilePath $grafanaExe `
    -ArgumentList @("--config", $grafanaIni, "--homepath", $grafanaHome) `
    -WorkingDirectory $grafanaHome `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $pidFile -Value $process.Id -Encoding ascii

# Espera ativa para confirmar que o Grafana realmente subiu.
$deadline = (Get-Date).AddSeconds(90)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$GrafanaPort$readyPath" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            $ready = $true
            break
        }
    }
    catch {
    }

    if ($process.HasExited) {
        Write-Host "Grafana encerrou antes de ficar pronto."
        if (Test-Path $stderrLog) { Get-Content $stderrLog }
        if (Test-Path $stdoutLog) { Get-Content $stdoutLog }
        throw "Falha ao iniciar Grafana."
    }

    Start-Sleep -Seconds 2
}

if (-not $ready) {
    if (Test-Path $stderrLog) { Get-Content $stderrLog }
    if (Test-Path $stdoutLog) { Get-Content $stdoutLog }
    throw "Timeout aguardando Grafana em http://127.0.0.1:$GrafanaPort$readyPath"
}

Write-Host "Grafana iniciado em http://127.0.0.1:$GrafanaPort (usuario admin / senha admin)"
