import os
import re
import socket
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError


_IPV6_ADDRPORT_RE = re.compile(r"^\[(?P<host>[^\]]+)\](?::(?P<port>\d+))?$")


def _parse_addrport(addrport: str, *, default_host: str, default_port: int) -> tuple[str, int]:
    raw = (addrport or "").strip()
    if not raw:
        return default_host, default_port
    if raw.isdigit():
        return default_host, int(raw)

    ipv6_match = _IPV6_ADDRPORT_RE.match(raw)
    if ipv6_match:
        host = ipv6_match.group("host") or default_host
        port_raw = ipv6_match.group("port")
        port = int(port_raw) if port_raw else default_port
        return host, port

    if ":" in raw:
        host, port_raw = raw.rsplit(":", 1)
        if not host:
            host = default_host
        if not port_raw.isdigit():
            raise CommandError(f"Invalid port value in addrport: {addrport}")
        return host, int(port_raw)

    return raw, default_port


def _uvicorn_app_from_django_asgi(asgi_path: str) -> str:
    raw = (asgi_path or "").strip()
    if not raw:
        raise CommandError("ASGI_APPLICATION is empty.")
    if ":" in raw:
        return raw
    module_path, dot, app_name = raw.rpartition(".")
    if not dot or not module_path or not app_name:
        raise CommandError(f"Invalid ASGI_APPLICATION: {raw}")
    return f"{module_path}:{app_name}"


def _can_connect(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, int(port)), timeout=0.3):
            return True
    except Exception:
        return False


def _listening_on_port(host: str, port: int) -> bool:
    normalized = (host or "").strip().lower()
    if normalized in {"0.0.0.0", "::", "[::]", "*"}:
        probe_hosts = ("127.0.0.1", "localhost")
    else:
        probe_hosts = (host,)
    return any(_can_connect(probe_host, port) for probe_host in probe_hosts)


class Command(BaseCommand):
    help = "Start HTTPS development server with ASGI/WebSocket support via uvicorn."
    default_addr = "127.0.0.1"
    default_port = 8443

    def add_arguments(self, parser):
        parser.add_argument(
            "addrport",
            nargs="?",
            default=f"{self.default_addr}:{self.default_port}",
            help="Optional port number, or ipaddr:port.",
        )
        parser.add_argument(
            "--cert-file",
            default=os.getenv("HTTPS_CERT_FILE", ".certs/localhost.crt"),
            help="Path to the TLS certificate file (PEM).",
        )
        parser.add_argument(
            "--key-file",
            default=os.getenv("HTTPS_KEY_FILE", ".certs/localhost.key"),
            help="Path to the TLS private key file (PEM).",
        )
        parser.add_argument(
            "--reload",
            action="store_true",
            help="Enable auto-reload.",
        )
        parser.add_argument(
            "--noreload",
            action="store_true",
            help="Disable auto-reload (default).",
        )
        parser.add_argument(
            "--nothreading",
            action="store_true",
            help="Accepted for compatibility; uvicorn handles concurrency itself.",
        )
        parser.add_argument(
            "--workers",
            type=int,
            default=1,
            help="Number of worker processes (ignored when auto-reload is enabled).",
        )

    def handle(self, *args, **options):
        try:
            import uvicorn
        except Exception as exc:
            raise CommandError("uvicorn is required for runsslserver (pip install uvicorn).") from exc

        cert_file = Path(options["cert_file"]).expanduser().resolve()
        key_file = Path(options["key_file"]).expanduser().resolve()
        if not cert_file.is_file():
            raise CommandError(
                f"Certificate file not found: {cert_file}\n"
                "Run `python manage.py gendevcert` first, or pass --cert-file."
            )
        if not key_file.is_file():
            raise CommandError(
                f"Private key file not found: {key_file}\n"
                "Run `python manage.py gendevcert` first, or pass --key-file."
            )

        host, port = _parse_addrport(
            options.get("addrport"),
            default_host=self.default_addr,
            default_port=self.default_port,
        )
        if port <= 0 or port > 65535:
            raise CommandError(f"Port out of range: {port}")
        if _listening_on_port(host, port):
            raise CommandError(
                f"Port {port} is already in use on host '{host}'. "
                "Stop the previous dev server process first."
            )

        reload_enabled = False
        if options.get("reload"):
            reload_enabled = True
        if options.get("noreload"):
            reload_enabled = False

        workers = max(1, int(options.get("workers") or 1))
        if reload_enabled and workers > 1:
            raise CommandError("Cannot use multiple workers together with auto-reload.")

        if options.get("nothreading"):
            self.stdout.write(self.style.WARNING("--nothreading is ignored under uvicorn."))

        app_path = _uvicorn_app_from_django_asgi(getattr(settings, "ASGI_APPLICATION", ""))
        self.stdout.write(
            f"Starting ASGI HTTPS server at https://{host}:{port} "
            f"(app={app_path}, reload={str(reload_enabled).lower()})"
        )

        uvicorn.run(
            app_path,
            host=host,
            port=port,
            reload=reload_enabled,
            workers=1 if reload_enabled else workers,
            lifespan="off",
            ssl_certfile=str(cert_file),
            ssl_keyfile=str(key_file),
            proxy_headers=True,
            forwarded_allow_ips="*",
        )
