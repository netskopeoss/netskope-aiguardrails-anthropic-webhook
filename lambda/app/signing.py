"""Standard Webhooks signature verification for Anthropic Inference hooks.

Spec: https://www.standardwebhooks.com/ (see Anthropic's endpoint docs, "Verify
the signature"):
  - Headers: webhook-id, webhook-timestamp, webhook-signature (lowercase from
    Anthropic, but proxies may re-case them, so lookups are case-insensitive).
  - Signed content: "{webhook-id}.{webhook-timestamp}.{raw body bytes}".
  - Key: standard-base64 decode of the secret after the "whsec_" prefix.
  - webhook-signature: space-separated "v1,<base64 HMAC-SHA256>" values; accept
    if ANY matches, compared in constant time.
  - Reject a timestamp more than 300 seconds from our clock, either direction.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import time

TOLERANCE_SECONDS = 300
_PREFIX = "whsec_"


def _decode_secret(secret: str) -> bytes | None:
    """Return the raw HMAC key, or None if the secret is not a valid whsec_ value."""
    if not secret.startswith(_PREFIX):
        return None
    try:
        return base64.b64decode(secret[len(_PREFIX):], validate=True)
    except (binascii.Error, ValueError):
        return None


def verify(
    secrets: list[str],
    headers: dict[str, str],
    body: bytes,
    now: float | None = None,
) -> bool:
    """True if the request is signed by any of ``secrets`` and is fresh."""
    lowered = {name.lower(): value for name, value in headers.items()}
    message_id = lowered.get("webhook-id")
    timestamp = lowered.get("webhook-timestamp")
    signatures = lowered.get("webhook-signature")
    if not message_id or not timestamp or not signatures:
        return False

    try:
        signed_at = int(timestamp)
    except ValueError:
        return False
    current = time.time() if now is None else now
    if abs(current - signed_at) > TOLERANCE_SECONDS:
        return False

    signed_content = f"{message_id}.{timestamp}.".encode() + body
    candidates = signatures.split()
    for secret in secrets:
        key = _decode_secret(secret)
        if key is None:
            continue
        mac = hmac.new(key, signed_content, hashlib.sha256).digest()
        expected = "v1," + base64.b64encode(mac).decode()
        for candidate in candidates:
            if hmac.compare_digest(candidate, expected):
                return True
    return False
