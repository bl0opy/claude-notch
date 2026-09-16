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
from agentsd.snapshot import build
from agentsd.transcripts import Transcripts
from backend.bridge import NotchBridge


async def serve():
    transcripts = Transcripts()
    bridge = NotchBridge(config.ws_host, config.ws_port)
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

    bridge.on("approve", on_approve)
    await bridge.start()
    await inbox.start()
    logger.info(f"watching claude sessions, {config.tick_s}s tick")

    last: dict | None = None
    bridge.on_connect(lambda: [last, inbox.snapshot()])
    try:
        while True:
            snapshot = await asyncio.to_thread(build, transcripts)
            if last is None or snapshot["list"] != last["list"] or snapshot["degraded"] != last["degraded"]:
                await bridge.send(snapshot)
                last = snapshot
            await inbox.reconcile()
            await asyncio.sleep(config.tick_s)
    finally:
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
