"""Client for the Netskope AI Guardrails on Demand evaluation API.

POST {url}  body: {"text": "...", "profiles": {"ai-guardrails": ["<profile-id>"]}}
  - The "profiles" key must be the literal "ai-guardrails"; the value is a list of
    profile IDs. Using the wrong ID silently returns "Not Match" for everything.
  - No auth token: access is controlled at the network layer (VPC-internal ALB).
  - Success: {"success": true, "data": {"verdict": "Match" | "Not Match",
              "matchDetails": [{"profileMatched", "profileDetails": [{"category", ...}]}]}}

Every failure raises AIGuardrailsError so the handler can return a 5xx, which
Anthropic treats as a webhook failure and applies the org's fail mode.
"""
from __future__ import annotations

import json
import socket
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable

MATCH = "Match"
NOT_MATCH = "Not Match"

Opener = Callable[..., Any]


class AIGuardrailsError(RuntimeError):
    """Any failure talking to AI Guardrails or understanding its answer."""


@dataclass(frozen=True)
class Evaluation:
    matched: bool
    categories: list[str] = field(default_factory=list)


def build_payload(text: str, profile_id: str) -> bytes:
    body = {"text": text, "profiles": {"ai-guardrails": [profile_id]}}
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


def parse_response(raw: bytes) -> Evaluation:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AIGuardrailsError(f"response is not JSON: {exc}") from exc

    if not isinstance(payload, dict) or payload.get("success") is not True:
        raise AIGuardrailsError("evaluation was not successful")
    data = payload.get("data")
    if not isinstance(data, dict):
        raise AIGuardrailsError("response has no data object")

    verdict = data.get("verdict")
    if verdict not in (MATCH, NOT_MATCH):
        raise AIGuardrailsError(f"unexpected verdict: {verdict!r}")

    categories: list[str] = []
    for match in data.get("matchDetails") or []:
        if not isinstance(match, dict):
            continue
        for detail in match.get("profileDetails") or []:
            if not isinstance(detail, dict):
                continue
            category = detail.get("category")
            if isinstance(category, str) and category and category not in categories:
                categories.append(category)
    return Evaluation(matched=verdict == MATCH, categories=categories)


def evaluate(
    text: str,
    *,
    url: str,
    profile_id: str,
    timeout: float,
    tls_context: ssl.SSLContext,
    opener: Opener | None = None,
) -> Evaluation:
    request = urllib.request.Request(
        url,
        data=build_payload(text, profile_id),
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    # Resolved per call (not as a default argument) so tests can substitute urlopen.
    send = opener or urllib.request.urlopen
    try:
        with send(request, timeout=timeout, context=tls_context) as response:
            status = getattr(response, "status", 200)
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise AIGuardrailsError(f"AI Guardrails returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, socket.timeout, TimeoutError, ssl.SSLError, OSError) as exc:
        raise AIGuardrailsError(f"transport error: {type(exc).__name__}") from exc

    if status // 100 != 2:
        raise AIGuardrailsError(f"AI Guardrails returned HTTP {status}")
    return parse_response(raw)
