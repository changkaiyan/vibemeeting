import os
import ssl
from pathlib import Path

from django.contrib.staticfiles.management.commands.runserver import Command as RunserverCommand
from django.core.management.base import CommandError
from django.core.servers.basehttp import WSGIServer


class SecureWSGIServer(WSGIServer):
    certfile: str | None = None
    keyfile: str | None = None

    def setup_environ(self):
        super().setup_environ()
        # Make Django treat requests as HTTPS when served by runsslserver.
        self.base_environ["wsgi.url_scheme"] = "https"
        self.base_environ["HTTPS"] = "on"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if not self.certfile or not self.keyfile:
            raise CommandError("HTTPS certificate and key files are required.")

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=self.certfile, keyfile=self.keyfile)
        self.socket = context.wrap_socket(self.socket, server_side=True)


class Command(RunserverCommand):
    help = "Start Django development server with HTTPS using a local certificate."
    protocol = "https"
    server_cls = SecureWSGIServer
    default_port = "8443"

    def add_arguments(self, parser):
        super().add_arguments(parser)
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

    def inner_run(self, *args, **options):
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

        SecureWSGIServer.certfile = str(cert_file)
        SecureWSGIServer.keyfile = str(key_file)

        try:
            super().inner_run(*args, **options)
        except ssl.SSLError as exc:
            raise CommandError(f"Unable to load TLS certificate or key: {exc}") from exc
