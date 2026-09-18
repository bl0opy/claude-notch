"""Spoken fleet commands, parsed without a model so they land instantly.

Anything that isn't one of these goes to the focused agent as a normal turn.

    yes / go / approve            the oldest open question (not if it's destructive)
    no / deny                     the oldest open question
    approve|deny <project>        that project's oldest question
    always allow <project>        and remember the rule, where Claude Code offered one
    what's waiting / status       one sentence about the fleet
    what's this costing / usage   tokens, dollars and the fullest window
    go to|switch to <project>     hand that agent the mic
    back / home                   the voice agent's own session again
    stop <project>                interrupt it, if the notch started it
"""
import re
from dataclasses import dataclass
from difflib import get_close_matches

_YES = {"yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go", "go ahead", "do it", "approve",
        "approved", "allow", "allow it", "fine", "please do", "affirmative", "sounds good", "confirm",
        "accept", "approve it", "yes please", "ship it"}
_NO = {"no", "nope", "nah", "don't", "dont", "cancel", "deny", "denied", "reject", "abort",
       "negative", "skip", "deny it", "don't do it", "no thanks"}
# A bare yes/no is only an answer when it's short — "ok but first rename it" is a turn.
_MAX_BARE_WORDS = 4

_APPROVE_VERB = r"(?:approve|allow|accept|yes(?:\s+(?:for|to))?|ok(?:ay)?(?:\s+for)?)"
_DENY_VERB = r"(?:deny|reject|decline|refuse|no(?:\s+(?:for|to))?)"
_FILLER = r"(?:the\s+|that\s+|one\s+(?:for|from|in)\s+|request\s+(?:for|from)\s+)*"

_ALWAYS = re.compile(rf"^always\s+(?:{_APPROVE_VERB}\s+)?{_FILLER}(?P<name>.+)$")
_APPROVE = re.compile(rf"^{_APPROVE_VERB}\s+{_FILLER}(?P<name>.+)$")
_DENY = re.compile(rf"^{_DENY_VERB}\s+{_FILLER}(?P<name>.+)$")
_FOCUS = re.compile(r"^(?:go\s+to|switch\s+to|focus(?:\s+on)?|talk\s+to|open)\s+(?P<name>.+)$")
_STOP = re.compile(r"^(?:stop|interrupt|cancel)\s+(?P<name>.+)$")
_HOME = {"back", "go back", "home", "go home", "back home", "back to home", "back to you"}
_STATUS = re.compile(
    r"^(?:status|fleet status|what'?s waiting|what is waiting|anything waiting|who needs me|"
    r"what needs me|what'?s everyone doing|what is everyone doing|what'?s going on|how are the agents)$"
)
_USAGE = re.compile(
    r"^(?:usage|cost|costs|the cost|spend|what'?s (?:this|it|that) cost(?:ing)?|"
    r"what is (?:this|it) costing|how much (?:is this|have (?:i|we) spent|does this cost)|"
    r"how many tokens|token usage|context usage|how full (?:is|are) (?:it|the context|the windows?))$"
)


