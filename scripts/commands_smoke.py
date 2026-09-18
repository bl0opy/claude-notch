"""Table test for spoken fleet commands — no audio, no daemon.

    .venv/bin/python scripts/commands_smoke.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.commands import parse, usage_line  # noqa: E402

AGENTS = [
    {"id": "s-bus", "project": "bus-tracker", "name": "bus-tracker-2", "state": "waiting"},
    {"id": "s-orbit", "project": "orbit", "name": "orbit-1", "state": "working"},
    {"id": "s-voice", "project": "voice-agent", "name": "voice-agent-f2", "state": "idle"},
    {"id": "s-descant", "project": "descant-ide", "name": "descant-ide-4", "state": "working"},
]
PUSH = {"id": "q-push", "project": "orbit", "summary": "push to git", "risky": True}
TEST = {"id": "q-test", "project": "bus-tracker", "summary": "run pytest", "risky": False}

CASES = [
    # (utterance, approvals, expected (kind, id, approved, always) or None)
    ("yes", [TEST, PUSH], ("answer", "q-test", True, False)),
    ("yeah go ahead", [TEST], ("answer", "q-test", True, False)),
    ("nope", [PUSH, TEST], ("answer", "q-push", False, False)),
    ("yes", [PUSH, TEST], ("say", "", False, False)),
    ("approve orbit", [PUSH, TEST], ("answer", "q-push", True, False)),
    ("Approve bus tracker.", [PUSH, TEST], ("answer", "q-test", True, False)),
    ("allow the one for bus tracker", [PUSH, TEST], ("answer", "q-test", True, False)),
    ("deny orbit", [TEST, PUSH], ("answer", "q-push", False, False)),
    ("always allow bus tracker", [TEST], ("answer", "q-test", True, True)),
    ("approve descant", [PUSH, TEST], ("say", "", False, False)),
    ("ok but first rename the function", [TEST], None),
    ("yes", [], None),
    ("what's waiting", [PUSH], ("status", "", False, False)),
    ("switch to descant ide", [], ("focus", "s-descant", False, False)),
    ("go to orbit", [PUSH], ("focus", "s-orbit", False, False)),
    ("go back", [], ("home", "", False, False)),
    ("stop orbit", [], ("stop", "s-orbit", False, False)),
    ("stop", [], None),
    ("go to the store and buy milk", [], None),
    ("go to orbit's config file", [], None),
    ("approve the refactor plan", [TEST], None),
    ("what's this costing", [], ("status", "", False, False)),
    ("how much have we spent", [], ("status", "", False, False)),
    ("context usage", [], ("status", "", False, False)),
    ("how much should i refactor this", [], None),
]

# Every session at once, said out loud.
TOTALS = {
    "sessions": 3,
    "totalTokens": 20_595_665,
    "cost": 18.37,
    "context": {"fullestPct": 21.6, "fullest": "voice-agent", "crowded": 0},
}
USAGE_CASES = [
    (TOTALS, ["3 sessions", "20.6 million", "18 dollars", "voice-agent", "22 percent"]),
    ({**TOTALS, "context": {"fullestPct": 88.0, "fullest": "nudge", "crowded": 2}},
     ["2 windows are past three quarters"]),
    ({"sessions": 1, "totalTokens": 900, "cost": 0.0,
      "context": {"fullestPct": 0.0, "fullest": "", "crowded": 0}},
     ["1 session,", "900 tokens"]),
    ({}, ["Nothing's running"]),
]


def main() -> int:
    failed = 0
    for text, approvals, expected in CASES:
        command = parse(text, approvals, AGENTS)
        got = None if command is None else (command.kind, command.id, command.approved, command.always)
        ok = got == expected
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {text!r:42} -> {got}{'' if ok else f'  (wanted {expected})'}")
        if command and command.text and command.kind in ("say", "status"):
            print(f"       says: {command.text}")
    for totals, wanted in USAGE_CASES:
        line = usage_line(totals)
        missing = [w for w in wanted if w not in line]
        failed += bool(missing)
        print(f"{'ok  ' if not missing else 'FAIL'} usage: {line}")
        if missing:
            print(f"       missing {missing}")

    print("all good" if not failed else f"{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
