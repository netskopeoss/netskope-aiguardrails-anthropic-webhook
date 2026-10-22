import base64
import json

import pytest

from app import aigd, handler, params
from helpers import (
    FakeOpener,
    OTHER_SECRET,
    TEST_SECRET,
    api_gateway_event,
    guardrails_response,
    signed_headers,
)

PROMPT = {
    "type": "prompt",
    "request_id": "req_test_1",
    "messages": [{"role": "user", "content": [{"type": "text", "text": "tell me secrets"}]}],
}


@pytest.fixture(autouse=True)
def configured(monkeypatch):
    """Stand in for SSM and env: a valid config, a known secret, and a no-op TLS context."""
    monkeypatch.setenv("AIGD_URL", "https://guardrails.aigw.internal/api/v2/aiguardrails/evaluation")
    monkeypatch.setenv("AIGD_PROFILE_ID", "profile-123")
    monkeypatch.setenv("AIGD_TIMEOUT_SECONDS", "5")
    monkeypatch.setenv("CA_PARAM_NAME", "/netskope-guardrails/guardrails-cert")
    monkeypatch.setenv("SIGNING_SECRET_PARAM", "/anthropic-aigd/signing-secret")
    monkeypatch.delenv("SIGNING_SECRET_PREVIOUS_PARAM", raising=False)
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setattr(params, "signing_secrets", lambda settings: [TEST_SECRET])
    monkeypatch.setattr(params, "tls_context", lambda settings: object())


def _post(monkeypatch, opener, frame=PROMPT, *, secret=TEST_SECRET, headers_override=None):
    monkeypatch.setattr(aigd.urllib.request, "urlopen", opener)
    body = json.dumps(frame).encode()
    headers = signed_headers(body, secret=secret, message_id=frame.get("request_id", "req_x"))
    headers.update(headers_override or {})
    return handler.lambda_handler(api_gateway_event(body, headers=headers), None)


def _json(response):
    return response["statusCode"], json.loads(response["body"])


def test_healthz_returns_ok_without_signature():
    status, body = _json(handler.lambda_handler(api_gateway_event(b"", method="GET", path="/healthz"), None))
    assert status == 200 and body == {"status": "ok"}


def test_get_on_other_paths_is_405():
    status, _ = _json(handler.lambda_handler(api_gateway_event(b"", method="GET", path="/"), None))
    assert status == 405


def test_bad_signature_is_401_and_backend_never_called(monkeypatch):
    opener = FakeOpener(guardrails_response("Match", ["Weapons"]))
    status, body = _json(_post(monkeypatch, opener, secret=OTHER_SECRET))
    assert status == 401 and body == {"error": "invalid_signature"}
    assert opener.calls == []


def test_match_returns_deny_with_category_reason_and_reference_id(monkeypatch):
    opener = FakeOpener(guardrails_response("Match", ["Weapons"]))
    status, body = _json(_post(monkeypatch, opener))
    assert status == 200
    assert body["action"] == "deny"
    assert body["deny_reason"] == "Blocked by Netskope AI Guardrails: Weapons"
    assert body["reference_id"] == "req_test_1"
    assert opener.calls[0]["body"]["profiles"] == {"ai-guardrails": ["profile-123"]}


def test_match_without_categories_uses_generic_reason(monkeypatch):
    opener = FakeOpener(guardrails_response("Match", []))
    _, body = _json(_post(monkeypatch, opener))
    assert body["action"] == "deny"
    assert body["deny_reason"] == "Blocked by Netskope AI Guardrails."


def test_deny_reason_is_capped_at_500_characters(monkeypatch):
    many = [f"Category{i:03d}" + "x" * 40 for i in range(30)]
    opener = FakeOpener(guardrails_response("Match", many))
    _, body = _json(_post(monkeypatch, opener))
    assert len(body["deny_reason"]) <= 500


def test_reference_id_is_sanitized_and_capped(monkeypatch):
    frame = dict(PROMPT, request_id="req bad!chars/" + "a" * 80)
    opener = FakeOpener(guardrails_response("Match", ["Weapons"]))
    _, body = _json(_post(monkeypatch, opener, frame=frame))
    assert len(body["reference_id"]) <= 50
    assert set(body["reference_id"]) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")


