from __future__ import annotations

import argparse
from collections.abc import Iterable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


HTML_INDEX = """\
<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8">
    <title>Ola Globo</title>
    <style>
      body {
        font-family: "Segoe UI", sans-serif;
        margin: 2rem;
        line-height: 1.5;
      }

      h1 {
        margin-bottom: 0.5rem;
      }

      ul {
        padding-left: 1.2rem;
      }
    </style>
  </head>
  <body>
    <h1>Ola Globo</h1>
    <p>Proxy reverso ativo. Use os links abaixo para acessar as aplicacoes:</p>
    <ul>
      <li><a href="/python">/python</a></li>
      <li><a href="/python/time">/python/time</a></li>
      <li><a href="/powershell">/powershell</a></li>
      <li><a href="/powershell/time">/powershell/time</a></li>
      <li><a href="/grafana">/grafana</a></li>
    </ul>
  </body>
</html>
"""


class ReverseProxyHandler(BaseHTTPRequestHandler):
    server_version = "ReverseProxy/1.0"

    python_backend = "http://127.0.0.1:8001"
    powershell_backend = "http://127.0.0.1:8002"
    grafana_backend = "http://127.0.0.1:3000"
    hop_by_hop_headers = {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "content-length",
    }

    def do_GET(self) -> None:
        self._handle_request(send_body=True)

    def do_HEAD(self) -> None:
        self._handle_request(send_body=False)

    def do_POST(self) -> None:
        self._handle_request(send_body=True)

    def do_PUT(self) -> None:
        self._handle_request(send_body=True)

    def do_PATCH(self) -> None:
        self._handle_request(send_body=True)

    def do_DELETE(self) -> None:
        self._handle_request(send_body=True)

    def do_OPTIONS(self) -> None:
        self._handle_request(send_body=True)

    def _handle_request(self, send_body: bool) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/" and self.command in {"GET", "HEAD"}:
            self._send_html(send_body=send_body)
            return

        if path in {"/metrics", "/export", "/export.csv"}:
            referer = self.headers.get("Referer", "")
            if "/python/" in referer:
                self._proxy_request(
                    "/python",
                    self.python_backend,
                    parsed,
                    send_body=send_body,
                    strip_prefix=False,
                )
                return
            if "/powershell/" in referer:
                self._proxy_request(
                    "/powershell",
                    self.powershell_backend,
                    parsed,
                    send_body=send_body,
                    strip_prefix=False,
                )
                return

        for prefix, backend, strip_prefix in (
            ("/python", self.python_backend, True),
            ("/powershell", self.powershell_backend, True),
            ("/grafana", self.grafana_backend, False),
        ):
            if path == prefix or path.startswith(prefix + "/"):
                self._proxy_request(
                    prefix,
                    backend,
                    parsed,
                    send_body=send_body,
                    strip_prefix=strip_prefix,
                )
                return

        self._send_text(404, "Rota nao encontrada.", {"X-Proxy": "MISS"}, send_body=send_body)

    def _proxy_request(
        self,
        prefix: str,
        backend: str,
        parsed,
        *,
        send_body: bool,
        strip_prefix: bool,
    ) -> None:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        request_body = self.rfile.read(content_length) if content_length > 0 else None

        backend_path = parsed.path
        if strip_prefix:
            backend_path = parsed.path[len(prefix) :] or "/"
        target_url = backend + backend_path
        if parsed.query:
            target_url = f"{target_url}?{parsed.query}"

        request_headers = self._build_request_headers(prefix)
        request = Request(
            target_url,
            data=request_body,
            headers=request_headers,
            method=self.command,
        )

        try:
            with urlopen(request, timeout=30) as response:
                payload = response.read()
                headers = self._build_response_headers(response.headers.items(), prefix, "HIT")
                self._send_payload(response.status, payload, headers, send_body=send_body)
                return
        except HTTPError as exc:
            payload = exc.read()
            headers = self._build_response_headers(exc.headers.items(), prefix, "ERROR")
            self._send_payload(exc.code, payload, headers, send_body=send_body)
            return
        except URLError:
            self._send_text(502, "Backend indisponivel.", {"X-Proxy": "ERROR"}, send_body=send_body)

    def _build_request_headers(self, prefix: str) -> dict[str, str]:
        headers: dict[str, str] = {}
        for header_name, header_value in self.headers.items():
            normalized = header_name.lower()
            if normalized in self.hop_by_hop_headers:
                continue
            if normalized in {"host", "content-length"}:
                continue
            headers[header_name] = header_value

        headers["Accept"] = self.headers.get("Accept", "*/*")
        headers["User-Agent"] = self.headers.get("User-Agent", "ReverseProxy/1.0")
        headers["X-Forwarded-For"] = self.client_address[0]
        headers["X-Forwarded-Host"] = self.headers.get("Host", "")
        headers["X-Forwarded-Prefix"] = prefix
        headers["X-Forwarded-Proto"] = self.headers.get("X-Forwarded-Proto", "http")
        return headers

    def _build_response_headers(
        self,
        headers: Iterable[tuple[str, str]],
        prefix: str,
        proxy_status: str,
    ) -> list[tuple[str, str]]:
        forwarded_headers: list[tuple[str, str]] = []
        seen_cache = False
        seen_ttl = False

        for header_name, header_value in headers:
            normalized = header_name.lower()
            if normalized in self.hop_by_hop_headers:
                continue

            value = header_value
            if normalized == "location":
                value = self._rewrite_location(prefix, header_value)
            elif normalized == "x-cache":
                seen_cache = True
            elif normalized == "x-cache-ttl":
                seen_ttl = True

            forwarded_headers.append((header_name, value))

        if not seen_cache:
            forwarded_headers.append(("X-Cache", "BYPASS"))
        if not seen_ttl:
            forwarded_headers.append(("X-Cache-TTL", "0"))
        forwarded_headers.append(("X-Proxy", proxy_status))
        return forwarded_headers

    def _rewrite_location(self, prefix: str, location: str) -> str:
        if not location:
            return location

        parsed_location = urlparse(location)
        if parsed_location.scheme or parsed_location.netloc:
            if parsed_location.hostname not in {"localhost", "127.0.0.1"}:
                return location
            rewritten_path = self._prefix_path(prefix, parsed_location.path)
            return parsed_location._replace(
                scheme="",
                netloc="",
                path=rewritten_path,
            ).geturl() or rewritten_path

        return self._prefix_path(prefix, location)

    def _prefix_path(self, prefix: str, value: str) -> str:
        if not value.startswith("/"):
            return value
        if value == prefix or value.startswith(prefix + "/"):
            return value
        return prefix + value

    def _send_html(self, body: str = HTML_INDEX, *, send_body: bool) -> None:
        self._send_payload(
            200,
            body.encode("utf-8"),
            [
                ("Content-Type", "text/html; charset=utf-8"),
                ("X-Cache", "BYPASS"),
                ("X-Cache-TTL", "0"),
                ("X-Proxy", "INDEX"),
            ],
            send_body=send_body,
        )

    def _send_text(
        self,
        status_code: int,
        body: str,
        headers: dict[str, str],
        *,
        send_body: bool,
    ) -> None:
        self._send_payload(
            status_code,
            body.encode("utf-8"),
            [("Content-Type", "text/plain; charset=utf-8"), *headers.items()],
            send_body=send_body,
        )

    def _send_payload(
        self,
        status_code: int,
        payload: bytes,
        headers: Iterable[tuple[str, str]],
        *,
        send_body: bool,
    ) -> None:
        self.send_response(status_code)
        self.send_header("Content-Length", str(len(payload)))
        for header_name, header_value in headers:
            self.send_header(header_name, header_value)
        self.end_headers()
        if send_body:
            self.wfile.write(payload)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Proxy reverso local para as aplicacoes.")
    parser.add_argument("--port", type=int, default=8080, help="Porta do proxy")
    parser.add_argument(
        "--python-backend-port",
        type=int,
        default=8001,
        help="Porta da aplicacao Python",
    )
    parser.add_argument(
        "--powershell-backend-port",
        type=int,
        default=8002,
        help="Porta da aplicacao PowerShell",
    )
    parser.add_argument(
        "--grafana-backend-port",
        type=int,
        default=3000,
        help="Porta do Grafana",
    )
    args = parser.parse_args()

    ReverseProxyHandler.python_backend = f"http://127.0.0.1:{args.python_backend_port}"
    ReverseProxyHandler.powershell_backend = (
        f"http://127.0.0.1:{args.powershell_backend_port}"
    )
    ReverseProxyHandler.grafana_backend = f"http://127.0.0.1:{args.grafana_backend_port}"

    server = ThreadingHTTPServer(("0.0.0.0", args.port), ReverseProxyHandler)
    print(
        "Proxy reverso ouvindo em "
        f"http://localhost:{args.port} "
        f"(python -> {ReverseProxyHandler.python_backend}, "
        f"powershell -> {ReverseProxyHandler.powershell_backend})."
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
