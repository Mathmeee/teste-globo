param(
    [int]$Port = 8002
)

$ErrorActionPreference = "Stop"

$cacheTtlSeconds = 60
$cache = @{}
$metrics = [ordered]@{
    StartTime = Get-Date
    TotalRequests = 0
    TotalErrors = 0
    CacheHit = 0
    CacheMiss = 0
    PerRoute = @{}
    PerStatus = @{}
    RecentLatencyMs = New-Object System.Collections.Generic.List[double]
    LastRequests = New-Object System.Collections.Generic.List[object]
}
$maxLatencySamples = 120
$maxLastRequests = 50

$observabilityHtml = @'
<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8">
    <title>Observabilidade - PowerShell</title>
    <style>
      :root {
        --bg: #0f172a;
        --card: #111827;
        --accent: #f97316;
        --text: #e2e8f0;
        --muted: #94a3b8;
      }
      body {
        background: radial-gradient(circle at top, #1e293b, #0f172a);
        font-family: "Segoe UI", sans-serif;
        color: var(--text);
        margin: 0;
        padding: 2rem;
      }
      header {
        display: flex;
        align-items: baseline;
        gap: 1rem;
      }
      h1 { margin: 0; }
      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 1rem;
        margin-top: 1.5rem;
      }
      .card {
        background: var(--card);
        border: 1px solid #1f2937;
        border-radius: 12px;
        padding: 1rem;
        box-shadow: 0 8px 30px rgba(0, 0, 0, 0.25);
      }
      .label {
        color: var(--muted);
        font-size: 0.85rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
      }
      .value {
        font-size: 1.6rem;
        margin-top: 0.5rem;
      }
      canvas {
        width: 100%;
        height: 120px;
        background: #0b1220;
        border-radius: 10px;
        margin-top: 0.75rem;
      }
      table {
        width: 100%;
        border-collapse: collapse;
        font-size: 0.9rem;
      }
      th, td {
        padding: 0.5rem;
        border-bottom: 1px solid #1f2937;
        text-align: left;
      }
      th {
        color: var(--muted);
        font-weight: 500;
      }
      .pill {
        display: inline-block;
        padding: 0.2rem 0.5rem;
        border-radius: 999px;
        background: rgba(249, 115, 22, 0.15);
        color: var(--accent);
        font-size: 0.75rem;
      }
    </style>
  </head>
  <body>
    <header>
      <h1>Observabilidade</h1>
      <span class="pill">PowerShell</span>
    </header>
    <div class="grid">
      <div class="card">
        <div class="label">Total requests</div>
        <div class="value" id="total-requests">-</div>
      </div>
      <div class="card">
        <div class="label">Erros</div>
        <div class="value" id="total-errors">-</div>
      </div>
      <div class="card">
        <div class="label">Cache HIT</div>
        <div class="value" id="cache-hit">-</div>
      </div>
      <div class="card">
        <div class="label">Cache MISS</div>
        <div class="value" id="cache-miss">-</div>
      </div>
      <div class="card">
        <div class="label">Latencia media (ms)</div>
        <div class="value" id="avg-latency">-</div>
      </div>
      <div class="card">
        <div class="label">Uptime (s)</div>
        <div class="value" id="uptime">-</div>
      </div>
    </div>

    <div class="grid" style="margin-top: 1.5rem;">
      <div class="card">
        <div class="label">Latencia recente (ms)</div>
        <canvas id="latency-chart" width="600" height="120"></canvas>
      </div>
      <div class="card">
        <div class="label">Rotas mais acessadas</div>
        <table>
          <thead>
            <tr><th>Rota</th><th>Requests</th></tr>
          </thead>
          <tbody id="routes-table"></tbody>
        </table>
      </div>
      <div class="card">
        <div class="label">Ultimas requisicoes</div>
        <table>
          <thead>
            <tr><th>Hora</th><th>Rota</th><th>Status</th><th>Cache</th><th>ms</th></tr>
          </thead>
          <tbody id="requests-table"></tbody>
        </table>
      </div>
    </div>

    <script>
      const prefixMatch = window.location.pathname.match(/^\/(python|powershell)(?:\/|$)/);
      const basePrefix = prefixMatch ? `/${prefixMatch[1]}` : '';
      const internalRoutes = new Set(['/metrics', '/observability', '/export', '/export.csv']);
      let warmedUp = false;

      async function fetchMetrics() {
        const attempts = [
          `${basePrefix}/metrics`,
          'metrics',
          '/metrics',
        ];
        let lastError = null;
        for (const url of attempts) {
          try {
            const response = await fetch(url, { cache: 'no-store' });
            if (response.ok) {
              return response.json();
            }
            lastError = new Error(`HTTP ${response.status}`);
          } catch (error) {
            lastError = error;
          }
        }
        throw lastError || new Error('Falha ao buscar metricas');
      }

      async function warmupCache() {
        if (warmedUp) return;
        warmedUp = true;
        const textUrl = basePrefix || '/';
        const timeUrl = `${basePrefix}/time`;
        try {
          await fetch(textUrl, { cache: 'no-store' });
          await fetch(textUrl, { cache: 'no-store' });
          await fetch(timeUrl, { cache: 'no-store' });
          await fetch(timeUrl, { cache: 'no-store' });
        } catch (_) {}
      }

      function renderLatency(canvas, values) {
        const ctx = canvas.getContext('2d');
        const w = canvas.width;
        const h = canvas.height;
        ctx.clearRect(0, 0, w, h);
        if (!values.length) {
          ctx.fillStyle = '#94a3b8';
          ctx.fillText('Sem dados', 10, 20);
          return;
        }
        const max = Math.max(...values, 1);
        ctx.strokeStyle = '#f97316';
        ctx.lineWidth = 2;
        ctx.beginPath();
        values.forEach((v, i) => {
          const x = (i / (values.length - 1 || 1)) * (w - 20) + 10;
          const y = h - (v / max) * (h - 20) - 10;
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        });
        ctx.stroke();
      }

      function renderTable(bodyId, rows) {
        const tbody = document.getElementById(bodyId);
        tbody.innerHTML = rows.map(row => `<tr>${row.map(cell => `<td>${cell}</td>`).join('')}</tr>`).join('');
      }

      async function update() {
        try {
          await warmupCache();
          const data = await fetchMetrics();
          document.getElementById('total-requests').textContent = data.total_requests;
          document.getElementById('total-errors').textContent = data.total_errors;
          document.getElementById('cache-hit').textContent = data.cache_hit;
          document.getElementById('cache-miss').textContent = data.cache_miss;
          document.getElementById('avg-latency').textContent = data.avg_latency_ms;
          document.getElementById('uptime').textContent = data.uptime_seconds;

          const routes = Object.entries(data.per_route || {})
            .filter(([route]) => !internalRoutes.has(route))
            .sort((a, b) => b[1] - a[1])
            .slice(0, 8);
          renderTable('routes-table', routes.map(([route, count]) => [route, count]));

          const requests = (data.last_requests || [])
            .filter(r => !internalRoutes.has(r.route))
            .slice(-8)
            .reverse();
          renderTable('requests-table', requests.map(r => [r.ts, r.route, r.status, r.cache, r.latency_ms]));

          renderLatency(document.getElementById('latency-chart'), data.recent_latency_ms || []);
        } catch (error) {
          console.error(error);
        }
      }

      update();
      setInterval(update, 2000);
    </script>
  </body>
