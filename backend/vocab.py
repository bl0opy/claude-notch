"""Repairs project names a local model mishears.

The spoken fleet commands are addressed by project — "approve orbit", "go to
descant" — so a name that comes back wrong doesn't degrade the turn, it aims it
at nobody. Cloud models take a keyword list for this; parakeet has no biasing
hook, so the names are put back afterwards instead.

The vocabulary is whatever repos have live sessions, which is exactly the set a
command can name. Rebuilt on a timer, since the roster changes as agents start.
"""
import re
import time
from difflib import SequenceMatcher

from agentsd.registry import live_sessions
from agentsd.snapshot import project_name

# Chosen from measured pairs, not picked by feel. Real mishearings of names in
# this workspace score 0.71-0.91 ("desk and" -> descant-ide, "bus trucker" ->
# bus-tracker, "orbits" -> orbit); ordinary phrases that happen to sit near a
# name score 0.22-0.67, the top of that range being "the agent" against
# voice-agent. 0.70 is the gap between the two.
THRESHOLD = 0.70
# The longest a run of words can be and still be one name, past the name's own
# word count: mishearing tends to split words, not join them.
SLACK = 1
_WORD = re.compile(r"[A-Za-z0-9']+")
_SQUASH = re.compile(r"[^a-z0-9]")


def squash(text: str) -> str:
    """Compare letters only, so "bus tracker" and "bus-tracker" are one thing."""
    return _SQUASH.sub("", text.lower())


class Vocabulary:
    def __init__(self, refresh_s: float = 30.0):
        self._names: list[str] = []
        self._refresh = refresh_s
        self._checked = 0.0

    def names(self) -> list[str]:
        now = time.monotonic()
        if now - self._checked >= self._refresh or not self._checked:
            self._checked = now
            try:
                rows, _ = live_sessions()
                self._names = sorted({project_name(r.cwd) for r in rows if r.cwd})
            except Exception:
                pass
        return self._names

    def correct(self, text: str) -> str:
        names = self.names()
        if not names:
            return text

        tokens = [(m.group(), m.start(), m.end()) for m in _WORD.finditer(text)]
        if not tokens:
            return text

        squashed = {name: squash(name) for name in names}
        longest = max(len(_WORD.findall(n)) for n in names) + SLACK

        # Every run of words that could be a name, scored against every name.
        # Best score wins rather than longest run: "desk and" matches
        # descant-ide better (0.71) than "desk and then" does (0.67).
        scored = []
        for width in range(1, longest + 1):
            for i in range(len(tokens) - width + 1):
                span = tokens[i:i + width]
                phrase = squash(" ".join(t[0] for t in span))
                if not phrase:
                    continue
                for name in names:
                    if phrase == squashed[name]:
                        continue
                    ratio = SequenceMatcher(None, phrase, squashed[name]).ratio()
                    if ratio >= THRESHOLD:
                        scored.append((ratio, i, width, name))

        scored.sort(reverse=True)
        taken: set[int] = set()
        replacements = []
        for _, i, width, name in scored:
            if any(j in taken for j in range(i, i + width)):
                continue
            taken.update(range(i, i + width))
            replacements.append((tokens[i][1], tokens[i + width - 1][2], name))

        for start, end, name in sorted(replacements, reverse=True):
            text = text[:start] + name + text[end:]
        return text
