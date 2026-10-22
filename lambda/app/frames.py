"""Turn an Anthropic Inference hooks frame into the text AI Guardrails inspects.

Two frame types (top-level ``type``):
  - "prompt":    the whole transcript up to inference. Every message is inspected.
  - "tool_call": only the latest message (the assistant turn that produced the
                 tool calls). Earlier turns were already covered by the prompt frame.

Inspectable pieces, in transcript order:
  - text.text
  - tool_result.content (text)
  - attachment.text (when present)
  - tool_use: "tool: <tool_name>" plus the JSON-encoded input, so data smuggled
    into tool arguments is scanned too.

Unknown block types are skipped, never rejected (forward compatibility).
"""
from __future__ import annotations

import json
from typing import Any, Optional

PROMPT_FRAME = "prompt"
TOOL_CALL_FRAME = "tool_call"
SUPPORTED_FRAME_TYPES = (PROMPT_FRAME, TOOL_CALL_FRAME)


def _block_text(block: Any) -> Optional[str]:
    if not isinstance(block, dict):
        return None
    kind = block.get("type")
    if kind == "text":
        value = block.get("text")
    elif kind == "tool_result":
        value = block.get("content")
    elif kind == "attachment":
        value = block.get("text")
    elif kind == "tool_use":
        name = block.get("tool_name")
        arguments = block.get("input", {})
        try:
            encoded = json.dumps(arguments, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            encoded = str(arguments)
        return f"tool: {name}\n{encoded}"
    else:
        return None
    return value if isinstance(value, str) else None


def _messages_text(messages: list[Any]) -> list[str]:
    parts: list[str] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        for block in message.get("content") or []:
            text = _block_text(block)
            if text:
                parts.append(text)
    return parts


def frame_type(frame: dict) -> Optional[str]:
    value = frame.get("type")
    return value if isinstance(value, str) else None


def inspectable_text(frame: dict) -> Optional[str]:
    """The document to send to AI Guardrails, or None if there is nothing to inspect."""
    messages = frame.get("messages")
    if not isinstance(messages, list):
        return None
    if frame_type(frame) == TOOL_CALL_FRAME:
        messages = messages[-1:]
    parts = _messages_text(messages)
    return "\n".join(parts) if parts else None