</html>
'@

function Get-CachedResponse {
    param(
        [string]$Key,
        [scriptblock]$Factory
    )

    $now = Get-Date
    if ($cache.ContainsKey($Key)) {
        $entry = $cache[$Key]
        if ($entry.ExpiresAt -gt $now) {
            return @{
                Body = $entry.Body
                CacheStatus = "HIT"
            }
        }
    }

    $body = & $Factory
    $cache[$Key] = @{
        Body = $body
        ExpiresAt = $now.AddSeconds($cacheTtlSeconds)
    }

    return @{
        Body = $body
        CacheStatus = "MISS"
    }
}

function Add-MetricSample {
    param(
        [string]$Route,
        [int]$StatusCode,
        [string]$CacheStatus,
        [double]$LatencyMs
    )

    $metrics.TotalRequests++
    if ($StatusCode -ge 400) {
        $metrics.TotalErrors++
    }

    if (-not $metrics.PerRoute.ContainsKey($Route)) {
        $metrics.PerRoute[$Route] = 0
    }
    $metrics.PerRoute[$Route]++

    $statusKey = [string]$StatusCode
    if (-not $metrics.PerStatus.ContainsKey($statusKey)) {
        $metrics.PerStatus[$statusKey] = 0
    }
    $metrics.PerStatus[$statusKey]++

    if ($CacheStatus -eq "HIT") { $metrics.CacheHit++ }
    if ($CacheStatus -eq "MISS") { $metrics.CacheMiss++ }

    $metrics.RecentLatencyMs.Add([math]::Round($LatencyMs, 2))
    while ($metrics.RecentLatencyMs.Count -gt $maxLatencySamples) {
        $metrics.RecentLatencyMs.RemoveAt(0)
    }

    $metrics.LastRequests.Add([ordered]@{
        ts = (Get-Date).ToString("o")
        route = $Route
        status = $StatusCode
        cache = $CacheStatus
        latency_ms = [math]::Round($LatencyMs, 2)
    })
    while ($metrics.LastRequests.Count -gt $maxLastRequests) {
        $metrics.LastRequests.RemoveAt(0)
    }
}

