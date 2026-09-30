"""Smoke test for end-of-turn detection: the roster's working -> idle, the Stop
hook's word, and the two agreeing on one announcement per turn.

    .venv/bin/python scripts/turns_smoke.py
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agentsd.turns import TurnEnds  # noqa: E402

failures = 0


def check(label: str, ok: bool, detail=""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {label}{f' — {detail}' if detail and not ok else ''}")


def row(session_id: str, state: str) -> dict:
    return {"id": session_id, "project": session_id, "state": state}


def hook_done(session_id: str) -> dict:
    return {"type": "fleet_event", "event": "done", "sessionId": session_id, "project": session_id, "long": True}


t0 = time.time()

turns = TurnEnds()
turns.update([row("orbit", "working")], t0)
events = turns.update([row("orbit", "idle")], t0 + 45)
check("working -> idle is a done", len(events) == 1 and events[0]["event"] == "done", events)
check("45 s is long", events and events[0]["long"] and events[0]["seconds"] == 45, events)

turns.update([row("quick", "working")], t0)
events = turns.update([row("quick", "idle")], t0 + 5)
check("a 5 s turn is done but not long", len(events) == 1 and not events[0]["long"], events)

turns.update([row("ask", "working")], t0)
events = turns.update([row("ask", "waiting")], t0 + 40)
check("waiting on you isn't done", events == [], events)
events = turns.update([row("ask", "idle")], t0 + 60)
check("done once the question's answered and it stops", len(events) == 1 and events[0]["long"], events)

events = turns.update([row("fresh", "idle")], t0)
check("idle from the start was never a turn", events == [], events)

turns.update([row("gone", "working")], t0)
turns.update([], t0 + 10)
events = turns.update([row("gone", "idle")], t0 + 20)
check("a session that vanished mid-turn isn't done when it's back", events == [], events)

# Now the hook, the way it races the roster. The hook's timing is real time.
now = time.time()
turns = TurnEnds()
turns.update([row("hooked", "working")], now - 60)
passed = turns.filter(hook_done("hooked"))
check("the hook's done goes through first", passed is not None)
events = turns.update([row("hooked", "idle")], time.time())
check("and the roster's, a tick later, is dropped", events == [], events)

turns.update([row("roster-first", "working")], now - 60)
events = turns.update([row("roster-first", "idle")], time.time())
check("the roster's done goes through first", len(events) == 1, events)
check("and the hook's, just after, is dropped", turns.filter(hook_done("roster-first")) is None)

other = {"type": "fleet_event", "event": "progress", "sessionId": "hooked"}
check("anything but done passes the filter untouched", turns.filter(other) is other)

print("all good" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
