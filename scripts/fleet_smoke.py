"""Voice control of the approval inbox, end to end, minus the audio.

Real inbox, real hook script, real fleet client and command parser. Only the
processor's speech output is captured instead of played.

    .venv/bin/python scripts/fleet_smoke.py
"""
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

os.environ["NOTCH_TOKEN_FILE"] = os.path.join(tempfile.mkdtemp(), "token")

from agentsd.inbox import Inbox  # noqa: E402
from backend import processor as processor_module  # noqa: E402
from backend.bridge import NotchBridge  # noqa: E402
from backend.fleet import Fleet  # noqa: E402
from backend.processor import ClaudeCodeProcessor  # noqa: E402

INBOX_PORT, WS_PORT = 18866, 18867
HOOK = ROOT / "hooks" / "notch_hook.py"
ENV = {**os.environ, "NOTCH_INBOX_PORT": str(INBOX_PORT)}


class StubDirector:
    focused = "s-home"
    home_id = "s-home"

    def focus(self, session_id):
        self.focused = session_id

    def owned_ids(self):
        return ["s-home"]

    async def interrupt_agent(self, agent_id):
        return agent_id == "s-home"

    async def send_turn(self, text):
        self.sent = text
        return "sent"


class StubBridge:
    last_state = "listening"

    async def send(self, payload):
        pass

    async def state(self, value):
        pass


async def hook(tool: str, args: dict) -> asyncio.Task:
    event = {"hook_event_name": "PermissionRequest", "session_id": "s-term", "cwd": str(ROOT),
             "tool_name": tool, "tool_input": args, "permission_suggestions": []}

    async def run():
        proc = await asyncio.create_subprocess_exec(
            "/usr/bin/python3", str(HOOK), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, env=ENV)
        out, _ = await proc.communicate(json.dumps(event).encode())
        return json.loads(out)["hookSpecificOutput"]["decision"]["behavior"] if out.strip() else None

    return asyncio.create_task(run())


async def until(predicate, timeout=6.0):
    for _ in range(int(timeout / 0.05)):
        if predicate():
            return
        await asyncio.sleep(0.05)
    raise AssertionError("timed out waiting")


async def main():
    processor_module._ALERT_COALESCE_S = 0.3
    bridge = NotchBridge("127.0.0.1", WS_PORT)
    inbox = Inbox("127.0.0.1", INBOX_PORT, bridge.send, owned_timeout_s=10, terminal_timeout_s=30)

    async def on_approve(msg):
        inbox.answer(msg["id"], msg["approved"], always=msg.get("always", False))

    bridge.on("approve", on_approve)
    bridge.on_connect(lambda: [inbox.snapshot()])
    await bridge.start()
    await inbox.start()

    fleet = Fleet(f"ws://127.0.0.1:{WS_PORT}")
    director = StubDirector()
    brain = ClaudeCodeProcessor(director, StubBridge(), cancel_on_interrupt=False, fleet=fleet)
    said: list[str] = []

    async def speak(text):
        said.append(text)

    brain._speak_now = speak
    fleet.on_new_approval = brain.on_new_approval
    fleet.on_event = brain.on_fleet_event
    await fleet.start()
    await until(lambda: fleet.connected)

    test = await hook("Bash", {"command": "pytest -q"})
    await until(lambda: said)
    assert said == ["voice-agent wants to run pytest."], said
    print(f"ok  announced: {said[-1]!r}")

    await brain._take_turn("yeah")
    assert await test == "allow" and said[-1] == "Allowed voice-agent.", said
    print("ok  'yeah' allowed it, hook got allow")

    push = await hook("Bash", {"command": "git push origin main"})
    await until(lambda: len(said) >= 3)
    await brain._take_turn("yes")
    assert "say approve voice-agent" in said[-1], said
    assert not push.done()
    print(f"ok  bare yes refused on a risky one: {said[-1]!r}")

    await brain._take_turn("approve voice agent")
    assert await push == "allow", "push not allowed"
    print("ok  'approve voice agent' allowed the risky one")

    # Two at once coalesce into one line.
    said.clear()
    a = await hook("Read", {"file_path": "/etc/hosts"})
    b = await hook("WebFetch", {"url": "https://example.com"})
    await until(lambda: said)
    assert said == ["voice-agent wants to read hosts.", "voice-agent wants to fetch example.com."] or \
        said == ["voice-agent needs you."], said
    print(f"ok  coalesced: {said}")
    await brain._take_turn("no")
    await brain._take_turn("nope")
    assert await a == "deny" and await b == "deny"
    print("ok  'no' twice denied both, oldest first")

    # Answered elsewhere before the alert gets out: nothing said.
    said.clear()
    brain._mic_open = True
    c = await hook("Bash", {"command": "make"})
    await until(lambda: fleet.approvals)
    inbox.answer(fleet.approvals[0]["id"], True)
    assert await c == "allow"
    brain._mic_open = False
    await asyncio.sleep(1.2)
    assert said == [], said
    print("ok  answered while you were talking: stays quiet")

    await brain._take_turn("what's waiting")
    assert said[-1].startswith("Nothing's waiting"), said
    print(f"ok  status: {said[-1]!r}")

    # Long turn done in a background session is said; the focused one isn't.
    said.clear()
    await brain.on_fleet_event({"event": "done", "sessionId": "s-orbit", "project": "orbit", "long": True})
    await brain.on_fleet_event({"event": "done", "sessionId": "s-home", "project": "voice-agent", "long": True})
    await brain.on_fleet_event({"event": "done", "sessionId": "s-bus", "project": "bus-tracker", "long": False})
    await until(lambda: said)
    await asyncio.sleep(0.5)
    assert said == ["orbit is done."], said
    print(f"ok  done: {said}")

    # Not a command: goes to the focused agent.
    await brain._take_turn("ok but first rename the function")
    assert director.sent == "ok but first rename the function"
    print("ok  anything else is a turn for the focused agent")

    await fleet.stop()
    await inbox.stop()
    await bridge.stop()
    print("all good")


if __name__ == "__main__":
    asyncio.run(main())
