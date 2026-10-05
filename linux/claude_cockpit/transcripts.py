"""Reads token usage out of Claude Code's JSON Lines transcripts.

A port of `CockpitCore/TranscriptParser.swift`, reading line by line rather than loading
whole files, because an active session's transcript grows without bound.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

#: Placeholder model on replies Claude Code generates itself; they consume no tokens.
SYNTHETIC_MODEL = "<synthetic>"
#: Most lines are prompts and tool results; skip them without decoding.
USAGE_MARKER = '"usage"'


@dataclass(frozen=True)
class ReplyUsage:
    """The tokens one Claude reply consumed, as recorded in a Claude Code transcript."""

    #: Identifies the reply across lines and files: its message id and request id.
    id: str
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_write_5m_tokens: int
    cache_write_1h_tokens: int


def replies_in(path: Path) -> Iterator[ReplyUsage]:
    """Yields one entry per assistant line that carries usage.

    Claude Code writes a reply as one line per content block, so the same reply can
    appear several times; `ClaudeCostEstimator` merges them.
    """
    try:
        handle = path.open("r", encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            if USAGE_MARKER not in line:
                continue
            reply = _reply_from(line)
            if reply is not None:
                yield reply


def _reply_from(line: str) -> ReplyUsage | None:
    try:
        entry = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(entry, dict) or entry.get("type") != "assistant":
        return None

    message = entry.get("message")
    if not isinstance(message, dict):
        return None
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None

    message_id = message.get("id")
    model = message.get("model")
    if not isinstance(message_id, str) or not isinstance(model, str):
        return None
    if model == SYNTHETIC_MODEL:
        return None

    timestamp = _timestamp(entry.get("timestamp"))
    if timestamp is None:
        return None

    cache_writes = usage.get("cache_creation")
    cache_write_1h = (
        _tokens(cache_writes, "ephemeral_1h_input_tokens")
        if isinstance(cache_writes, dict)
        else 0
    )
    request_id = entry.get("requestId")

    return ReplyUsage(
        id=f"{message_id}|{request_id if isinstance(request_id, str) else ''}",
        timestamp=timestamp,
        model=model,
        input_tokens=_tokens(usage, "input_tokens"),
        output_tokens=_tokens(usage, "output_tokens"),
        cache_read_tokens=_tokens(usage, "cache_read_input_tokens"),
        # Without a breakdown, every cache write is the default five-minute kind.
        cache_write_5m_tokens=_tokens(usage, "cache_creation_input_tokens") - cache_write_1h,
        cache_write_1h_tokens=cache_write_1h,
    )


def _tokens(counts: dict, key: str) -> int:
    value = counts.get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _timestamp(raw: object) -> datetime | None:
    if not isinstance(raw, str):
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
