import json
from pathlib import Path

from app import frames

FIXTURES = Path(__file__).parent / "fixtures"


def _prompt(messages):
    return {"type": "prompt", "request_id": "req_1", "messages": messages}


def test_prompt_fixture_extracts_text_and_attachment_text():
    frame = json.loads((FIXTURES / "prompt_frame.json").read_text(encoding="utf-8"))
    text = frames.inspectable_text(frame)
    assert "Summarize the attached report." in text
    assert "Q2 revenue grew 14%" in text


def test_text_tool_result_and_attachment_are_collected_in_order():
    frame = _prompt(
        [
            {"role": "user", "content": [{"type": "text", "text": "first"}]},
            {"role": "assistant", "content": [{"type": "text", "text": "second"}]},
            {"role": "user", "content": [{"type": "tool_result", "content": "third", "is_error": False}]},
            {"role": "user", "content": [{"type": "attachment", "file_name": "a.txt", "text": "fourth"}]},
        ]
    )
    assert frames.inspectable_text(frame) == "first\nsecond\nthird\nfourth"


def test_tool_use_name_and_input_are_inspected():
    frame = _prompt(
        [
            {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "t1", "tool_name": "read_file", "input": {"path": "x.txt"}}
                ],
            }
        ]
    )
    text = frames.inspectable_text(frame)
    assert "tool: read_file" in text
    assert '"path": "x.txt"' in text


def test_image_and_unknown_blocks_are_skipped_not_rejected():
    frame = _prompt(
        [
            {
                "role": "user",
                "content": [
                    {"type": "attachment", "file_name": "pic.png", "media_type": "image/png", "text": None},
                    {"type": "brand_new_block", "payload": 42},
                    "not even a dict",
                    {"type": "text", "text": "visible"},
                ],
            }
        ]
    )
    assert frames.inspectable_text(frame) == "visible"


def test_nothing_inspectable_returns_none():
    assert frames.inspectable_text(_prompt([])) is None
    assert frames.inspectable_text(_prompt([{"role": "user", "content": []}])) is None
    assert frames.inspectable_text({"type": "prompt"}) is None


def test_tool_call_frame_inspects_only_latest_message():
    frame = {
        "type": "tool_call",
        "request_id": "req_2",
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": "old prompt"}]},
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "running it"},
                    {"type": "tool_use", "id": "t2", "tool_name": "web_search",
                     "input": {"query": "acme"}, "tool_info": {"type": "application"}},
                ],
            },
        ],
    }
    text = frames.inspectable_text(frame)
    assert "old prompt" not in text
    assert "running it" in text
    assert "tool: web_search" in text


def test_frame_type_helpers():
    assert frames.frame_type({"type": "prompt"}) == "prompt"
    assert frames.frame_type({"type": 7}) is None
    assert frames.frame_type({}) is None
    assert "tool_call" in frames.SUPPORTED_FRAME_TYPES
