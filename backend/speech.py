import re

SPEECH_SYSTEM_PROMPT = (
    "You are being spoken aloud through a text-to-speech voice in a hands-free coding "
    "conversation. Talk like a friend who happens to be a good engineer: casual, warm, "
    "contractions, plain words. Say 'yeah' and 'nope' and 'let me look'. Skip the throat "
    "clearing - no 'certainly', no 'I'd be happy to', no restating the question back.\n\n"
    "Be extremely brief. Two or three sentences is a normal answer. One is often better. "
    "Summarize the outcome, never the process: what you found, what you changed, what you'd "
    "do next. Give the headline and stop - if they want detail they'll ask.\n\n"
    "Never read out code, file contents, paths, commands, logs, diffs, or lists of names. "
    "Say 'three files' not the three filenames. Say 'the config' not the full path. Say "
    "'it failed on a type error' not the stack trace. The screen has the specifics; you "
    "have the gist. No markdown, no headers, no bullets, no code blocks - it all sounds "
    "like noise out loud.\n\n"
    "While you work, narrate almost nothing. A short 'give me a sec' at most. Save it for "
    "the answer.\n\n"
    "If you need the user to approve something, ask in one short question ending in a "
    "clear yes-or-no, and then wait."
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
