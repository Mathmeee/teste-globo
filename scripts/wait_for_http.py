from __future__ import annotations

import argparse
import sys
import time
from urllib.error import URLError
from urllib.request import urlopen


def wait_for_url(url: str, timeout: float, interval: float) -> None:
    deadline = time.monotonic() + timeout
    last_error: str | None = None

    while time.monotonic() < deadline:
        try:
            with urlopen(url, timeout=5) as response:
                if 200 <= response.status < 500:
                    print(f"READY {url} -> {response.status}")
                    return
                last_error = f"status {response.status}"
        except URLError as exc:
            last_error = str(exc)

        time.sleep(interval)

    raise RuntimeError(f"Timeout esperando {url}. Ultimo erro: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Espera uma ou mais URLs responderem.")
    parser.add_argument("urls", nargs="+", help="Lista de URLs para validar")
    parser.add_argument("--timeout", type=float, default=30, help="Timeout em segundos")
    parser.add_argument(
        "--interval", type=float, default=1, help="Intervalo entre tentativas"
    )
    args = parser.parse_args()

    try:
        for url in args.urls:
            wait_for_url(url, args.timeout, args.interval)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
