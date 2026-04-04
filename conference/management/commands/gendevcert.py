from __future__ import annotations

import ipaddress
from datetime import datetime, timedelta, timezone
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
except ImportError as exc:  # pragma: no cover - surfaced as command error.
    x509 = None
    _import_error = exc
else:
    _import_error = None


def _parse_hosts(raw_hosts: str) -> list[str]:
    hosts = [item.strip() for item in raw_hosts.split(",") if item.strip()]
    if not hosts:
        raise CommandError("At least one host is required via --hosts.")
    return hosts


def _build_san_entries(hosts: list[str]) -> list[x509.GeneralName]:
    entries: list[x509.GeneralName] = []
    for host in hosts:
        try:
            ip = ipaddress.ip_address(host)
            entries.append(x509.IPAddress(ip))
        except ValueError:
            entries.append(x509.DNSName(host))
    return entries


class Command(BaseCommand):
    help = "Generate a self-signed certificate and private key for local HTTPS testing."

    def add_arguments(self, parser) -> None:
        parser.add_argument(
            "--cert-file",
            default=".certs/localhost.crt",
            help="Output certificate file path (PEM).",
        )
        parser.add_argument(
            "--key-file",
            default=".certs/localhost.key",
            help="Output private key file path (PEM).",
        )
        parser.add_argument(
            "--hosts",
            default="localhost,127.0.0.1,::1",
            help="Comma-separated SAN hosts/IPs for the certificate.",
        )
        parser.add_argument(
            "--days",
            type=int,
            default=365,
            help="Certificate validity period in days.",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help="Overwrite certificate/key if they already exist.",
        )

    def handle(self, *args, **options) -> None:
        if _import_error is not None:
            raise CommandError(
                "The `cryptography` package is required for gendevcert. "
                "Install it and retry."
            ) from _import_error

        cert_file = Path(options["cert_file"]).expanduser()
        key_file = Path(options["key_file"]).expanduser()
        force = bool(options["force"])
        validity_days = int(options["days"])

        if validity_days < 1:
            raise CommandError("--days must be >= 1.")
        if cert_file == key_file:
            raise CommandError("--cert-file and --key-file must be different paths.")

        cert_file.parent.mkdir(parents=True, exist_ok=True)
        key_file.parent.mkdir(parents=True, exist_ok=True)

        if not force:
            existing = [str(path) for path in (cert_file, key_file) if path.exists()]
            if existing:
                raise CommandError(
                    "File already exists: "
                    + ", ".join(existing)
                    + ". Use --force to overwrite."
                )

        hosts = _parse_hosts(options["hosts"])
        san_entries = _build_san_entries(hosts)

        private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

        primary_name = hosts[0]
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, primary_name)])
        utc_now = datetime.now(timezone.utc)

        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(utc_now - timedelta(minutes=1))
            .not_valid_after(utc_now + timedelta(days=validity_days))
            .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(
                x509.KeyUsage(
                    digital_signature=True,
                    key_encipherment=True,
                    key_cert_sign=False,
                    key_agreement=False,
                    content_commitment=False,
                    data_encipherment=False,
                    encipher_only=False,
                    decipher_only=False,
                    crl_sign=False,
                ),
                critical=True,
            )
            .add_extension(
                x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
                critical=False,
            )
            .sign(private_key, hashes.SHA256())
        )

        cert_pem = cert.public_bytes(serialization.Encoding.PEM)
        key_pem = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )

        cert_file.write_bytes(cert_pem)
        key_file.write_bytes(key_pem)

        self.stdout.write(self.style.SUCCESS("Generated local HTTPS certificate files."))
        self.stdout.write(f"Certificate: {cert_file.resolve()}")
        self.stdout.write(f"Private key: {key_file.resolve()}")
        self.stdout.write("SAN hosts: " + ", ".join(hosts))
