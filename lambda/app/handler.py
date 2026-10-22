"""Lambda entry point: Anthropic Inference hooks -> Netskope AI Guardrails on Demand.

Routes (behind API Gateway, which enforces the API key and source-IP allowlist):
  POST <any path>  : prompt or tool_call frame -> 200 {"action": "allow"|"deny"}
  GET  /healthz    : liveness probe (200)

Fail-closed contract: anything that prevents a verdict (bad signature is a 401,
backend or config failure is a 502) is a non-200 response. Anthropic treats that
as a webhook failure and applies the organization's fail mode. A deny is never
signalled with an error status.
"""
from __future__ import annotations

import base64
import json
import logging
import re
import time
from typing import Any

from . import aigd, frames, params, signing
from .config import Settings, load_settings

logger = logging.getLogger("aigd_webhook")

DENY_REASON_MAX = 500
REFERENCE_ID_MAX = 50
_REFERENCE_ID_INVALID = re.compile(r"[^A-Za-z0-9._:/-]")


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _header(headers: dict[str, str], name: str) -> str | None:
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered:
            return value
    return None


def _body_bytes(event: dict[str, Any]) -> bytes:
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body)
    return body.encode("utf-8")


def _reference_id(request_id: str) -> str | None:
    """request_id, sanitized to Anthropic's charset and length limit (or dropped)."""
    cleaned = _REFERENCE_ID_INVALID.sub("", request_id)[:REFERENCE_ID_MAX]
    return cleaned or None


def _deny_reason(categories: list[str]) -> str:
    if categories:
        reason = "Blocked by Netskope AI Guardrails: " + ", ".join(categories)
    else:
        reason = "Blocked by Netskope AI Guardrails."
    return reason[:DENY_REASON_MAX]


def _handle_post(event: dict[str, Any], settings: Settings) -> dict[str, Any]:
    headers = event.get("headers") or {}
    body = _body_bytes(event)

    if not signing.verify(params.signing_secrets(settings), headers, body):
        logger.warning("rejected request: signature check failed")
        return _response(401, {"error": "invalid_signature"})

    try:
        frame = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _response(400, {"error": "invalid_json"})
    if not isinstance(frame, dict):
        return _response(400, {"error": "invalid_frame"})

    webhook_id = _header(headers, "webhook-id") or ""
    request_id = str(frame.get("request_id") or "")
    if request_id != webhook_id:
        logger.warning("rejected request: request_id does not match webhook-id")
        return _response(400, {"error": "request_id_mismatch"})

    frame_type = frames.frame_type(frame)
    if frame_type not in frames.SUPPORTED_FRAME_TYPES:
        # Forward compatibility: a new event type is not a reason to reject it.
        logger.warning("unrecognized frame type %.32r; allowing", frame_type)
        return _response(200, {"action": "allow"})

    text = frames.inspectable_text(frame)
    if text is None:
        logger.info("request_id=%s type=%s nothing to inspect", request_id, frame_type)
        return _response(200, {"action": "allow"})

    started = time.monotonic()
    evaluation = aigd.evaluate(
        text,
        url=settings.aigd_url,
        profile_id=settings.aigd_profile_id,
        timeout=settings.aigd_timeout_seconds,
        tls_context=params.tls_context(settings),
    )
    logger.info(
        "request_id=%s type=%s verdict=%s categories=%d latency_ms=%d",
        request_id,
        frame_type,
        "deny" if evaluation.matched else "allow",
        len(evaluation.categories),
        int((time.monotonic() - started) * 1000),
    )

    if evaluation.matched:
        return _response(
            200,
            {
                "action": "deny",
                "deny_reason": _deny_reason(evaluation.categories),
                "reference_id": _reference_id(request_id),
            },
        )
    return _response(200, {"action": "allow"})


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    settings = load_settings()
    logger.setLevel(settings.log_level)

    method = (event.get("httpMethod") or "").upper()
    path = (event.get("path") or "/").rstrip("/") or "/"
    if method == "GET" and path == "/healthz":
        return _response(200, {"status": "ok"})
    if method != "POST":
        return _response(405, {"error": "method_not_allowed"})

    try:
        return _handle_post(event, settings)
    except Exception as exc:  # fail closed: Anthropic applies the org's fail mode
        logger.error("webhook failure: %s", type(exc).__name__)
        logger.debug("webhook failure detail", exc_info=True)
        return _response(502, {"error": "inspection_failed"})
