"""SSM Parameter Store access with a small in-process cache.

Lambda containers are reused between invocations, so the signing secret and the
CA context are fetched once per container and refreshed on a TTL. The signing
secret TTL is short so a rotation takes effect within minutes without redeploying.
"""
from __future__ import annotations

import ssl
import time
from typing import Any, Optional

from .config import Settings

SECRET_TTL_SECONDS = 300
CA_TTL_SECONDS = 3600

_ssm_client: Any = None
_cache: dict[str, tuple[float, Any]] = {}


def _client() -> Any:
    global _ssm_client
    if _ssm_client is None:
        import boto3  # bundled in the Lambda python3.12 runtime

        _ssm_client = boto3.client("ssm")
    return _ssm_client


def get_parameter(name: str, *, decrypt: bool, ttl: float) -> str:
    now = time.monotonic()
    hit = _cache.get(name)
    if hit is not None and now - hit[0] < ttl:
        return hit[1]
    response = _client().get_parameter(Name=name, WithDecryption=decrypt)
    value = response["Parameter"]["Value"]
    _cache[name] = (now, value)
    return value


def signing_secrets(settings: Settings) -> list[str]:
    """Current secret, plus the previous one while a rotation is in flight."""
    secrets = [
        get_parameter(
            settings.signing_secret_parameter_name, decrypt=True, ttl=SECRET_TTL_SECONDS
        )
    ]
    if settings.previous_signing_secret_parameter_name:
        secrets.append(
            get_parameter(
                settings.previous_signing_secret_parameter_name,
                decrypt=True,
                ttl=SECRET_TTL_SECONDS,
            )
        )
    return secrets


def tls_context(settings: Settings) -> ssl.SSLContext:
    """Verifying TLS context that trusts only the AI Guardrails self-signed CA."""
    key = f"ctx:{settings.ca_parameter_name}"
    now = time.monotonic()
    hit: Optional[tuple[float, Any]] = _cache.get(key)
    if hit is not None and now - hit[0] < CA_TTL_SECONDS:
        return hit[1]
    pem = get_parameter(settings.ca_parameter_name, decrypt=False, ttl=CA_TTL_SECONDS)
    context = ssl.create_default_context(cadata=pem)
    _cache[key] = (now, context)
    return context
