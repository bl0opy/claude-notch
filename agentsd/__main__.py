"""The agents daemon: watches every Claude Code session, serves the roster, and
holds every permission question any of them is waiting on.

Deliberately separate from the voice backend — no audio, no API key, so the
notch keeps its dashboard and its approvals when the voice pipeline is down.
"""
import argparse
import asyncio
import json
import sys

from loguru import logger

from agentsd.config import config
from agentsd.inbox import Inbox
from agentsd.pty_host import PtyHost
from agentsd.snapshot import build
from agentsd.transcripts import Transcripts
from agentsd.window import WindowServer, page_origins
from backend.bridge import NotchBridge

# Esc is a keypress the TUI has to read and act on before the next line lands,
# or the line is typed into the turn being cancelled.
STEER_PAUSE_S = 0.4


async def serve():
    transcripts = Transcripts()
    # The terminal window reads the roster from here too, so its page is the
    # one browser origin let in.
    bridge = NotchBridge(
        config.ws_host, config.ws_port, origins=page_origins(config.ws_host, config.window_port)
    )
    pty = PtyHost()
    window = WindowServer(
        config.ws_host, config.window_port, pty, f"ws://{config.ws_host}:{config.ws_port}"
    )
    inbox = Inbox(
        config.ws_host,
        config.inbox_port,
        bridge.send,
        owned_timeout_s=config.owned_timeout_s,
        terminal_timeout_s=config.terminal_timeout_s,
    )

    async def on_approve(msg):
        inbox.answer(
            str(msg.get("id") or ""),
            bool(msg.get("approved")),
            always=bool(msg.get("always")),
            how=str(msg.get("how") or "from the notch"),
        )

    last: dict | None = None

    def row_state(session_id: str) -> str:
        rows = (last or {}).get("list") or []
        return next((r["state"] for r in rows if r["id"] == session_id), "unknown")

    async def fail(message: str):
        logger.warning(message)
        await bridge.send({"type": "error", "message": message})

    async def on_spawn(msg):
        cwd = str(msg.get("cwd") or "").strip()
        try:
            hosted = pty.spawn(cwd)
        except (OSError, ValueError, RuntimeError) as e:
            await fail(f"could not start an agent in {cwd}: {e}")
            return
        await bridge.send({"type": "spawned", "id": hosted.id, "cwd": hosted.cwd})

    async def on_resume(msg):
        try:
            hosted = pty.resume(str(msg.get("id") or ""))
        except (KeyError, OSError, RuntimeError) as e:
            await fail(f"could not resume that session: {e}")
            return
        await bridge.send({"type": "spawned", "id": hosted.id, "cwd": hosted.cwd})

    async def on_stop(msg):
        pty.stop(str(msg.get("id") or ""))

    async def on_forget(msg):
        pty.forget(str(msg.get("id") or ""))

    async def on_interrupt(msg):
        pty.interrupt(str(msg.get("id") or ""))

    async def on_type(msg):
        """A line for a hosted session — typed into its prompt, like a person would."""
        session_id = str(msg.get("id") or "")
        text = str(msg.get("text") or "")
        if session_id not in pty.running_ids():
            status = "gone"
        elif row_state(session_id) == "waiting":
            # Its screen is a permission dialog: keys would answer it.
            status = "waiting"
        elif msg.get("steer") and row_state(session_id) == "working":
            pty.interrupt(session_id)
            await asyncio.sleep(STEER_PAUSE_S)
            await pty.type(session_id, text)
            status = "steered"
        else:
            await pty.type(session_id, text)
            status = "sent"
        await bridge.send({"type": "typed", "id": session_id, "status": status})

    bridge.on("approve", on_approve)
    bridge.on("spawn", on_spawn)
    bridge.on("resume", on_resume)
    bridge.on("stop", on_stop)
    bridge.on("forget", on_forget)
    bridge.on("interrupt", on_interrupt)
    bridge.on("type", on_type)
    pty.on_change = lambda: asyncio.create_task(bridge.send(pty.snapshot()))
    await bridge.start()
    await inbox.start()
    await window.start()
    logger.info(f"watching claude sessions, {config.tick_s}s tick")

    bridge.on_connect(lambda: [last, inbox.snapshot(), pty.snapshot()])
    try:
        while True:
            snapshot = await asyncio.to_thread(build, transcripts, None, pty.running_ids())
            if last is None or snapshot["list"] != last["list"] or snapshot["degraded"] != last["degraded"]:
                await bridge.send(snapshot)
                last = snapshot
            await inbox.reconcile()
            await asyncio.sleep(config.tick_s)
    finally:
        await pty.shutdown()
        await window.stop()
        await inbox.stop()
        await bridge.stop()


def main():
    parser = argparse.ArgumentParser(prog="agentsd")
    parser.add_argument("--once", action="store_true", help="print one snapshot and exit")
    args = parser.parse_args()

    logger.remove()
    logger.add(sys.stderr, level="INFO")

    if args.once:
        print(json.dumps(build(Transcripts()), indent=2))
        return 0
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
