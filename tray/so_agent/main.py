"""system-optimize-agent: the optional tuning advisor.

  system-optimize-agent check                 is the model server up, is the model there
  system-optimize-agent ask "QUESTION"        one question, answer on stdout
  system-optimize-agent chat                  a conversation in the terminal
  system-optimize-agent run --scheduled       the timer's job: analyse, maybe propose, notify
  system-optimize-agent triage [--since 1h] [--propose] [--json]
                                              the quick look: pressure, readings and journal
                                              warnings decided by rules (and Laya when set up)
  system-optimize-agent proposal [--json]     the pending proposal
  system-optimize-agent approve [--yes]       apply the pending proposal (asks for your password)
  system-optimize-agent dismiss               drop the pending proposal
  system-optimize-agent schedule [CRON|off]   show or set when it runs on its own (default @daily)
  system-optimize-agent model [NAME]          show or set the model (default qwen3:4b)

Options --model, --backend and --url override the config for one command.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

from . import DEFAULT_MODEL
from . import config as cfgmod
from . import schedule as sched
from . import store
from . import triage as triagemod
from .agent import SCHEDULED_TASK, Agent
from .llm import LlmError, client
from .tools import Proposal


def _cli():
    from so_tray.cli import Cli    # shared with the tray app
    return Cli()


def self_exe():
    return shutil.which("system-optimize-agent") or os.path.realpath(sys.argv[0])


def notify(title, body):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "system-optimize", "-i", "system-optimize-tray", title, body],
                       check=False, timeout=10, capture_output=True)


def build_parser():
    p = argparse.ArgumentParser(prog="system-optimize-agent", description="Local-LLM tuning advisor for system-optimize.")
    p.add_argument("--model", help="model to use (default from config, %s)" % DEFAULT_MODEL)
    p.add_argument("--backend", choices=("ollama", "llamacpp"))
    p.add_argument("--url", help="model server URL")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    a = sub.add_parser("ask")
    a.add_argument("question")
    a.add_argument("--json", action="store_true")
    sub.add_parser("chat")
    r = sub.add_parser("run")
    r.add_argument("--scheduled", action="store_true")
    pr = sub.add_parser("proposal")
    pr.add_argument("--json", action="store_true")
    ap = sub.add_parser("approve")
    ap.add_argument("--yes", action="store_true")
    sub.add_parser("dismiss")
    t = sub.add_parser("triage")
    t.add_argument("--since", default="1h", help="how far back in the journal: 30m, 1h, 1d (default 1h)")
    t.add_argument("--propose", action="store_true", help="save a suggestion for a confident finding")
    t.add_argument("--json", action="store_true")
    s = sub.add_parser("schedule")
    s.add_argument("expr", nargs="?")
    m = sub.add_parser("model")
    m.add_argument("name", nargs="?")
    return p


def load_cfg(args):
    return cfgmod.load(overrides={"AGENT_MODEL": args.model, "AGENT_BACKEND": args.backend,
                                  "AGENT_URL": args.url})


def make_agent(cfg, cli=None, keep_alive=None):
    c = client(cfg, cfgmod.backend_url(cfg), keep_alive=keep_alive)
    return Agent(c, cli or _cli(), max_rounds=int(cfg["AGENT_MAX_ROUNDS"])), c


def cmd_check(cfg, out):
    url = cfgmod.backend_url(cfg)
    c = client(cfg, url)
    try:
        models = c.models()
    except LlmError as exc:
        out.write("model server: not reachable (%s)\n" % exc)
        return 1
    have = cfg["AGENT_MODEL"] in models or (cfg["AGENT_MODEL"] + ":latest") in models
    out.write("model server: %s (%s)\nmodel: %s (%s)\n" % (
        url, cfg["AGENT_BACKEND"], cfg["AGENT_MODEL"], "present" if have else "missing: ollama pull " + cfg["AGENT_MODEL"]))
    out.write("schedule: %s\nnext run: %s\n" % (cfg["AGENT_SCHEDULE"], sched.next_run() or "not scheduled"))
    return 0 if have else 1


def cmd_run(cfg, out, cli=None):
    """The scheduled job: unattended, so it only ever proposes."""
    agent, c = make_agent(cfg, cli, keep_alive=0)
    task = SCHEDULED_TASK
    if cfg["AGENT_BENCHMARK"] != "1":
        task += " Do not run a benchmark."
    if cfg["AGENT_TRIAGE"] != "off":
        try:        # the quick look first: the model gets facts already decided, not raw logs
            task += "\n\n" + triagemod.digest(make_triage(cfg)[0].run(gather_signals("1d")))
        except Exception:
            pass
    try:
        reply = agent.ask(task)
    except LlmError as exc:
        store.log_run({"kind": "scheduled", "ok": False, "error": str(exc)})
        out.write("agent: %s\n" % exc)
        return 1
    finally:
        c.unload()
    store.log_run({"kind": "scheduled", "ok": True, "text": reply.text[:500],
                   "proposal": reply.proposal.to_dict() if reply.proposal else None})
    out.write(reply.text + "\n")
    if reply.proposal:
        store.save_proposal(reply.proposal.to_dict())
        out.write("proposal: %s\n" % reply.proposal.summary())
        if cfg["AGENT_NOTIFY"] == "1":
            notify("Tuning suggestion: %s" % reply.proposal.summary(),
                   reply.proposal.reason + "\nOpen system-optimize to approve or dismiss it.")
    return 0


def make_triage(cfg):
    """(Triage, a note about the backend or '')."""
    if cfg["AGENT_TRIAGE"] == "laya":
        try:
            import laya  # noqa: F401
        except ImportError:
            return triagemod.Triage(), "AGENT_TRIAGE=laya but laya is not installed (pip install laya): rules only"
        return triagemod.Triage(text_model=triagemod.Laya()), ""
    return triagemod.Triage(), ""


def gather_signals(since):
    from so_tray.monitor import Monitor
    signals = triagemod.journal_signals(since)
    try:
        signals += triagemod.signals_from_sample(Monitor(root=os.environ.get("SO_ROOT", "/")).sample())
    except Exception:       # a broken sensor must not stop the look at the journal
        pass
    return signals


def cmd_triage(args, cfg, out, cli=None, signals=None):
    if cfg["AGENT_TRIAGE"] == "off":
        out.write("triage is off (AGENT_TRIAGE=off)\n")
        return 0
    if not triagemod.SINCE_RE.match(args.since):
        print("system-optimize-agent: --since takes a number and s, m, h or d (30m, 1h, 1d)", file=sys.stderr)
        return 2
    t, note = make_triage(cfg)
    findings = t.run(signals if signals is not None else gather_signals(args.since))
    proposal = None
    if findings:
        info = (cli or _cli()).describe()
        proposal = next((p for p in (triagemod.recommend(f, info) for f in findings) if p), None)
    saved = False
    if proposal and args.propose and not store.load_proposal():
        store.save_proposal(dict(proposal.to_dict(), source="triage"))
        saved = True
    backend = "laya" if t.text_model is not None else "rules"
    if args.json:
        out.write(json.dumps({"findings": [f.to_dict() for f in findings],
                              "proposal": proposal.to_dict() if proposal else None, "backend": backend}) + "\n")
        return 0
    if note:
        out.write(note + "\n")
    for err in t.errors:
        out.write("triage model error: %s\n" % err)
    if not findings:
        out.write("Nothing needs attention (%s, the last %s).\n" % (backend, args.since))
        return 0
    for f in findings:
        out.write("%s: %s, seen %d time%s (%s, %s)\n" % (
            f.kind, triagemod.SEVERITIES[f.severity], f.count, "" if f.count == 1 else "s",
            "confident" if f.route == "auto" else "unsure: worth asking the agent", f.backend))
        out.write("    %s\n" % f.what)
        for line in f.evidence:
            out.write("    log: %s\n" % line)
    if proposal:
        out.write("\nSuggestion: %s\n  %s\n" % (proposal.summary(), proposal.reason))
        if saved:
            out.write("Saved as the pending suggestion (system-optimize-agent approve, or the dashboard).\n")
        elif args.propose:
            out.write("Not saved: another suggestion is already pending.\n")
        else:
            out.write("Run again with --propose to save it for approval.\n")
    return 0


def cmd_approve(args, out, cli=None):
    d = store.load_proposal()
    if not d:
        out.write("no pending proposal\n")
        return 1
    p = Proposal.from_dict(d)
    if not args.yes:
        if not sys.stdin.isatty():
            out.write("approve needs --yes without a terminal\n")
            return 2
        ans = input("Apply: %s? [y/N] " % p.summary())
        if ans.strip().lower() not in ("y", "yes"):
            return 1
    rc, o, e = p.execute(cli or _cli())
    out.write((o + e).strip() + "\n")
    if rc == 0:
        store.clear_proposal()
    return 0 if rc == 0 else 1


def main(argv=None, out=sys.stdout, cli=None, signals=None):
    args = build_parser().parse_args(argv)
    try:
        cfg = load_cfg(args)
    except cfgmod.ConfigError as exc:
        print("system-optimize-agent: %s" % exc, file=sys.stderr)
        return 2
    if args.cmd == "check":
        return cmd_check(cfg, out)
    if args.cmd == "proposal":
        d = store.load_proposal()
        if args.json:
            out.write(json.dumps({"pending": bool(d), **(d or {})}) + "\n")
        else:
            out.write(("%s\n  %s\n" % (d["summary"], d.get("reason", ""))) if d else "no pending proposal\n")
        return 0
    if args.cmd == "triage":
        return cmd_triage(args, cfg, out, cli, signals)
    if args.cmd == "dismiss":
        store.clear_proposal()
        return 0
    if args.cmd == "approve":
        return cmd_approve(args, out, cli)
    if args.cmd == "schedule":
        if not args.expr:
            out.write("schedule: %s\nnext run: %s\n" % (cfg["AGENT_SCHEDULE"], sched.next_run() or "not scheduled"))
            return 0
        try:
            expr = args.expr.strip()
            if expr.lower() != "off":
                sched.normalise(expr)
            msg = sched.install(expr, self_exe())
            cfgmod.write_user_setting("AGENT_SCHEDULE", "off" if expr.lower() == "off" else expr)
        except (sched.ScheduleError, cfgmod.ConfigError) as exc:
            print("system-optimize-agent: %s" % exc, file=sys.stderr)
            return 2
        out.write(msg + "\n")
        return 0
    if args.cmd == "model":
        if not args.name:
            out.write(cfg["AGENT_MODEL"] + "\n")
            return 0
        try:
            cfgmod.write_user_setting("AGENT_MODEL", args.name)
        except cfgmod.ConfigError as exc:
            print("system-optimize-agent: %s" % exc, file=sys.stderr)
            return 2
        out.write("model set to %s (pull it with: ollama pull %s)\n" % (args.name, args.name))
        return 0
    if args.cmd == "run":
        return cmd_run(cfg, out, cli)
    agent, c = make_agent(cfg, cli)
    try:
        if args.cmd == "ask":
            reply = agent.ask(args.question)
            if reply.proposal:
                store.save_proposal(reply.proposal.to_dict())
            if args.json:
                out.write(json.dumps({"text": reply.text,
                                      "proposal": reply.proposal.to_dict() if reply.proposal else None}) + "\n")
            else:
                out.write(reply.text + "\n")
                if reply.proposal:
                    out.write("\nproposal: %s (system-optimize-agent approve)\n" % reply.proposal.summary())
            return 0
        # chat
        out.write("system-optimize agent (%s). Empty line to quit.\n" % cfg["AGENT_MODEL"])
        while True:
            try:
                q = input("> ").strip()
            except EOFError:
                break
            if not q:
                break
            reply = agent.ask(q)
            out.write(reply.text + "\n")
            if reply.proposal:
                store.save_proposal(reply.proposal.to_dict())
                out.write("proposal: %s (system-optimize-agent approve)\n" % reply.proposal.summary())
        return 0
    except LlmError as exc:
        print("system-optimize-agent: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
