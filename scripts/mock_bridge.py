import asyncio, json, websockets

SCRIPT = [
    (0.5, {"type": "session", "id": "mock", "cwd": "/Users/you/code/voice-agent"}),
    (0.2, {"type": "state", "value": "listening"}),
    (1.5, {"type": "transcript", "role": "user", "text": "should auth be its own service or just a module?"}),
    (0.2, {"type": "state", "value": "thinking"}),
    (0.8, {"type": "tool", "name": "Grep", "summary": "searching"}),
    (0.4, {"type": "state", "value": "speaking"}),
    (0.3, {"type": "assistant_delta", "text": "Keep it a module for now. "}),
    (0.4, {"type": "assistant_delta", "text": "Splitting it out buys you independent deploys you don't need yet, "}),
    (0.4, {"type": "assistant_delta", "text": "and costs you a network hop on every request."}),
    (1.0, {"type": "state", "value": "listening"}),
]

async def handler(ws):
    print("client connected")
    for delay, msg in SCRIPT:
        await asyncio.sleep(delay)
        await ws.send(json.dumps(msg))
    async for raw in ws:
        print("from shell:", raw)

async def main():
    async with websockets.serve(handler, "127.0.0.1", 8765):
        await asyncio.Future()

asyncio.run(main())
