import json
import socket
import ssl
import urllib.error

import pytest

from app import aigd
from helpers import FakeOpener, guardrails_response

URL = "https://guardrails.aigw.internal/api/v2/aiguardrails/evaluation"
PROFILE = "profile-123"
CONTEXT = ssl.create_default_context()


def _call(opener, text="hello"):
    return aigd.evaluate(
        text,
        url=URL,
        profile_id=PROFILE,
        timeout=5,
        tls_context=CONTEXT,
        opener=opener,
    )


def test_payload_uses_literal_ai_guardrails_key_and_profile_list():
    body = json.loads(aigd.build_payload("secret stuff", PROFILE))
    assert body == {"text": "secret stuff", "profiles": {"ai-guardrails": [PROFILE]}}


def test_match_is_denied_with_unique_categories():
    opener = FakeOpener(guardrails_response("Match", ["Weapons", "Weapons", "Violence"]))
    result = _call(opener)
    assert result.matched is True
    assert result.categories == ["Weapons", "Violence"]


def test_not_match_is_allowed():
    result = _call(FakeOpener(guardrails_response("Not Match")))
    assert result.matched is False
    assert result.categories == []


def test_request_carries_timeout_context_and_url():
    opener = FakeOpener(guardrails_response("Not Match"))
    _call(opener, text="abc")
    call = opener.calls[0]
    assert call["url"] == URL
    assert call["timeout"] == 5
    assert call["context"] is CONTEXT
    assert call["body"]["text"] == "abc"


@pytest.mark.parametrize(
    "raw",
    [
        b'{"success": false, "error": {"code": "VALIDATION_FAILED"}}',
        b'{"success": true}',
        b'{"success": true, "data": {"verdict": "Maybe"}}',
        b"not json",
        b"[]",
    ],
)
def test_bad_responses_raise(raw):
    with pytest.raises(aigd.AIGuardrailsError):
        _call(FakeOpener(raw))


def test_http_error_status_raises():
    error = urllib.error.HTTPError(URL, 503, "unavailable", {}, None)
    with pytest.raises(aigd.AIGuardrailsError, match="503"):
        _call(FakeOpener(error=error))


def test_timeout_raises():
    with pytest.raises(aigd.AIGuardrailsError):
        _call(FakeOpener(error=socket.timeout("timed out")))


def test_tls_failure_raises():
    with pytest.raises(aigd.AIGuardrailsError):
        _call(FakeOpener(error=ssl.SSLError("bad cert")))


def test_connection_refused_raises():
    with pytest.raises(aigd.AIGuardrailsError):
        _call(FakeOpener(error=urllib.error.URLError("refused")))