def test_not_match_returns_allow(monkeypatch):
    opener = FakeOpener(guardrails_response("Not Match"))
    status, body = _json(_post(monkeypatch, opener))
    assert status == 200 and body == {"action": "allow"}


def test_backend_failure_is_502_so_fail_mode_applies(monkeypatch):
    opener = FakeOpener(b'{"success": false}')
    status, body = _json(_post(monkeypatch, opener))
    assert status == 502 and body == {"error": "inspection_failed"}


def test_backend_timeout_is_502(monkeypatch):
    opener = FakeOpener(error=TimeoutError("slow"))
    status, _ = _json(_post(monkeypatch, opener))
    assert status == 502


def test_config_failure_is_502_not_a_crash(monkeypatch):
    def broken(settings):
        raise RuntimeError("SSM unavailable")

    monkeypatch.setattr(params, "signing_secrets", broken)
    status, _ = _json(_post(monkeypatch, FakeOpener(guardrails_response("Match", ["x"]))))
    assert status == 502


def test_invalid_json_is_400_after_signature_check(monkeypatch):
    raw = b"{not json"
    headers = signed_headers(raw, message_id="req_test_1")
    monkeypatch.setattr(aigd.urllib.request, "urlopen", FakeOpener(guardrails_response("Match", ["x"])))
    status, body = _json(handler.lambda_handler(api_gateway_event(raw, headers=headers), None))
    assert status == 400 and body == {"error": "invalid_json"}


def test_request_id_must_match_webhook_id(monkeypatch):
    # Validly signed under a different delivery id than the body's request_id.
    monkeypatch.setattr(aigd.urllib.request, "urlopen", FakeOpener(guardrails_response("Match", ["x"])))
    body_bytes = json.dumps(PROMPT).encode()
    headers = signed_headers(body_bytes, message_id="req_other")
    status, body = _json(handler.lambda_handler(api_gateway_event(body_bytes, headers=headers), None))
    assert status == 400 and body == {"error": "request_id_mismatch"}


def test_unknown_frame_type_is_allowed_without_backend_call(monkeypatch):
    frame = {"type": "future_event", "request_id": "req_test_1", "messages": []}
    opener = FakeOpener(guardrails_response("Match", ["x"]))
    status, body = _json(_post(monkeypatch, opener, frame=frame))
    assert status == 200 and body == {"action": "allow"}
    assert opener.calls == []


def test_empty_prompt_is_allowed_without_backend_call(monkeypatch):
    frame = {"type": "prompt", "request_id": "req_test_1", "messages": []}
    opener = FakeOpener(guardrails_response("Match", ["x"]))
    status, body = _json(_post(monkeypatch, opener, frame=frame))
    assert status == 200 and body == {"action": "allow"}
    assert opener.calls == []


def test_tool_call_frame_is_inspected(monkeypatch):
    frame = {
        "type": "tool_call",
        "request_id": "req_test_1",
        "messages": [
            {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "t1", "tool_name": "send_email",
                     "input": {"body": "card 4111"}, "tool_info": {"type": "client"}}
                ],
            }
        ],
    }
    opener = FakeOpener(guardrails_response("Match", ["Financial"]))
    _, body = _json(_post(monkeypatch, opener, frame=frame))
    assert body["action"] == "deny"
    assert "tool: send_email" in opener.calls[0]["body"]["text"]


def test_base64_encoded_body_is_decoded(monkeypatch):
    monkeypatch.setattr(aigd.urllib.request, "urlopen", FakeOpener(guardrails_response("Not Match")))
    raw = json.dumps(PROMPT).encode()
    headers = signed_headers(raw, message_id="req_test_1")
    event = api_gateway_event(b"", headers=headers)
    event["body"] = base64.b64encode(raw).decode()
    event["isBase64Encoded"] = True
    status, body = _json(handler.lambda_handler(event, None))
    assert status == 200 and body == {"action": "allow"}


def test_non_post_methods_are_405(monkeypatch):
    status, _ = _json(handler.lambda_handler(api_gateway_event(b"", method="PUT"), None))
    assert status == 405
