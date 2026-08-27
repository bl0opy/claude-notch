import asyncio
import sys

from loguru import logger
from pipecat.frames.frames import InterruptionFrame, TTSSpeakFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.deepgram.flux.stt import DeepgramFluxSTTService
from pipecat.transports.local.audio import LocalAudioTransport, LocalAudioTransportParams

from backend.bridge import NotchBridge
from backend.claude_code import ClaudeCodeSession
from backend.config import config
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


def build_tts() -> CartesiaTTSService:
    return CartesiaTTSService(
        api_key=config.cartesia_api_key,
        settings=CartesiaTTSService.Settings(
            voice=config.cartesia_voice_id,
            model=config.cartesia_model,
        ),
    )


async def run():
    missing = config.missing_keys()
    if missing:
        logger.error(f"missing env vars: {', '.join(missing)} — copy .env.example to .env")
        return 1

    bridge = NotchBridge(config.ws_host, config.ws_port)
    await bridge.start()

    session = ClaudeCodeSession(
        cwd=config.claude_cwd,
        model=config.claude_model,
        permission_mode=config.permission_mode,
        system_prompt=SPEECH_SYSTEM_PROMPT,
    )

    transport = LocalAudioTransport(
        LocalAudioTransportParams(audio_in_enabled=True, audio_out_enabled=True)
    )
    stt = build_stt()
    tts = build_tts()
    brain = ClaudeCodeProcessor(session, bridge, config.cancel_on_interrupt)

    pipeline = Pipeline([transport.input(), stt, brain, tts, transport.output()])
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            audio_in_sample_rate=16000,
            audio_out_sample_rate=24000,
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

    async def on_say(msg):
        text = (msg.get("text") or "").strip()
        if text:
            await task.queue_frame(TTSSpeakFrame(text))

    bridge.on("interrupt", on_interrupt)
    bridge.on("text", on_text)
    bridge.on("say", on_say)

    runner = PipelineRunner(handle_sigint=True)
    try:
        await runner.run(task)
    finally:
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
