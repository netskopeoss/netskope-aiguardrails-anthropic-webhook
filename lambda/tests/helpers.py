"""Shared test helpers: signing a request the way Anthropic does, and fake backends."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from typing import Any

TEST_SECRET_KEY = b"0123456789abcdef0123456789abcdef"
TEST_SECRET = "whsec_" + base64.b64encode(TEST_SECRET_KEY).decode()
OTHER_SECRET = "whsec_" + base64.b64encode(b"fedcba9876543210fedcba9876543210").decode()


def sign(secret: str, message_id: str, timestamp: int, body: bytes) -> str:
    key = base64.b64decode(secret[len("whsec_"):])
    mac = hmac.new(key, f"{message_id}.{timestamp}.".encode() + body, hashlib.sha256).digest()
    return "v1," + base64.b64encode(mac).decode()


def signed_headers(
    body: bytes,
    *,
    secret: str = TEST_SECRET,
    message_id: str = "req_test_1",
    timestamp: int | None = None,
) -> dict[str, str]:
    stamp = int(time.time()) if timestamp is None else timestamp
    return {
        "webhook-id": message_id,
        "webhook-timestamp": str(stamp),
        "webhook-signature": sign(secret, message_id, stamp, body),
        "content-type": "application/json",
    }


def api_gateway_event(
    body: dict[str, Any] | bytes | str,
    *,
    headers: dict[str, str] | None = None,
    method: str = "POST",
    path: str = "/",
) -> dict[str, Any]:
    if isinstance(body, dict):
        raw = json.dumps(body).encode()
    elif isinstance(body, str):
        raw = body.encode()
    else:
        raw = body
    return {
        "httpMethod": method,
        "path": path,
        "headers": headers or {},
        "body": raw.decode("utf-8", errors="replace"),
        "isBase64Encoded": False,
    }


class FakeOpener:
    """Stands in for urllib.request.urlopen. Returns a canned body or raises."""

    def __init__(self, body: bytes | None = None, *, status: int = 200, error: Exception | None = None):
        self.body = body
        self.status = status
        self.error = error
        self.calls: list[dict[str, Any]] = []

    def __call__(self, request, timeout=None, context=None):
        self.calls.append(
            {
                "url": request.full_url,
                "body": json.loads(request.data.decode()),
                "timeout": timeout,
                "context": context,
            }
        )
        if self.error is not None:
            raise self.error
        return FakeResponse(self.body, self.status)


class FakeResponse:
    def __init__(self, body: bytes, status: int):
        self._body = body
        self.status = status

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def guardrails_response(verdict: str, categories: list[str] | None = None) -> bytes:
    details = [{"category": c, "confidence": "high"} for c in (categories or [])]
    data: dict[str, Any] = {"verdict": verdict}
    if verdict == "Match":
        data["matchDetails"] = [{"profileMatched": "AIGR on demand", "profileDetails": details}]
    return json.dumps({"success": True, "data": data}).encode()
