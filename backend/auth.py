"""The secret that lets something talk to the notch's sockets.

Those sockets can approve permission questions and type into sessions, and
binding to localhost only keeps other machines out. Any process here can connect,
including a sandboxed command an agent ran without asking. An Origin check stops
web pages, but anything else can send whatever Origin it likes.

So every connection has to show a token from a file only this user can read.
Under Claude Code's sandbox that file is out of a command's reach as long as
~/Library/Application Support isn't readable there, which is the case with
`blockReadsOutsideWorkingDirectories` on, or with this path in
`sandbox.filesystem.denyRead`.
"""
import hmac
import os
import secrets
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

DEFAULT_FILE = Path.home() / "Library" / "Application Support" / "notch-agent" / "bridge-token"


def token_file() -> Path:
    return Path(os.getenv("NOTCH_TOKEN_FILE") or DEFAULT_FILE)


def token() -> str:
    """This machine's token, made the first time anything asks for it."""
    path = token_file()
    try:
        existing = path.read_text().strip()
    except FileNotFoundError:
        existing = ""
    if existing:
        return existing
    path.parent.mkdir(parents=True, exist_ok=True)
    fresh = secrets.token_urlsafe(32)
    # Written aside and linked into place, so the daemon and the voice backend
    # starting together can't each make their own, or read a half-written one.
    draft = path.with_name(f"{path.name}.{os.getpid()}")
    fd = os.open(draft, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(fresh)
    try:
        os.link(draft, path)
    except FileExistsError:
        return path.read_text().strip()
    finally:
        draft.unlink()
    return fresh


def matches(candidate: str) -> bool:
    return hmac.compare_digest(candidate.encode(), token().encode())


def headers() -> dict[str, str]:
    """For a client that can set headers."""
    return {"Authorization": f"Bearer {token()}"}


def refuse_without_token(connection, request):
    """A websockets `process_request`: a 401 unless the handshake shows the token.

    Browsers can't set headers on a websocket, so the page sends it in the query.
    """
    header = request.headers.get("Authorization", "")
    shown = header.removeprefix("Bearer ") if header.startswith("Bearer ") else ""
    if not shown:
        shown = parse_qs(urlsplit(request.path).query).get("token", [""])[0]
    if matches(shown):
        return None
    return connection.respond(HTTPStatus.UNAUTHORIZED, "the notch's token is required\n")