function Get-MetricsSnapshot {
    $avg = 0
    if ($metrics.RecentLatencyMs.Count -gt 0) {
        $avg = ($metrics.RecentLatencyMs | Measure-Object -Average).Average
    }
    return [ordered]@{
        start_time = $metrics.StartTime.ToString("o")
        uptime_seconds = [math]::Round(((Get-Date) - $metrics.StartTime).TotalSeconds, 2)
        total_requests = $metrics.TotalRequests
        total_errors = $metrics.TotalErrors
        per_route = $metrics.PerRoute
        per_status = $metrics.PerStatus
        cache_hit = $metrics.CacheHit
        cache_miss = $metrics.CacheMiss
        avg_latency_ms = [math]::Round($avg, 2)
        recent_latency_ms = $metrics.RecentLatencyMs
        last_requests = $metrics.LastRequests
    }
}

function Write-Response {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [Parameter(Mandatory = $true)]
        [string]$CacheStatus,
        [string]$ContentType = "text/plain; charset=utf-8",
        [string]$ContentDisposition = $null
    )

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
    try {
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $buffer.Length
        $Response.Headers["X-Cache"] = $CacheStatus
        $Response.Headers["X-Cache-TTL"] = [string]$cacheTtlSeconds
        if ($ContentDisposition) {
            $Response.Headers["Content-Disposition"] = $ContentDisposition
        }
        $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    }
    catch {
        # A conexao pode ser encerrada pelo cliente; nao derruba o servidor.
    }
    finally {
        try { $Response.OutputStream.Close() } catch {}
    }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "Aplicacao PowerShell ouvindo em http://localhost:$Port com cache de $cacheTtlSeconds s."

try {
    while ($true) {
        try {
            $context = $listener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            break
        }

        $response = $context.Response
        $requestPath = $context.Request.Url.AbsolutePath
        if ([string]::IsNullOrWhiteSpace($requestPath)) {
            $requestPath = "/"
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $statusCode = 200
        $cacheStatus = "BYPASS"
        $body = ""
        $contentType = "text/plain; charset=utf-8"
        $contentDisposition = $null
        $metricRoute = $requestPath

        try {
            switch ($requestPath) {
                "/metrics" {
                    $body = (Get-MetricsSnapshot | ConvertTo-Json -Depth 6)
                    $contentType = "application/json; charset=utf-8"
                    break
                }
                "/export" {
                    $body = (Get-MetricsSnapshot | ConvertTo-Json -Depth 6)
                    $contentType = "application/json; charset=utf-8"
                    $contentDisposition = "attachment; filename=metrics-powershell.json"
                    break
                }
                "/export.csv" {
                    $snapshot = Get-MetricsSnapshot
                    $headers = "timestamp,uptime_seconds,total_requests,total_errors,cache_hit,cache_miss,avg_latency_ms"
                    $values = @(
                        (Get-Date).ToString("o"),
                        $snapshot.uptime_seconds,
                        $snapshot.total_requests,
                        $snapshot.total_errors,
                        $snapshot.cache_hit,
                        $snapshot.cache_miss,
                        $snapshot.avg_latency_ms
                    ) -join ","
                    $body = $headers + "`n" + $values + "`n"
                    $contentType = "text/csv; charset=utf-8"
                    $contentDisposition = "attachment; filename=metrics-powershell.csv"
                    break
                }
                "/observability" {
                    $body = $observabilityHtml
                    $contentType = "text/html; charset=utf-8"
                    break
                }
                "/" {
                    $result = Get-CachedResponse -Key $requestPath -Factory {
                        ("Ol{0} Globo" -f [char]0x00E1)
                    }
                    $body = $result.Body
                    $cacheStatus = $result.CacheStatus
                    break
                }
                "/time" {
                    $result = Get-CachedResponse -Key $requestPath -Factory {
                        "Horario atual do servidor: $(Get-Date -Format o)"
                    }
                    $body = $result.Body
                    $cacheStatus = $result.CacheStatus
                    break
                }
                default {
                    $statusCode = 404
                    $cacheStatus = "BYPASS"
                    $metricRoute = "404"
                    $body = "Rota nao encontrada."
                    break
                }
            }
        }
        catch {
            $statusCode = 500
            $cacheStatus = "BYPASS"
            $metricRoute = "500"
            $body = "Erro interno do servidor PowerShell."
            Write-Warning "Erro ao processar requisicao ${requestPath}: $($_.Exception.Message)"
        }
        finally {
            Write-Response `
                -Response $response `
                -StatusCode $statusCode `
                -Body $body `
                -CacheStatus $cacheStatus `
                -ContentType $contentType `
                -ContentDisposition $contentDisposition
            Add-MetricSample -Route $metricRoute -StatusCode $statusCode -CacheStatus $cacheStatus -LatencyMs $sw.Elapsed.TotalMilliseconds
        }
    }
}
finally {
    $listener.Stop()
}
