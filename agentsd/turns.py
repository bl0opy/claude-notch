"""When an agent finishes a turn, told once however it's heard.

Two sources say so. The Stop hook is exact but only fires where the hook is
installed. The roster sees every session go from working to idle, a tick or
two late, hook or not — including the ones the daemon hosts. Either can land
first, so whichever does is announced and the other, arriving within a few
seconds for the same session, is dropped.
"""
import time

# A turn this long is worth "done" out loud; anything shorter you were watching.
DONE_AFTER_S = 30
# How far apart the hook's word and the roster's can be and still be one turn.
SAME_TURN_S = 8


class TurnEnds:
    def __init__(self, long_after_s: float = DONE_AFTER_S, same_turn_s: float = SAME_TURN_S):
        self._long_after = long_after_s
        self._same_turn = same_turn_s
        self._working_since: dict[str, float] = {}
        self._announced: dict[str, float] = {}

    def update(self, rows: list[dict], now: float | None = None) -> list[dict]:
        """One roster tick in; a `done` event out for each turn it saw end."""
        now = time.time() if now is None else now
        events = []
        live = {r["id"] for r in rows}
        for row in rows:
            session_id, state = row["id"], row.get("state")
            if state == "working":
                self._working_since.setdefault(session_id, now)
            elif state == "idle" and session_id in self._working_since:
                span = now - self._working_since.pop(session_id)
                event = self.done(session_id, row.get("project") or "", span, now)
                if event:
                    events.append(event)
            # "waiting" is mid-turn: it's on you, not finished.
        for gone in set(self._working_since) - live:
            del self._working_since[gone]
        return events

    def done(self, session_id: str, project: str, span: float, now: float | None = None) -> dict | None:
        """The event for a finished turn, or None if it was just announced."""
        now = time.time() if now is None else now
        if session_id:
            last = self._announced.get(session_id)
            if last is not None and now - last < self._same_turn:
                return None
            self._announced[session_id] = now
            self._working_since.pop(session_id, None)
        return {
            "type": "fleet_event",
            "event": "done",
            "sessionId": session_id,
            "project": project,
            "long": span >= self._long_after,
            "seconds": int(span),
        }

    def filter(self, event: dict) -> dict | None:
        """A `done` from the Stop hook, let through only if the roster hasn't said it."""
        if event.get("type") != "fleet_event" or event.get("event") != "done":
            return event
        session_id = event.get("sessionId") or ""
        if not session_id:
            return event
        last = self._announced.get(session_id)
        now = time.time()
        if last is not None and now - last < self._same_turn:
            return None
        self._announced[session_id] = now
        self._working_since.pop(session_id, None)
        return event