@dataclass
class Command:
    kind: str  # answer | say | status | focus | home | stop
    id: str = ""
    approved: bool = False
    always: bool = False
    text: str = ""


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _key(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def match(spoken: str, names: list[str]) -> str | None:
    """The name a speech-to-text'd "bus tracker" meant: "bus-tracker"."""
    target = _key(spoken)
    if not target:
        return None
    keyed = {_key(n): n for n in names if n}
    if target in keyed:
        return keyed[target]
    # "descant" for descant-ide, but never "orbit config" for orbit.
    prefixed = [k for k in keyed if k.startswith(target) and len(target) >= 4]
    if len(prefixed) == 1:
        return keyed[prefixed[0]]
    close = get_close_matches(target, list(keyed), n=1, cutoff=0.72)
    return keyed[close[0]] if close else None


def _bare(words: list[str]) -> bool | None:
    if not words or len(words) > _MAX_BARE_WORDS:
        return None
    phrase = " ".join(words)
    if phrase in _YES:
        return True
    if phrase in _NO:
        return False
    # "yeah go ahead", "nope don't" — every word on one side.
    if all(w in _YES or w in {"ahead", "it", "please"} for w in words):
        return True
    if all(w in _NO or w in {"it", "thanks"} for w in words):
        return False
    return None


def _agent_name(agent: dict) -> list[str]:
    return [agent.get("project") or "", agent.get("name") or ""]


def _find_agent(spoken: str, agents: list[dict]) -> dict | None:
    names = [n for a in agents for n in _agent_name(a)]
    hit = match(spoken, names)
    return next((a for a in agents if hit in _agent_name(a)), None) if hit else None


def spoken_list(items: list[str]) -> str:
    return items[0] if len(items) == 1 else f"{', '.join(items[:-1])} and {items[-1]}"


def status_line(approvals: list[dict], agents: list[dict]) -> str:
    if approvals:
        asks = [f"{a['project'] or 'an agent'} wants to {a['summary']}" for a in approvals[:3]]
        more = f", and {len(approvals) - 3} more" if len(approvals) > 3 else ""
        head = "One waiting" if len(approvals) == 1 else f"{len(approvals)} waiting"
        line = f"{head}: {spoken_list(asks)}{more}."
    else:
        line = "Nothing's waiting on you."
    working = [a.get("project") or "one" for a in agents if a.get("state") == "working"]
    if working:
        names = spoken_list(working[:3] + ([f"{len(working) - 3} more"] if len(working) > 3 else []))
        line += f" {names} {'is' if len(working) == 1 else 'are'} working."
    elif agents:
        line += " Everyone else is idle."
    return line


def _tokens(n: int) -> str:
    """Said out loud, so "twenty point six million", not "20,595,665"."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f} million".replace(".0 ", " ")
    if n >= 1_000:
        return f"{round(n / 1_000)} thousand"
    return str(n)


def usage_line(totals: dict) -> str:
    if not totals or not totals.get("sessions"):
        return "Nothing's running."
    count = totals["sessions"]
    spend = totals.get("cost") or 0
    # "about 0 dollars" is worse than saying nothing about the amount.
    money = "under a dollar" if spend < 1 else f"about {spend:.0f} dollars"
    line = (
        f"{count} session{'s' if count != 1 else ''}, "
        f"{_tokens(totals.get('totalTokens') or 0)} tokens, "
        f"{money} at API rates."
    )
    context = totals.get("context") or {}
    fullest, whose = context.get("fullestPct") or 0, context.get("fullest")
    crowded = context.get("crowded") or 0
    if crowded:
        line += f" {crowded} {'window is' if crowded == 1 else 'windows are'} past three quarters."
    elif whose:
        line += f" Fullest window is {whose}, at {fullest:.0f} percent."
    return line


def parse(
    text: str,
    approvals: list[dict],
    agents: list[dict],
    totals: dict | None = None,
) -> Command | None:
    words = _words(text)
    if not words:
        return None
    phrase = " ".join(words)

    if _STATUS.match(phrase):
        return Command("status", text=status_line(approvals, agents))
    if _USAGE.match(phrase):
        return Command("status", text=usage_line(totals or {}))
    if phrase in _HOME:
        return Command("home")

    if approvals:
        verdict = _bare(words)
        if verdict is not None:
            oldest = approvals[0]
            if verdict and oldest.get("risky"):
                name = oldest.get("project") or "it"
                return Command("say", text=f"That one wants to {oldest['summary']} — say approve {name}.")
            return Command("answer", id=oldest["id"], approved=verdict)

        for pattern, approved, always in ((_ALWAYS, True, True), (_APPROVE, True, False), (_DENY, False, False)):
            found = pattern.match(phrase)
            if not found:
                continue
            spoken = found.group("name")
            hit = match(spoken, [a.get("project") or "" for a in approvals])
            if hit:
                request = next(a for a in approvals if a.get("project") == hit)
                return Command("answer", id=request["id"], approved=approved, always=always)
            if _find_agent(spoken, agents):
                return Command("say", text=f"Nothing from {spoken} is waiting.")

    found = _FOCUS.match(phrase)
    if found:
        agent = _find_agent(found.group("name"), agents)
        if agent:
            return Command("focus", id=agent["id"], text=agent.get("project") or "")
    found = _STOP.match(phrase)
    if found:
        agent = _find_agent(found.group("name"), agents)
        if agent:
            return Command("stop", id=agent["id"], text=agent.get("project") or "")
    return None
