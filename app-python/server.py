from __future__ import annotations

import argparse
import json
import time
from collections import deque
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import urlparse


CACHE_TTL_SECONDS = 10
_cache: dict[str, tuple[datetime, str]] = {}
_cache_lock = Lock()

_metrics_lock = Lock()
_metrics = {
    "start_time": time.time(),
    "total_requests": 0,
    "total_errors": 0,
    "per_route": {},
    "per_status": {},
    "cache_hit": 0,
    "cache_miss": 0,
    "latency_ms": deque(maxlen=120),
    "last_requests": deque(maxlen=50),
}


def _record_metrics(route: str, status: int, cache_status: str, duration_ms: float) -> None:
    with _metrics_lock:
        _metrics["total_requests"] += 1
        if status >= 400:
            _metrics["total_errors"] += 1
        _metrics["per_route"][route] = _metrics["per_route"].get(route, 0) + 1
        _metrics["per_status"][str(status)] = _metrics["per_status"].get(str(status), 0) + 1
        if cache_status == "HIT":
            _metrics["cache_hit"] += 1
        elif cache_status == "MISS":
            _metrics["cache_miss"] += 1
        _metrics["latency_ms"].append(duration_ms)
        _metrics["last_requests"].append(
            {
                "ts": datetime.now().astimezone().isoformat(),
                "route": route,
                "status": status,
                "cache": cache_status,
                "latency_ms": round(duration_ms, 2),
            }
        )


def _metrics_snapshot() -> dict:
    with _metrics_lock:
        latency = list(_metrics["latency_ms"])
        avg_latency = sum(latency) / len(latency) if latency else 0.0
        uptime = time.time() - _metrics["start_time"]
        return {
            "start_time": _metrics["start_time"],
            "uptime_seconds": round(uptime, 2),
            "total_requests": _metrics["total_requests"],
            "total_errors": _metrics["total_errors"],
            "per_route": dict(_metrics["per_route"]),
            "per_status": dict(_metrics["per_status"]),
            "cache_hit": _metrics["cache_hit"],
            "cache_miss": _metrics["cache_miss"],
            "avg_latency_ms": round(avg_latency, 2),
            "recent_latency_ms": latency,
            "last_requests": list(_metrics["last_requests"]),
        }


def _metrics_csv(snapshot: dict) -> str:
    headers = [
        "timestamp",
        "uptime_seconds",
        "total_requests",
        "total_errors",
        "cache_hit",
        "cache_miss",
        "avg_latency_ms",
    ]
    values = [
        datetime.now().astimezone().isoformat(),
        snapshot.get("uptime_seconds", 0),
        snapshot.get("total_requests", 0),
        snapshot.get("total_errors", 0),
        snapshot.get("cache_hit", 0),
        snapshot.get("cache_miss", 0),
        snapshot.get("avg_latency_ms", 0),
    ]
    return ",".join(headers) + "\n" + ",".join(str(v) for v in values) + "\n"


HTML_OBSERVABILITY = """\
<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8">
    <title>Observabilidade - Python</title>
    <style>
      :root {
        --bg: #0f172a;
        --card: #111827;
        --accent: #38bdf8;
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
      h1 {
        margin: 0;
      }
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
      .muted {
        color: var(--muted);
      }
      .pill {
        display: inline-block;
        padding: 0.2rem 0.5rem;
        border-radius: 999px;
        background: rgba(56, 189, 248, 0.15);
        color: var(--accent);
        font-size: 0.75rem;
      }
    </style>
  </head>
  <body>
    <header>
      <h1>Observabilidade</h1>
      <span class="pill">Python</span>
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
      const prefixMatch = window.location.pathname.match(/^\\/(python|powershell)(?:\\/|$)/);
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
        ctx.strokeStyle = '#38bdf8';
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
"""


def get_cached_response(path: str, factory) -> tuple[str, str]:
    now = datetime.now()

    with _cache_lock:
        cached = _cache.get(path)
        if cached and cached[0] > now:
            return cached[1], "HIT"

    body = factory()
    expires_at = now + timedelta(seconds=CACHE_TTL_SECONDS)

    with _cache_lock:
        _cache[path] = (expires_at, body)

    return body, "MISS"


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "PythonCacheServer/1.0"

    def do_GET(self) -> None:
        start = time.perf_counter()
        path = urlparse(self.path).path

        if path == "/metrics":
            payload = json.dumps(_metrics_snapshot(), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            _record_metrics("/metrics", 200, "BYPASS", (time.perf_counter() - start) * 1000)
            return

        if path == "/export":
            snapshot = _metrics_snapshot()
            payload = json.dumps(snapshot, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Disposition", "attachment; filename=metrics-python.json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            _record_metrics("/export", 200, "BYPASS", (time.perf_counter() - start) * 1000)
            return

        if path == "/export.csv":
            snapshot = _metrics_snapshot()
            payload_text = _metrics_csv(snapshot)
            payload = payload_text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/csv; charset=utf-8")
            self.send_header("Content-Disposition", "attachment; filename=metrics-python.csv")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            _record_metrics("/export.csv", 200, "BYPASS", (time.perf_counter() - start) * 1000)
            return

        if path == "/observability":
            payload = HTML_OBSERVABILITY.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            _record_metrics("/observability", 200, "BYPASS", (time.perf_counter() - start) * 1000)
            return

        if path == "/":
            body, cache_status = get_cached_response(
                path,
                lambda: "Ol\u00e1 Globo",
            )
            self._send_response(200, body, cache_status)
            _record_metrics("/", 200, cache_status, (time.perf_counter() - start) * 1000)
            return

        if path == "/time":
            body, cache_status = get_cached_response(
                path,
                lambda: f"Horario atual do servidor: {datetime.now().astimezone().isoformat()}",
            )
            self._send_response(200, body, cache_status)
            _record_metrics("/time", 200, cache_status, (time.perf_counter() - start) * 1000)
            return

        self._send_response(404, "Rota nao encontrada.", "BYPASS")
        _record_metrics("404", 404, "BYPASS", (time.perf_counter() - start) * 1000)

    def _send_response(self, status_code: int, body: str, cache_status: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Cache", cache_status)
        self.send_header("X-Cache-TTL", str(CACHE_TTL_SECONDS))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Aplicacao HTTP em Python com cache.")
    parser.add_argument("--port", type=int, default=8001, help="Porta do servidor")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("0.0.0.0", args.port), RequestHandler)
    print(
        f"Aplicacao Python ouvindo em http://localhost:{args.port} com cache de {CACHE_TTL_SECONDS}s."
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
