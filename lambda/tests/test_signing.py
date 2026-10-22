import time

from app import signing
from helpers import OTHER_SECRET, TEST_SECRET, sign

BODY = b'{"type":"prompt","request_id":"req_test_1"}'
NOW = 1_800_000_000.0


def _headers(secret=TEST_SECRET, message_id="req_test_1", timestamp=int(NOW), body=BODY, extra=None):
    headers = {
        "webhook-id": message_id,
        "webhook-timestamp": str(timestamp),
        "webhook-signature": sign(secret, message_id, timestamp, body),
    }
    headers.update(extra or {})
    return headers


def test_valid_signature_is_accepted():
    assert signing.verify([TEST_SECRET], _headers(), BODY, now=NOW)


def test_wrong_secret_is_rejected():
    assert not signing.verify([OTHER_SECRET], _headers(), BODY, now=NOW)


def test_tampered_body_is_rejected():
    assert not signing.verify([TEST_SECRET], _headers(), BODY + b" ", now=NOW)


def test_stale_timestamp_is_rejected_in_both_directions():
    old = _headers(timestamp=int(NOW) - 301)
    future = _headers(timestamp=int(NOW) + 301)
    assert not signing.verify([TEST_SECRET], old, BODY, now=NOW)
    assert not signing.verify([TEST_SECRET], future, BODY, now=NOW)


def test_timestamp_inside_tolerance_is_accepted():
    edge = _headers(timestamp=int(NOW) - 299)
    assert signing.verify([TEST_SECRET], edge, BODY, now=NOW)


def test_any_of_several_space_separated_signatures_matches():
    good = sign(TEST_SECRET, "req_test_1", int(NOW), BODY)
    headers = _headers()
    headers["webhook-signature"] = "v1,AAAA " + good + " v1,BBBB"
    assert signing.verify([TEST_SECRET], headers, BODY, now=NOW)


def test_header_names_are_matched_case_insensitively():
    headers = {
        "Webhook-Id": "req_test_1",
        "WEBHOOK-TIMESTAMP": str(int(NOW)),
        "Webhook-Signature": sign(TEST_SECRET, "req_test_1", int(NOW), BODY),
    }
    assert signing.verify([TEST_SECRET], headers, BODY, now=NOW)


def test_missing_headers_are_rejected():
    headers = _headers()
    del headers["webhook-signature"]
    assert not signing.verify([TEST_SECRET], headers, BODY, now=NOW)


def test_non_numeric_timestamp_is_rejected():
    headers = _headers()
    headers["webhook-timestamp"] = "yesterday"
    assert not signing.verify([TEST_SECRET], headers, BODY, now=NOW)


def test_secret_without_whsec_prefix_or_bad_base64_is_skipped():
    assert not signing.verify(["not-a-secret", "whsec_!!!"], _headers(), BODY, now=NOW)


def test_rotation_accepts_previous_secret_too():
    assert signing.verify([OTHER_SECRET, TEST_SECRET], _headers(), BODY, now=NOW)


def test_default_now_uses_wall_clock():
    headers = _headers(timestamp=int(time.time()))
    assert signing.verify([TEST_SECRET], headers, BODY)
