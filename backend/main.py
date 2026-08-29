import asyncio
import sys

from loguru import logger
from pipecat.frames.frames import InterruptionFrame, TTSSpeakFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.deepgram.flux.stt import DeepgramFluxSTTService
from pipecat.services.deepgram.tts import DeepgramTTSService
from pipecat.transports.local.audio import LocalAudioTransport, LocalAudioTransportParams

from backend.approvals import ApprovalServer
from backend.audio_devices import resolve_device
from backend.bridge import NotchBridge
from backend.claude_code import ClaudeCodeSession
from backend.mic_gate import MicGate
from backend.ptt import PushToTalkGate
from backend.config import ROOT, config
from backend.processor import ClaudeCodeProcessor
from backend.speech import SPEECH_SYSTEM_PROMPT


def build_stt() -> DeepgramFluxSTTService:
    return DeepgramFluxSTTService(
        api_key=config.deepgram_api_key,
        should_interrupt=True,
        settings=DeepgramFluxSTTService.Settings(
            model=config.deepgram_model,
            eot_threshold=config.eot_threshold,
            eot_timeout_ms=config.eot_timeout_ms,
        ),
    )


def build_tts() -> DeepgramTTSService:
    return DeepgramTTSService(
        api_key=config.deepgram_api_key,
        sample_rate=config.tts_sample_rate,
        settings=DeepgramTTSService.Settings(voice=config.deepgram_voice),
    )


async def run():
    missing = config.missing_keys()
    if missing:
        logger.error(f"missing env vars: {', '.join(missing)} — copy .env.example to .env")
        return 1

    bridge = NotchBridge(config.ws_host, config.ws_port)
    await bridge.start()

    approvals = ApprovalServer(config.ws_host, config.approval_port, config.approval_timeout_s)
    await approvals.start()

    hook = ROOT / "hooks" / "approve.py"
    session = ClaudeCodeSession(
        cwd=config.claude_cwd,
        model=config.claude_model,
        permission_mode=config.permission_mode,
        system_prompt=SPEECH_SYSTEM_PROMPT,
        settings={
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": ".*",
                        "hooks": [{"type": "command", "command": f"{sys.executable} {hook}"}],
                    }
                ]
            }
        },
    )

    rate = config.audio_sample_rate
    in_index, in_name, in_native = resolve_device(config.input_device, want_input=True)
    out_index, out_name, out_native = resolve_device(config.output_device, want_input=False)
    logger.info(f"audio in: {in_name} @ {rate} Hz (device native {in_native})")
    logger.info(f"audio out: {out_name} @ {rate} Hz (device native {out_native})")
    for name, native in ((in_name, in_native), (out_name, out_native)):
        if native and native != rate:
            logger.warning(
                f"{name} is native {native} Hz but we open it at {rate} Hz — "
                f"CoreAudio will resample. set AUDIO_SAMPLE_RATE={native}"
            )
    logger.info(f"tts: {config.tts_sample_rate} Hz -> {rate} Hz via soxr")

    transport = LocalAudioTransport(
        LocalAudioTransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_in_sample_rate=rate,
            audio_out_sample_rate=rate,
            input_device_index=in_index,
            output_device_index=out_index,
        )
    )
    stt = build_stt()
    tts = build_tts()
    brain = ClaudeCodeProcessor(
        session, bridge, config.cancel_on_interrupt, approvals, config.spoken_sentences
    )

    ptt = PushToTalkGate() if config.push_to_talk else None

    stages = [transport.input()]
    if ptt:
        stages.append(ptt)
        logger.info("push-to-talk on — hold the command key to talk")
    elif config.mic_gate:
        stages.append(MicGate(config.mic_gate_tail_ms))
        logger.info(f"mic gate on ({config.mic_gate_tail_ms} ms tail) — voice barge-in disabled")
    else:
        logger.info("mic gate off — expect the mic to hear the speakers unless you're on headphones")
    stages += [stt, brain, tts, transport.output()]

    pipeline = Pipeline(stages)
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            audio_in_sample_rate=rate,
            audio_out_sample_rate=rate,
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )

    async def on_interrupt(_msg):
        await task.queue_frame(InterruptionFrame())

    async def on_text(msg):
        text = (msg.get("text") or "").strip()
        if text:
            await brain.send_text_turn(text)

    async def on_approve(msg):
        await brain.resolve_approval(bool(msg.get("approved")), "from the notch")

    async def on_ptt(msg):
        if not ptt:
            return
        down = bool(msg.get("down"))
        ptt.set_open(down)
        await bridge.send({"type": "mic", "open": down})
        # Holding the key while it's talking is how you cut it off.
        if down and bridge.last_state == "speaking":
            await task.queue_frame(InterruptionFrame())

    async def on_say(msg):
        text = (msg.get("text") or "").strip()
        if text:
            await task.queue_frame(TTSSpeakFrame(text))

    approvals.on_ask(brain.ask_approval)
    bridge.on("approve", on_approve)
    bridge.on("interrupt", on_interrupt)
    bridge.on("ptt", on_ptt)
    bridge.on("text", on_text)
    bridge.on("say", on_say)

    runner = PipelineRunner(handle_sigint=True)
    try:
        await runner.run(task)
    finally:
        await approvals.stop()
        await bridge.stop()
        await session.stop()
    return 0


def main():
    logger.remove()
    logger.add(sys.stderr, level="INFO")
    try:
        sys.exit(asyncio.run(run()))
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
