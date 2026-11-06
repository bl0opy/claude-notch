"""Fake agents daemon on :8767 — builds the roster and approvals UI without live sessions."""
import asyncio, json, os, random, time, websockets

# MOCK_SCENE: "demo" (default) keeps questions up; "cycle" walks through
# questions -> working -> all idle, to watch the island expand, shrink and fold;
# "supervisor" alternates the supervisor's progress and stuck popups every 12 s;
# "notify" walks the notch's news every 8 s: a long turn finishing, a new
# permission question, a stuck agent, and a short turn finishing (which should
# stay quiet). Typed lines, "+ agent" and approvals are answered in every scene.
SCENE = os.getenv("MOCK_SCENE", "demo")
START = time.time()

ROWS = [
    {"id": "a1", "pid": 101, "tty": "", "host": "", "name": "voice-agent-83", "project": "voice-agent",
     "cwd": "/Users/you/code/voice-agent", "branch": "notch-agent-dashboard",
     "state": "working", "waitingFor": "", "reachable": True, "owned": True,
     "model": "claude-opus-5", "activity": "Grep", "activityDetail": "NotchBridge",
     "subagents": {"total": 2, "active": 1},
     "tokens": {"in": 578, "out": 164927, "cache_read": 19466890, "cache_write": 1093205, "thinking": 46112}},
    {"id": "b2", "pid": 102, "tty": "ttys003", "host": "Terminal", "name": "descant-ide-4", "project": "descant-ide",
     "cwd": "/Users/you/code/descant-ide", "branch": "fix-auth-flow",
     "state": "waiting", "waitingFor": "input needed", "reachable": True, "owned": False,
     "model": "claude-sonnet-5", "activity": "Bash", "activityDetail": "pytest -q",
     "subagents": {"total": 0, "active": 0},
     "tokens": {"in": 12, "out": 4210, "cache_read": 220145, "cache_write": 9821, "thinking": 640}},
    {"id": "c3", "pid": 103, "tty": "", "host": "Code", "name": "pose-lab-1", "project": "pose-lab",
     "cwd": "/Users/you/code/pose-lab", "branch": "main",
     "state": "idle", "waitingFor": "", "reachable": False, "owned": False,
     "model": "claude-sonnet-5", "activity": "Read", "activityDetail": "train.py",
     "subagents": {"total": 0, "active": 0},
     "tokens": {"in": 4, "out": 4_210_000, "cache_read": 12, "cache_write": 0, "thinking": 0}},
    {"id": "d4", "pid": 104, "name": "multiplayer-piano-2",
     "project": "multiplayer-piano-with-a-very-long-name", "cwd": "/tmp/x",
     "branch": "feature/websocket-reconnect-backoff", "state": "working", "waitingFor": "",
     "reachable": True, "owned": False, "model": "claude-opus-5",
     "activity": "Edit", "activityDetail": "server.ts", "subagents": {"total": 0, "active": 0},
     "tokens": {"in": 0, "out": 812, "cache_read": 0, "cache_write": 0, "thinking": 0}},
]


NOW = int(time.time() * 1000)
APPROVALS = [
    {"id": "q1", "source": "terminal", "sessionId": "b2", "pid": 102, "project": "descant-ide",
     "cwd": "/tmp", "tool": "Bash", "detail": "git push origin fix-auth-flow", "summary": "push to git",
     "risky": True, "canAlways": False, "created": NOW - 94_000},
    {"id": "q2", "source": "terminal", "sessionId": "d4", "pid": 104,
     "project": "multiplayer-piano-with-a-very-long-name", "cwd": "/tmp", "tool": "Bash",
     "detail": "npm test -- --runInBand --coverage src/server/websocket/reconnect.test.ts",
     "summary": "run npm", "risky": False, "canAlways": True, "created": NOW - 20_000},
    {"id": "q3", "source": "owned", "sessionId": "a1", "pid": 101, "project": "voice-agent", "cwd": "/tmp",
     "tool": "WebFetch", "detail": "https://code.claude.com/docs/en/hooks.md", "summary": "fetch code.claude.com",
     "risky": False, "canAlways": False, "created": NOW - 3_000},
]


def approvals():
    return {"type": "approvals", "list": APPROVALS}


def cycle_phase():
    t = (time.time() - START) % 40
    return "questions" if t < 10 else "working" if t < 22 else "idle"


