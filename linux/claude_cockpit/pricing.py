"""Anthropic API list prices, in US dollars per million tokens.

A port of `CockpitCore/ModelPricing.swift`. Keep the two tables in step.
"""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class TokenRates:
    input: float
    output: float
    cache_write_5m: float
    cache_write_1h: float
    cache_read: float


def _standard(input_: float, output: float) -> TokenRates:
    """Cache prices at the usual multiples of the input price: 1.25x and 2x to write, 0.1x to read."""
    return TokenRates(
        input=input_,
        output=output,
        cache_write_5m=input_ * 1.25,
        cache_write_1h=input_ * 2,
        cache_read=input_ * 0.1,
    )


#: Standard-speed prices as published in September 2026.
#: Update this table when Anthropic changes a price or releases a model.
TABLE: dict[str, TokenRates] = {
    "claude-fable-5-1": TokenRates(10, 50, 12.50, 20, 0.25),
    "claude-fable-5": _standard(10, 50),
    "claude-opus-5-5": TokenRates(4, 20, 5, 8, 0.20),
    "claude-opus-5": _standard(5, 25),
    "claude-opus-4-8": _standard(5, 25),
    "claude-opus-4-7": _standard(5, 25),
    "claude-opus-4-6": _standard(5, 25),
    "claude-sonnet-5-5": TokenRates(2, 10, 2.50, 4, 0.20),
    "claude-sonnet-5": TokenRates(2, 10, 2.50, 4, 0.20),
    "claude-sonnet-4-6": _standard(3, 15),
    "claude-haiku-4-5": _standard(1, 5),
}

_SNAPSHOT = re.compile(r"(.+)-\d{8}")


def rates_for(model: str) -> TokenRates | None:
    """Returns None for a model with no known price, so callers report it instead of guessing."""
    exact = TABLE.get(model)
    if exact is not None:
        return exact
    # A dated snapshot such as `claude-haiku-4-5-20251001` is priced as its base model.
    snapshot = _SNAPSHOT.fullmatch(model)
    if snapshot is None:
        return None
    return TABLE.get(snapshot.group(1))


def cost_text(dollars: float, is_partial: bool) -> str:
    """`~$3.40` below ten dollars and `~$140` above; a trailing `+` when part could not be priced."""
    amount = f"{dollars:.2f}" if dollars < 10 else f"{dollars:.0f}"
    return f"~${amount}{'+' if is_partial else ''}"
