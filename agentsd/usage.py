from dataclasses import dataclass


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
