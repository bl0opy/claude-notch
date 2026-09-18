"""Tokens, what they'd cost, and how full a window is.

The dollars are what the same tokens would cost at API rates — Claude Code on a
subscription isn't billed per token, so this is a size, not an invoice. It is
still the only number that compares a cheap session to an expensive one.
"""
from dataclasses import dataclass

# $ per million tokens, input and output, from the Anthropic pricing table.
# Cache is the standard multiple of input everywhere: a write costs 1.25x, a
# read 0.1x. Prefix-matched on the model id, so dated snapshots land on the
# same row as the bare id.
PRICES = {
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4": (5.00, 25.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-sonnet-4": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-haiku-4": (1.00, 5.00),
}
CACHE_WRITE = 1.25
CACHE_READ = 0.1

# Context window, in tokens. Haiku is the odd one out.
WINDOWS = {"claude-haiku-4-5": 200_000, "claude-haiku-4": 200_000}
DEFAULT_WINDOW = 1_000_000


def _row(model: str) -> tuple[float, float] | None:
    for prefix, price in sorted(PRICES.items(), key=lambda kv: -len(kv[0])):
        if model.startswith(prefix):
            return price
    return None


def window_for(model: str) -> int:
    for prefix, size in WINDOWS.items():
        if model.startswith(prefix):
            return size
    return DEFAULT_WINDOW


@dataclass
class Totals:
    tokens_in: int = 0
    tokens_out: int = 0
    cache_read: int = 0
    cache_write: int = 0
    thinking: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "in": self.tokens_in,
            "out": self.tokens_out,
            "cache_read": self.cache_read,
            "cache_write": self.cache_write,
            "thinking": self.thinking,
        }

    @property
    def total(self) -> int:
        return self.tokens_in + self.tokens_out + self.cache_read + self.cache_write


def cost(totals: Totals, model: str) -> float:
    """Dollars at API rates. 0.0 for a model we don't have a price for."""
    price = _row(model or "")
    if not price:
        return 0.0
    dollars_in, dollars_out = price
    return (
        totals.tokens_in * dollars_in
        + totals.tokens_out * dollars_out
        + totals.cache_write * dollars_in * CACHE_WRITE
        + totals.cache_read * dollars_in * CACHE_READ
    ) / 1_000_000


def fold(usage: dict, acc: Totals):
    """Add one assistant line's usage to a running total.

    `usage["iterations"]` is a per-request breakdown of these same numbers —
    folding both counts every token twice.
    """
    if not isinstance(usage, dict):
        return
    acc.tokens_in += usage.get("input_tokens") or 0
    acc.tokens_out += usage.get("output_tokens") or 0
    acc.cache_write += usage.get("cache_creation_input_tokens") or 0
    acc.cache_read += usage.get("cache_read_input_tokens") or 0
    details = usage.get("output_tokens_details") or {}
    if isinstance(details, dict):
        acc.thinking += details.get("thinking_tokens") or 0


def occupancy(usage: dict) -> int:
    """How much of the window one request carried.

    Everything the model was sent, however it was billed: fresh input, what was
    read from cache and what was written to it. Not a sum over the session —
    the last request is the current size of the conversation.
    """
    if not isinstance(usage, dict):
        return 0
    return (
        (usage.get("input_tokens") or 0)
        + (usage.get("cache_read_input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
    )


def fold_dict(tokens: dict, acc: Totals):
    """Add one row's already-serialised `tokens` block to a running total."""
    if not isinstance(tokens, dict):
        return
    acc.tokens_in += tokens.get("in") or 0
    acc.tokens_out += tokens.get("out") or 0
    acc.cache_read += tokens.get("cache_read") or 0
    acc.cache_write += tokens.get("cache_write") or 0
    acc.thinking += tokens.get("thinking") or 0
