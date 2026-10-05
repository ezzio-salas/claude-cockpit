import json
from datetime import datetime, timedelta, timezone

import pytest

from claude_cockpit.cost import ClaudeCostEstimator
from claude_cockpit.pricing import cost_text, rates_for
from claude_cockpit.transcripts import replies_in

NOW = datetime(2026, 10, 5, 18, 0, tzinfo=timezone.utc)


def reply_line(
    message_id="msg_1",
    request_id="req_1",
    model="claude-sonnet-5",
    when=None,
    output=100,
    input_=1_000,
    cache_read=0,
    cache_write=0,
    cache_write_1h=None,
):
    usage = {
        "input_tokens": input_,
        "output_tokens": output,
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_write,
    }
    if cache_write_1h is not None:
        usage["cache_creation"] = {"ephemeral_1h_input_tokens": cache_write_1h}
    return json.dumps(
        {
            "type": "assistant",
            "requestId": request_id,
            "timestamp": (when or NOW).isoformat().replace("+00:00", "Z"),
            "message": {"id": message_id, "model": model, "usage": usage},
        }
    )


def write_transcript(root, name, lines):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    return path


# --- pricing -------------------------------------------------------------


def test_known_model():
    assert rates_for("claude-sonnet-5").input == 2


def test_dated_snapshot_is_priced_as_its_base_model():
    assert rates_for("claude-haiku-4-5-20251001") == rates_for("claude-haiku-4-5")


def test_unknown_model_is_not_guessed():
    assert rates_for("claude-something-new") is None
    assert rates_for("gpt-5") is None


def test_standard_cache_multiples():
    rates = rates_for("claude-opus-5")
    assert rates.cache_write_5m == pytest.approx(rates.input * 1.25)
    assert rates.cache_write_1h == pytest.approx(rates.input * 2)
    assert rates.cache_read == pytest.approx(rates.input * 0.1)


@pytest.mark.parametrize(
    "dollars,partial,expected",
    [(3.4, False, "~$3.40"), (9.999, False, "~$10.00"), (140.2, False, "~$140"),
     (12.0, True, "~$12+"), (0, False, "~$0.00")],
)
def test_cost_text(dollars, partial, expected):
    assert cost_text(dollars, partial) == expected


# --- transcript parsing --------------------------------------------------


def test_reads_usage_from_an_assistant_line(tmp_path):
    path = write_transcript(tmp_path, "a.jsonl", [reply_line(output=42, cache_write_1h=7)])
    (reply,) = list(replies_in(path))
    assert reply.output_tokens == 42
    assert reply.cache_write_1h_tokens == 7
    assert reply.id == "msg_1|req_1"


def test_skips_prompts_tool_results_and_synthetic_replies(tmp_path):
    path = write_transcript(tmp_path, "a.jsonl", [
        json.dumps({"type": "user", "message": {"content": "hi"}}),
        json.dumps({"type": "assistant", "message": {"id": "m", "model": "<synthetic>",
                                                     "usage": {"output_tokens": 1}},
                    "timestamp": NOW.isoformat()}),
        "not json at all",
        reply_line(),
    ])
    assert [r.id for r in replies_in(path)] == ["msg_1|req_1"]


def test_a_missing_file_yields_nothing(tmp_path):
    assert list(replies_in(tmp_path / "gone.jsonl")) == []


# --- estimator -----------------------------------------------------------


def test_returns_none_without_a_transcripts_directory(tmp_path):
    assert ClaudeCostEstimator(tmp_path / "absent").estimate(NOW) is None


def test_prices_a_single_reply(tmp_path):
    # 1M input at $2 + 1M output at $10 = $12.
    write_transcript(tmp_path, "p/a.jsonl", [reply_line(input_=1_000_000, output=1_000_000)])
    cost = ClaudeCostEstimator(tmp_path).estimate(NOW)
    assert cost.last_7_days.dollars == pytest.approx(12.0)


