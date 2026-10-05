"""What recent Claude Code usage on this machine would have cost at API list prices.

A port of `CockpitCore/ClaudeCostEstimator.swift`, with two changes:

* replies outside the seven-day window are dropped as each transcript is parsed, so the
  cache holds only what an estimate can use rather than a whole session's history;
* each window carries its own set of unpriced models, so a model used five days ago no
  longer marks today's figure as incomplete.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .periods import WEEK, start_of_today
from .pricing import TokenRates, rates_for
from .transcripts import ReplyUsage, replies_in

log = logging.getLogger(__name__)


def default_transcripts() -> Path:
    return Path.home() / ".claude/projects"


@dataclass(frozen=True)
class CostWindow:
    """One period's estimate."""

    dollars: float
    #: Models used in this period that have no known price. Their usage is missing from `dollars`.
    unpriced_models: tuple[str, ...] = ()

    @property
    def is_partial(self) -> bool:
        return bool(self.unpriced_models)


@dataclass(frozen=True)
class ClaudeCost:
    #: Since local midnight.
    today: CostWindow
    #: Over the last seven days.
    last_7_days: CostWindow


@dataclass
class _ParsedTranscript:
    modified: float
    size: int
    replies: dict[str, ReplyUsage] = field(default_factory=dict)


class ClaudeCostEstimator:
    """Estimates `ClaudeCost` from the token counts in Claude Code's local transcripts.

    `estimate` blocks on file I/O, so callers run it off the UI thread.
    """

    def __init__(self, transcripts: Path | None = None) -> None:
        self._transcripts = transcripts or default_transcripts()
        #: Transcripts already parsed, so each refresh re-reads only the files that changed.
        self._parsed: dict[Path, _ParsedTranscript] = {}

    def estimate(self, now: datetime) -> ClaudeCost | None:
        """Returns None when the transcripts directory does not exist."""
        week_ago = now - WEEK
        recent = self._transcripts_modified_since(week_ago)
        if recent is None:
            return None
        self._refresh_parsed(recent, week_ago)

        midnight = start_of_today(now)
        today = 0.0
        last_7_days = 0.0
        unpriced_today: set[str] = set()
        unpriced_week: set[str] = set()

        for reply in self._distinct_replies():
            if reply.timestamp < week_ago:
                continue
            is_today = reply.timestamp >= midnight
            rates = rates_for(reply.model)
            if rates is None:
                unpriced_week.add(reply.model)
                if is_today:
                    unpriced_today.add(reply.model)
                continue
            cost = _cost_of(reply, rates)
            last_7_days += cost
            if is_today:
                today += cost

        return ClaudeCost(
            today=CostWindow(today, tuple(sorted(unpriced_today))),
            last_7_days=CostWindow(last_7_days, tuple(sorted(unpriced_week))),
        )

    def _transcripts_modified_since(
        self, cutoff: datetime
    ) -> dict[Path, os.stat_result] | None:
        """The transcripts that can hold a reply newer than `cutoff`, with their stat."""
        root = self._transcripts.expanduser()
        if not root.is_dir():
            return None

        cutoff_epoch = cutoff.timestamp()
        recent: dict[Path, os.stat_result] = {}
        for path in root.rglob("*.jsonl"):
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime >= cutoff_epoch:
                recent[path] = stat
        return recent

    def _refresh_parsed(
        self, recent: dict[Path, os.stat_result], week_ago: datetime
    ) -> None:
        self._parsed = {
            path: parsed for path, parsed in self._parsed.items() if path in recent
        }
        for path, stat in recent.items():
            known = self._parsed.get(path)
            if known and known.modified == stat.st_mtime and known.size == stat.st_size:
                continue
            # A reply is written once per content block; keep the line with the most
            # output tokens, which is the finished one.
            replies: dict[str, ReplyUsage] = {}
            for reply in replies_in(path):
                if reply.timestamp < week_ago:
                    continue
                seen = replies.get(reply.id)
                if seen is None or reply.output_tokens > seen.output_tokens:
                    replies[reply.id] = reply
            self._parsed[path] = _ParsedTranscript(stat.st_mtime, stat.st_size, replies)

    def _distinct_replies(self) -> list[ReplyUsage]:
        """One entry per reply, merged across every transcript that resumes its session."""
        by_id: dict[str, ReplyUsage] = {}
        for transcript in self._parsed.values():
            for reply_id, reply in transcript.replies.items():
                seen = by_id.get(reply_id)
                if seen is None or reply.output_tokens > seen.output_tokens:
                    by_id[reply_id] = reply
        return list(by_id.values())


def _cost_of(reply: ReplyUsage, rates: TokenRates) -> float:
    dollars_per_million = (
        reply.input_tokens * rates.input
        + reply.output_tokens * rates.output
        + reply.cache_read_tokens * rates.cache_read
        + reply.cache_write_5m_tokens * rates.cache_write_5m
        + reply.cache_write_1h_tokens * rates.cache_write_1h
    )
    return dollars_per_million / 1_000_000
