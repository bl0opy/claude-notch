"""Proves the approval inbox end to end with the real hook script, no Claude Code.

    .venv/bin/python scripts/inbox_smoke.py
"""
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agentsd.inbox import Inbox  # noqa: E402

PORT = 18766
HOOK = ROOT / "hooks" / "notch_hook.py"
ENV = {**os.environ, "NOTCH_INBOX_PORT": str(PORT)}


async def run_hook(event: dict) -> subprocess.CompletedProcess:
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/python3", str(HOOK),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, env=ENV,
    )
    out, _ = await proc.communicate(json.dumps(event).encode())
    return json.loads(out) if out.strip() else None


def permission(tool: str, args: dict, suggestions=None) -> dict:
    return {"hook_event_name": "PermissionRequest", "session_id": "s-term", "cwd": str(ROOT),
            "tool_name": tool, "tool_input": args, "permission_suggestions": suggestions or []}


def pre_tool(tool: str, args: dict) -> dict:
    return {"hook_event_name": "PreToolUse", "session_id": "s-owned", "cwd": str(ROOT),
            "tool_name": tool, "tool_input": args}


async def until(predicate, timeout=5.0):
    for _ in range(int(timeout / 0.05)):
        if predicate():
            return
        await asyncio.sleep(0.05)
    raise AssertionError("timed out waiting")


async def main():
    frames: list[dict] = []

    async def broadcast(frame):
        frames.append(frame)

    def cards():
        snaps = [f for f in frames if f["type"] == "approvals"]
        return snaps[-1]["list"] if snaps else []

    # Inbox down: terminal falls through to its own dialog, owned is refused.
    assert await run_hook(permission("Bash", {"command": "ls"})) is None
    down = await run_hook(pre_tool("Bash", {"command": "rm -rf build"}))
    assert down["hookSpecificOutput"]["permissionDecision"] == "deny", down
    # Safe calls in an owned agent never ask.
    assert await run_hook(pre_tool("Bash", {"command": "ls"})) is None
    print("ok  inbox down: terminal falls through, owned risky is denied, safe passes")

    inbox = Inbox("127.0.0.1", PORT, broadcast, owned_timeout_s=2, terminal_timeout_s=30)
    await inbox.start()

    suggestion = [{"type": "addDirectories", "directories": ["/tmp"], "destination": "session"}]
    t1 = asyncio.create_task(run_hook(permission("Bash", {"command": "pytest -q"}, suggestion)))
    await until(lambda: len(cards()) == 1)
    t2 = asyncio.create_task(run_hook(pre_tool("Bash", {"command": "git push origin main"})))
    await until(lambda: len(cards()) == 2)
    t3 = asyncio.create_task(run_hook(permission("Edit", {"file_path": "/etc/hosts"})))
    await until(lambda: len(cards()) == 3)

    first, second, third = cards()
    assert [c["source"] for c in cards()] == ["terminal", "owned", "terminal"], cards()
    assert first["summary"] == "run pytest" and first["canAlways"] and not first["risky"], first
    assert second["risky"] and second["summary"] == "push to git", second
    assert third["detail"] == "/etc/hosts" and third["summary"] == "edit hosts", third
    assert first["project"] == "voice-agent", first
    print("ok  three concurrent requests, oldest first, described")

    # Answer out of order, by id.
    assert inbox.answer(third["id"], approved=False)
    out3 = await t3
    assert out3["hookSpecificOutput"]["decision"]["behavior"] == "deny", out3
    assert inbox.answer(first["id"], approved=True, always=True)
    out1 = await t1
    decision = out1["hookSpecificOutput"]["decision"]
    assert decision["behavior"] == "allow" and decision["updatedPermissions"] == suggestion, out1
    assert not inbox.answer(first["id"], approved=False), "answered twice"
    print("ok  answered by id, out of order; always carries the suggestions")

    # Owned with no answer is a deny once the timeout passes.
    out2 = await t2
    assert out2["hookSpecificOutput"]["permissionDecision"] == "deny", out2
    await until(lambda: cards() == [])
    print("ok  owned question times out to deny, inbox empties")

    # A request from an agent that's gone is dropped on the next reconcile.
    reader, writer = await asyncio.open_connection("127.0.0.1", PORT)
    writer.write((json.dumps({"kind": "permission", "source": "terminal", "pid": 999_999,
                              "cwd": str(ROOT), "tool": "Bash", "input": {"command": "ls"}}) + "\n").encode())
    await writer.drain()
    await until(lambda: len(cards()) == 1)
    await inbox.reconcile()
    line = await asyncio.wait_for(reader.readline(), 2)
    assert json.loads(line)["decision"] == "none", line
    await until(lambda: cards() == [])
    writer.close()
    print("ok  dead agent's card dropped")

    # A killed hook takes its card with it.
    hook = await asyncio.create_subprocess_exec(
        "/usr/bin/python3", str(HOOK), stdin=asyncio.subprocess.PIPE, env=ENV,
    )
    hook.stdin.write(json.dumps(permission("Bash", {"command": "make"})).encode())
    hook.stdin.close()
    await until(lambda: len(cards()) == 1)
    hook.kill()
    await until(lambda: cards() == [])
    print("ok  killed hook's card dropped")

    await run_hook({"hook_event_name": "Stop", "session_id": "s-term", "cwd": str(ROOT)})
    await until(lambda: any(f["type"] == "fleet_event" for f in frames))
    event = next(f for f in frames if f["type"] == "fleet_event")
    assert event["event"] == "done" and event["project"] == "voice-agent" and not event["long"], event
    print("ok  stop hook becomes a fleet_event")

    await inbox.stop()
    print("all good")


if __name__ == "__main__":
    asyncio.run(main())