def snapshot(tick):
    rows = [dict(r) for r in ROWS]
    if SCENE == "cycle":
        phase = cycle_phase()
        for r in rows:
            r["state"] = {"questions": r["state"], "working": "working", "idle": "idle"}[phase]
            if phase != "questions" and r["state"] == "waiting":
                r["state"] = "working"
        return {"type": "agents", "ts": tick, "degraded": False, "reason": "",
                "cliVersion": "2.1.251-mock", "list": rows}
    rows[0]["tokens"] = dict(rows[0]["tokens"], out=rows[0]["tokens"]["out"] + tick * 37)
    if tick % 8 == 0:
        rows[3]["state"] = random.choice(["working", "waiting", "idle"])
    return {"type": "agents", "ts": tick, "degraded": False, "reason": "",
            "cliVersion": "2.1.251-mock", "list": rows}


async def listen(ws):
    async for raw in ws:
        msg = json.loads(raw)
        print("got", msg, flush=True)
        kind = msg.get("type")
        if kind == "approve":
            APPROVALS[:] = [a for a in APPROVALS if a["id"] != msg.get("id")]
            await ws.send(json.dumps(approvals()))
        elif kind == "type":
            row = next((r for r in ROWS if r["id"] == msg.get("id")), None)
            status = "gone" if not row else "waiting" if row["state"] == "waiting" else (
                ("steered" if msg.get("steer") else "sent") if row.get("host") == "window"
                else "queued" if row["state"] == "working" else "sent")
            await ws.send(json.dumps({"type": "typed", "id": msg.get("id"), "status": status, "detail": ""}))
        elif kind == "spawn":
            # A hosted row appears, the way the real daemon's would; there's no
            # pty behind it, so no "spawned" to open a window on.
            cwd = msg.get("cwd") or "/tmp"
            ROWS.append({"id": f"h{len(ROWS)}", "pid": 900 + len(ROWS), "tty": "", "host": "window",
                         "name": os.path.basename(cwd), "project": os.path.basename(cwd) or cwd, "cwd": cwd,
                         "branch": "main", "state": "working", "waitingFor": "", "reachable": True,
                         "owned": True, "model": "claude-sonnet-5", "activity": "", "activityDetail": "",
                         "subagents": {"total": 0, "active": 0},
                         "tokens": {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0, "thinking": 0}})


SUPERVISOR_LINES = [
    {"event": "progress", "sessionId": "c3", "project": "pose-lab", "level": "info",
     "line": "pose-lab, 7 minutes in, 12 edits across 4 files, tests passing. Now wiring the eval loop into the CLI."},
    {"event": "stuck", "sessionId": "c3", "project": "pose-lab", "level": "attention", "reason": "failing",
     "line": "pose-lab looks stuck: it keeps rerunning the same test without fixing the missing import it trips on."},
]


NOTIFY_STEPS = [
    {"type": "fleet_event", "event": "done", "sessionId": "c3", "project": "pose-lab", "long": True, "seconds": 312},
    "question",
    {"type": "fleet_event", "event": "stuck", "sessionId": "d4", "project": "multiplayer-piano", "level": "attention",
     "reason": "looping", "speak": True,
     "line": "multiplayer-piano looks stuck: it keeps reading the same socket file without changing anything."},
    {"type": "fleet_event", "event": "done", "sessionId": "a1", "project": "voice-agent", "long": False, "seconds": 6},
]


async def notify_step(ws, n):
    step = NOTIFY_STEPS[n % len(NOTIFY_STEPS)]
    if step == "question":
        APPROVALS.append({"id": f"n{n}", "source": "terminal", "sessionId": "b2", "pid": 102,
                          "project": "descant-ide", "cwd": "/tmp", "tool": "Bash", "detail": "rm -rf build/",
                          "summary": "delete build", "risky": True, "canAlways": False,
                          "created": int(time.time() * 1000)})
        await ws.send(json.dumps(approvals()))
    else:
        await ws.send(json.dumps(step))
    print("notify:", step if step == "question" else f"{step['event']} {step['project']}", flush=True)


async def handler(ws):
    print("client connected", flush=True)
    listener = asyncio.create_task(listen(ws))
    await ws.send(json.dumps(approvals()))
    tick = 0
    try:
        while True:
            if SCENE == "cycle":
                shown = approvals() if cycle_phase() == "questions" else {"type": "approvals", "list": []}
                await ws.send(json.dumps(shown))
            await ws.send(json.dumps(snapshot(tick)))
            if SCENE == "notify" and tick % 8 == 3:
                await notify_step(ws, tick // 8)
            if SCENE == "supervisor" and tick % 12 == 2:
                event = SUPERVISOR_LINES[(tick // 12) % len(SUPERVISOR_LINES)]
                await ws.send(json.dumps({"type": "fleet_event", "speak": True, **event}))
            tick += 1
            await asyncio.sleep(1)
    finally:
        listener.cancel()


async def main():
    async with websockets.serve(handler, "127.0.0.1", 8767):
        await asyncio.Future()

asyncio.run(main())
