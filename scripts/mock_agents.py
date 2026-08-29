"""Fake agents daemon on :8767 — builds the roster UI without live sessions."""
import asyncio, json, random, websockets

ROWS = [
    {"id": "a1", "pid": 101, "name": "voice-agent-83", "project": "voice-agent",
     "cwd": "/Users/ayan/Documents/GitHub/voice-agent", "branch": "notch-agent-dashboard",
     "state": "working", "waitingFor": "", "reachable": True, "owned": True,
     "model": "claude-opus-5", "activity": "Grep", "activityDetail": "NotchBridge",
     "subagents": {"total": 2, "active": 1},
     "tokens": {"in": 578, "out": 164927, "cache_read": 19466890, "cache_write": 1093205, "thinking": 46112}},
    {"id": "b2", "pid": 102, "name": "descant-ide-4", "project": "descant-ide",
     "cwd": "/Users/ayan/Documents/GitHub/descant-ide", "branch": "fix-auth-flow",
     "state": "waiting", "waitingFor": "input needed", "reachable": True, "owned": False,
     "model": "claude-sonnet-5", "activity": "Bash", "activityDetail": "pytest -q",
     "subagents": {"total": 0, "active": 0},
     "tokens": {"in": 12, "out": 4210, "cache_read": 220145, "cache_write": 9821, "thinking": 640}},
    {"id": "c3", "pid": 103, "name": "wound-stage-1", "project": "wound-stage",
     "cwd": "/Users/ayan/Documents/GitHub/wound-stage", "branch": "main",
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


def snapshot(tick):
    rows = [dict(r) for r in ROWS]
    rows[0]["tokens"] = dict(rows[0]["tokens"], out=rows[0]["tokens"]["out"] + tick * 37)
    if tick % 8 == 0:
        rows[3]["state"] = random.choice(["working", "waiting", "idle"])
    return {"type": "agents", "ts": tick, "degraded": False, "reason": "",
            "cliVersion": "2.1.251-mock", "list": rows}


async def handler(ws):
    print("client connected")
    tick = 0
    while True:
        await ws.send(json.dumps(snapshot(tick)))
        tick += 1
        await asyncio.sleep(1)


async def main():
    async with websockets.serve(handler, "127.0.0.1", 8767):
        await asyncio.Future()

asyncio.run(main())
