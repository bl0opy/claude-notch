import asyncio
import os
import re

from loguru import logger
from pipecat.frames.frames import (
    CancelFrame,
    EndFrame,
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    StartFrame,
    TranscriptionFrame,
    UserStartedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from backend.bridge import NotchBridge
from backend.agents import AgentDirector
from backend.speech import SpeechFilter
from backend.tools import _TOOL_NARRATION, _tool_detail

_YES = {"yes","yeah","yep","yup","sure","ok","okay","go","go ahead","do it","approve",
        "approved","allow","fine","please do","affirmative","sounds good","confirm"}
_NO = {"no","nope","nah","stop","don't","dont","cancel","deny","denied","reject","abort",
       "negative","skip","never mind","nevermind"}


def hears_approval(text: str) -> bool | None:
    """yes/no from a spoken reply, or None if it isn't an answer either way."""
    words = re.findall(r"[a-z']+", text.lower())
    if not words:
        return None
    phrase = " ".join(words)
    # Check the leading words first — "no, wait" is a no even though it's long.
    for n in (3, 2, 1):
        head = " ".join(words[:n])
        if head in _NO:
            return False
        if head in _YES:
            return True
    if any(w in _NO for w in words) and not any(w in _YES for w in words):
        return False
    if any(w in _YES for w in words) and not any(w in _NO for w in words):
        return True
    return None


class ClaudeCodeProcessor(FrameProcessor):
    """Stands where an LLM service normally would.

    Takes final transcriptions in, drives a long-lived Claude Code subprocess,
    and pushes only the speakable prose downstream to TTS. Raw text still goes
    to the notch shell over the bridge.
    """

    def __init__(
        self,
        director: AgentDirector,
        bridge: NotchBridge,
        cancel_on_interrupt: bool,
        approvals=None,
        max_spoken_sentences: int = 2,
        hold_to_talk: bool = False,
        hold_tail_ms: int = 400,
    ):
        super().__init__()
        self._director = director
        self._bridge = bridge
        self._approvals = approvals
        self._cancel_on_interrupt = cancel_on_interrupt
        self._filter = SpeechFilter(max_spoken_sentences)
        self._consumer: asyncio.Task | None = None
        self._responding = False
        self._dropping = False
        self._pending_turns = 0
        self._raw = ""
        # The key, not the silence, ends the turn: Flux fires end-of-turn on
        # every pause, so a held key collects those pieces and sends one turn
        # when it comes up. Off when there is no key to hold.
        self._hold_to_talk = hold_to_talk
        self._hold_tail = hold_tail_ms / 1000
        self._mic_open = False
        self._held: list[str] = []
        self._drain: asyncio.Task | None = None

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            await self.push_frame(frame, direction)
            await self._director.start()
            self._consumer = asyncio.create_task(self._consume())
            await self._bridge.state("listening")
            return

        if isinstance(frame, (EndFrame, CancelFrame)):
            if self._consumer:
                self._consumer.cancel()
            await self._director.stop()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, (InterruptionFrame, UserStartedSpeakingFrame)):
            await self._handle_interruption()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, TranscriptionFrame) and frame.text.strip():
            if self._hold_to_talk and (self._mic_open or self._drain):
                self._collect(frame.text)
                await self._bridge.send(
                    {
                        "type": "transcript",
                        "role": "user",
                        "text": " ".join(self._held),
                        "final": False,
                    }
                )
                return
            await self._take_turn(frame.text)
            return

        await self.push_frame(frame, direction)

    # ---- turns -----------------------------------------------------------

    def _collect(self, text: str):
        text = text.strip()
        if text:
            self._held.append(text)

    async def set_mic(self, open_: bool):
        """The push-to-talk key went down or came up.

        Everything Flux hears between the two is one turn, however many pauses
        it took — releasing the key is the only thing that ends it.
        """
        if open_ == self._mic_open:
            return
        self._mic_open = open_
        if not self._hold_to_talk:
            return
        if open_:
            # Pressing again before the tail ran out sends what's held rather
            # than gluing two presses into one turn.
            await self._flush_held()
            return
        # The last words of a hold arrive after the key is already up — Flux
        # only calls end-of-turn once the audio stops — so give them a moment
        # to land before the turn is sealed.
        self._drain = asyncio.create_task(self._drain_held())

    async def _drain_held(self):
        try:
            await asyncio.sleep(self._hold_tail)
        except asyncio.CancelledError:
            return
        self._drain = None
        text = " ".join(self._held).strip()
        self._held = []
        if text:
            await self._take_turn(text)

    async def _flush_held(self):
        """Send whatever is held right now and stop waiting for more."""
        if self._drain:
            self._drain.cancel()
            self._drain = None
        text = " ".join(self._held).strip()
        self._held = []
        if text:
            await self._take_turn(text)

    async def _take_turn(self, text: str):
        if await self._answered_approval(text):
            return
        await self._bridge.send(
            {"type": "transcript", "role": "user", "text": text, "final": True}
        )
        await self._bridge.state("thinking")
        self._filter.reset()
        self._raw = ""
        try:
            self._pending_turns += 1
            status = await self._director.send_turn(text)
            if status == "steered":
                # The turn it was in the middle of has been cut off, and that
                # one still owes us a result — which will decrement for it.
                self._dropping = False
            elif status == "queued":
                await self._speak_now("It's mid-turn — I'll pass that on when it's free.")
            elif status == "gone":
                self._pending_turns = max(0, self._pending_turns - 1)
                await self._speak_now("That agent isn't running any more.")
        except Exception as e:
            self._pending_turns -= 1
            logger.error(f"failed to send turn to claude code: {e}")
            await self._bridge.send({"type": "error", "message": str(e)})

    async def _answered_approval(self, text: str) -> bool:
        """Consume a spoken yes/no while the focused agent has a question open."""
        if not self._approvals or not self._approvals.pending_for(self._director.focused):
            return False
        verdict = hears_approval(text)
        if verdict is None:
            return False
        await self._bridge.send(
            {"type": "transcript", "role": "user", "text": text, "final": True}
        )
        await self.resolve_approval(verdict, "by voice")
        return True

    async def resolve_approval(self, approved: bool, how: str = ""):
        if not self._approvals:
            return
        # An answer is always for the agent you're talking to, never whichever
        # question happened to arrive last.
        req_id = self._approvals.pending_for(self._director.focused) or self._approvals.pending_id
        if not req_id or not self._approvals.resolve(req_id, approved, how):
            return
        await self._bridge.send({"type": "approval_closed", "id": req_id, "approved": approved})
        await self._bridge.state("thinking")

    async def ask_approval(self, request: dict):
        """A hook is blocked on us; put the question in the notch and say it."""
        asked_by = request.get("session_id", "")
        await self._bridge.send(
            {
                "type": "approval",
                "id": request["id"],
                "tool": request.get("tool", "tool"),
                "reason": request.get("reason", ""),
                "summary": request.get("summary", ""),
                "agent": asked_by,
            }
        )
        # A question from an agent you aren't talking to gets a nudge, not the
        # whole question — answering it means focusing it first.
        if asked_by and asked_by != self._director.focused:
            where = os.path.basename(self._director.cwd_of(asked_by)) or "another agent"
            await self._speak_now(f"{where} needs your ok.")
            return
        await self._bridge.state("waiting")
        # Out loud it's only ever the summary — the command itself is on screen.
        summary = request.get("summary") or "this one"
        await self._speak_now(f"I need your approval for {summary}.")

    async def _speak_now(self, text: str):
        """Say something that isn't part of Claude's streamed answer."""
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
        await self.push_frame(LLMTextFrame(text))
        await self.push_frame(LLMFullResponseEndFrame())
        self._responding = False

    async def send_text_turn(self, text: str):
        """Typed input from the notch shell — same path as a spoken turn."""
        await self._take_turn(text)

    async def _handle_interruption(self):
        if not self._responding and not self._dropping:
            return
        self._dropping = True
        self._filter.reset()
        if self._responding:
            await self.push_frame(LLMFullResponseEndFrame())
            self._responding = False
        if self._cancel_on_interrupt:
            await self._director.interrupt()

    async def _speak(self, text: str):
        # A turn we already talked over may still be streaming; only the newest one speaks.
        if self._dropping or self._pending_turns > 1 or not text:
            return
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
            await self._bridge.state("speaking")
        await self.push_frame(LLMTextFrame(text + " "))

    async def _consume(self):
        async for agent_id, event in self._director.stream():
            kind = event["kind"]
            # Everything reaches the notch; only the focused agent is spoken.
            focused = agent_id == self._director.focused

            if kind == "alert":
                # A background agent blocked or finished. One line, and never
                # over the top of a permission question we're already asking.
                if not (self._approvals and self._approvals.pending_id):
                    await self._speak_now(event["text"])
                continue

            if kind == "delivery":
                await self._bridge.send({k: v for k, v in event.items() if k != "kind"})
                # A held message that never landed is worth a word — silence
                # here is indistinguishable from having been heard.
                if event.get("status") == "refused":
                    where = os.path.basename(self._director.cwd_of(agent_id)) or "that agent"
                    await self._speak_now(f"Couldn't get that to {where}.")
                continue

            if kind == "ready":
                await self._bridge.send(
                    {
                        "type": "session",
                        "id": event["session_id"],
                        "cwd": self._director.cwd_of(event["session_id"]),
                    }
                )

            elif kind == "turn_start":
                self._raw = ""

            elif kind == "text_delta":
                if self._pending_turns > 1:
                    continue
                await self._bridge.send(
                    {"type": "assistant_delta", "text": event["text"], "agent": agent_id}
                )
                if not focused:
                    continue
                self._raw += event["text"]
                for chunk in self._filter.feed(event["text"]):
                    await self._speak(chunk)

            elif kind == "tool_use":
                name = event["name"]
                verb = _TOOL_NARRATION.get(name, f"using {name}")
                await self._bridge.send(
                    {
                        "type": "tool",
                        "id": event.get("id", ""),
                        "name": name,
                        "summary": verb,
                        "detail": _tool_detail(name, event.get("input") or {}),
                        "agent": agent_id,
                    }
                )

            elif kind == "tool_result":
                await self._bridge.send(
                    {
                        "type": "tool_result",
                        "id": event.get("id", ""),
                        "ok": not event.get("is_error"),
                        "text": event.get("text", ""),
                        "agent": agent_id,
                    }
                )

            elif kind == "turn_end":
                if not focused:
                    continue
                self._pending_turns = max(0, self._pending_turns - 1)
                self._dropping = False
                if self._pending_turns > 0:
                    continue
                for chunk in self._filter.flush():
                    await self._speak(chunk)
                if self._responding:
                    await self.push_frame(LLMFullResponseEndFrame())
                    self._responding = False
                await self._bridge.send({"type": "assistant_done", "text": self._raw})
                await self._bridge.state("listening")
                if event.get("is_error"):
                    await self._bridge.send({"type": "error", "message": event.get("text", "")})

            elif kind == "process_exit":
                logger.error("claude code process exited")
                await self._bridge.send({"type": "error", "message": "claude code exited"})
                await self._bridge.state("error")
                break