def test_merges_a_reply_repeated_across_content_blocks_and_files(tmp_path):
    """The same reply, written once per block and again in a resumed session."""
    write_transcript(tmp_path, "p/a.jsonl", [
        reply_line(output=10, input_=1_000_000),
        reply_line(output=250, input_=1_000_000),  # the finished line
    ])
    write_transcript(tmp_path, "p/b.jsonl", [reply_line(output=120, input_=1_000_000)])
    cost = ClaudeCostEstimator(tmp_path).estimate(NOW)
    # Counted once, at 250 output tokens: $2 input + 250 * $10/1M.
    assert cost.last_7_days.dollars == pytest.approx(2.0 + 250 * 10 / 1_000_000)


def test_today_and_the_week_are_counted_separately(tmp_path):
    three_days_ago = NOW - timedelta(days=3)
    write_transcript(tmp_path, "p/a.jsonl", [
        reply_line(message_id="old", request_id="r1", when=three_days_ago,
                   input_=1_000_000, output=0),
        reply_line(message_id="new", request_id="r2", when=NOW,
                   input_=1_000_000, output=0),
    ])
    cost = ClaudeCostEstimator(tmp_path).estimate(NOW)
    assert cost.last_7_days.dollars == pytest.approx(4.0)
    assert cost.today.dollars == pytest.approx(2.0)


def test_replies_older_than_the_window_are_ignored(tmp_path):
    write_transcript(tmp_path, "p/a.jsonl", [
        reply_line(message_id="ancient", request_id="r0",
                   when=NOW - timedelta(days=30), input_=1_000_000),
        reply_line(message_id="recent", request_id="r1", when=NOW, input_=1_000_000),
    ])
    cost = ClaudeCostEstimator(tmp_path).estimate(NOW)
    assert cost.last_7_days.dollars == pytest.approx(2.0 + 100 * 10 / 1_000_000)


def test_an_unpriced_model_marks_only_the_window_it_was_used_in(tmp_path):
    """The macOS build flags both rows; a model used days ago must not mark today."""
    write_transcript(tmp_path, "p/a.jsonl", [
        reply_line(message_id="old", request_id="r1", model="claude-unknown-9",
                   when=NOW - timedelta(days=4)),
        reply_line(message_id="new", request_id="r2", model="claude-sonnet-5", when=NOW),
    ])
    cost = ClaudeCostEstimator(tmp_path).estimate(NOW)
    assert cost.last_7_days.unpriced_models == ("claude-unknown-9",)
    assert cost.last_7_days.is_partial
    assert cost.today.unpriced_models == ()
    assert not cost.today.is_partial


def test_unchanged_transcripts_are_not_re_read(tmp_path):
    path = write_transcript(tmp_path, "p/a.jsonl", [reply_line(input_=1_000_000, output=0)])
    estimator = ClaudeCostEstimator(tmp_path)
    assert estimator.estimate(NOW).last_7_days.dollars == pytest.approx(2.0)

    reads = []
    original = type(path).open

    def counting_open(self, *args, **kwargs):
        reads.append(self)
        return original(self, *args, **kwargs)

    type(path).open = counting_open
    try:
        estimator.estimate(NOW)
    finally:
        type(path).open = original
    assert reads == []


def test_an_appended_transcript_is_re_read(tmp_path):
    import os

    path = write_transcript(tmp_path, "p/a.jsonl", [
        reply_line(message_id="one", request_id="r1", input_=1_000_000, output=0)
    ])
    estimator = ClaudeCostEstimator(tmp_path)
    assert estimator.estimate(NOW).last_7_days.dollars == pytest.approx(2.0)

    with path.open("a") as handle:
        handle.write(reply_line(message_id="two", request_id="r2",
                                input_=1_000_000, output=0) + "\n")
    # Make the change visible even on a filesystem with coarse timestamps.
    stat = path.stat()
    os.utime(path, (stat.st_atime, stat.st_mtime + 1))

    assert estimator.estimate(NOW).last_7_days.dollars == pytest.approx(4.0)
