"""Proves the foreign-agent tail: commentary isn't spoken, partial writes survive.

    .venv/bin/python scripts/tail_smoke.py
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agentsd.tail import TranscriptTail

MID = "msg_01abc"


def row(kind, **body):
    return json.dumps({"type": kind, **body}, ensure_ascii=False)


def assistant(mid, *blocks):
    return row("assistant", message={"id": mid, "content": list(blocks)})


def text(s):
    return {"type": "text", "text": s}


def tool(name="Bash"):
    return {"type": "tool_use", "name": name, "input": {}}


END = row("system", subtype="turn_duration", durationMs=1000)

failures = []


def check(label, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        print(f"       got  {got!r}\n       want {want!r}")
        failures.append(label)


def write(path, *lines):
    with path.open("a") as handle:
        for line in lines:
            handle.write(line + "\n")


with tempfile.TemporaryDirectory() as tmp:
    # 1. The measured shape: commentary, a tool call, then the real answer.
    p = Path(tmp) / "a.jsonl"
    p.touch()
    tail = TranscriptTail(p)
    write(
        p,
        assistant(MID, {"type": "thinking", "thinking": "hmm"}),
        assistant(MID, text("Let me check the config.")),
        assistant(MID, tool()),
        assistant("msg_02", text("Port 8765, and it's already listening.")),
        END,
    )
    got = tail.poll()
    check("commentary is shown", got.said,
          ["Let me check the config.", "Port 8765, and it's already listening."])
    check("only the post-tool text is spoken", got.answer,
          "Port 8765, and it's already listening.")
    check("turn end is reported", got.ended, True)

    # 2. A turn with no tool calls speaks in full.
    p = Path(tmp) / "b.jsonl"
    p.touch()
    tail = TranscriptTail(p)
    write(p, assistant("msg_03", text("Nothing to do — it's clean.")), END)
    check("toolless turn speaks whole", tail.poll().answer, "Nothing to do — it's clean.")

    # 3. A read landing mid-write must not lose the line.
    p = Path(tmp) / "c.jsonl"
    p.touch()
    tail = TranscriptTail(p)
    whole = assistant("msg_04", text("The migration finished.")) + "\n"
    with p.open("a") as handle:
        handle.write(whole[:40])          # half a line, as the writer would leave it
        handle.flush()
    check("partial line says nothing yet", tail.poll().said, [])
    with p.open("a") as handle:
        handle.write(whole[40:])
    write(p, END)
    got = tail.poll()
    check("partial line completes", got.said, ["The migration finished."])
    check("and is spoken", got.answer, "The migration finished.")

    # 4. The same block rewritten on a later row is said once.
    p = Path(tmp) / "d.jsonl"
    p.touch()
    tail = TranscriptTail(p)
    write(p, assistant("msg_05", text("Done.")))
    first = tail.poll().said
    write(p, assistant("msg_05", text("Done."), tool()), END)
    second = tail.poll()
    check("rewritten block isn't repeated", first + second.said, ["Done."])
    check("a trailing tool call empties the answer", second.answer, "")

    # 5. Multibyte text survives a chunk boundary.
    p = Path(tmp) / "e.jsonl"
    p.touch()
    tail = TranscriptTail(p)
    line = assistant("msg_06", text("it's 24 kHz — resampled locally")) + "\n"
    raw = line.encode()
    split = raw.index("—".encode()) + 1          # mid em-dash
    with p.open("ab") as handle:
        handle.write(raw[:split])
    tail.poll()
    with p.open("ab") as handle:
        handle.write(raw[split:])
    write(p, END)
    check("split multibyte char is intact", tail.poll().answer,
          "it's 24 kHz — resampled locally")

print()
if failures:
    print(f"{len(failures)} failed: {', '.join(failures)}")
    sys.exit(1)
print("all good")
