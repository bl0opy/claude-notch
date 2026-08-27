import re

SPEECH_SYSTEM_PROMPT = (
    "You are being spoken aloud through a text-to-speech voice in a hands-free coding "
    "conversation. Talk like a colleague thinking out loud with someone: short sentences, "
    "plain prose, no markdown, no headers, no bullet lists, no code blocks, no file diffs. "
    "Never read code, paths, or command lines out loud - say what you're doing and why, and "
    "let the user read the specifics on screen. Keep answers to a few sentences unless asked "
    "to go deeper. When you use tools, briefly narrate the intent, not the mechanics."
)

_FENCE = re.compile(r"```")
_SENTENCE_END = re.compile(r"[.!?]['\")\]]?\s")
_INLINE_CODE = re.compile(r"`([^`]*)`")
_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_MD_EMPHASIS = re.compile(r"(\*\*|__|\*|_|~~)")
_MD_HEADER = re.compile(r"^\s{0,3}#{1,6}\s*", re.MULTILINE)
_MD_BULLET = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+", re.MULTILINE)
_DIFF_LINE = re.compile(r"^\s*[+-]{1,3}[^\s]", re.MULTILINE)
_PATHY = re.compile(r"[/\\]|\.\w{1,5}$|\(\)|::|_")
_WS = re.compile(r"\s+")


def _speakable_inline(match: re.Match) -> str:
    inner = match.group(1).strip()
    if not inner or _PATHY.search(inner) or len(inner.split()) > 4:
        return "that"
    return inner


def clean_for_speech(text: str) -> str:
    """Turn a chunk of Claude Code prose into something worth hearing out loud."""
    text = _MD_LINK.sub(r"\1", text)
    text = _INLINE_CODE.sub(_speakable_inline, text)
    text = _MD_HEADER.sub("", text)
    text = _MD_BULLET.sub("", text)
    text = _DIFF_LINE.sub("", text)
    text = _MD_EMPHASIS.sub("", text)
    text = _WS.sub(" ", text)
    return text.strip()


class SpeechFilter:
    """Streaming filter: swallow code fences, emit speakable sentences as they complete."""

    def __init__(self):
        self._buffer = ""
        self._in_fence = False

    def reset(self):
        self._buffer = ""
        self._in_fence = False

    def feed(self, delta: str) -> list[str]:
        self._buffer += delta
        return self._drain(final=False)

    def flush(self) -> list[str]:
        chunks = self._drain(final=True)
        self.reset()
        return chunks

    def _drain(self, final: bool) -> list[str]:
        out: list[str] = []
        while True:
            if self._in_fence:
                match = _FENCE.search(self._buffer)
                if not match:
                    if final:
                        self._buffer = ""
                    return out
                self._buffer = self._buffer[match.end():]
                self._in_fence = False
                continue

            match = _FENCE.search(self._buffer)
            if match:
                prose, self._buffer = self._buffer[: match.start()], self._buffer[match.end():]
                self._in_fence = True
                out.extend(self._emit(prose, final=True))
                continue

            out.extend(self._emit_ready(final))
            return out

    def _emit_ready(self, final: bool) -> list[str]:
        out: list[str] = []
        while True:
            match = _SENTENCE_END.search(self._buffer)
            if not match:
                break
            sentence, self._buffer = self._buffer[: match.end()], self._buffer[match.end():]
            out.extend(self._emit(sentence, final=True))
        if final and self._buffer.strip():
            out.extend(self._emit(self._buffer, final=True))
            self._buffer = ""
        # An unterminated fence's opening line is never worth speaking.
        if not final and len(self._buffer) > 2000:
            out.extend(self._emit(self._buffer, final=True))
            self._buffer = ""
        return out

    @staticmethod
    def _emit(raw: str, final: bool) -> list[str]:
        cleaned = clean_for_speech(raw)
        return [cleaned] if cleaned else []
