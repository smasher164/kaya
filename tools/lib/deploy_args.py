"""deploy-win's command line, the twin of matrix_args: `--help` once started a whole Windows
run, since the first argument was taken as the host. A help request or any argument this file
does not know is refused before anything starts. tools/check-gates.py runs parse() over its
cases."""

PHASES = ("caption-centre", "enable-dumps", "crash-report", "analyze-dump")

USAGE = """usage: tools/deploy-win.py user@host [--provision] [all | <leg>... | <phase> | probe=<name>]

  user@host      the Windows guest's ssh target, first
  --provision    install the guest's toolchains before the run
  all            every leg on the roster (the default)
  <leg>...       these legs, in the order given (tools/lib/lanes/win.py's roster)
  <phase>        one of caption-centre, enable-dumps, crash-report, analyze-dump
  probe=<name>   one probe
  -h, --help     print this and exit"""


class Refused(Exception):
    def __init__(self, code, text):
        super().__init__(text)
        self.code = code
        self.text = text


def parse(argv, legs):
    """The run's choices, or Refused: code 0 with the usage for a help request, code 2 with a
    sentence naming the argument otherwise."""
    args = list(argv)
    if any(a in ("-h", "--help") for a in args):
        raise Refused(0, USAGE)
    if not args:
        raise Refused(2, "deploy-win: no host; nothing was started\n" + USAGE)
    host = args.pop(0)
    if host.startswith("-") or "@" not in host:
        raise Refused(2, f"deploy-win: the first argument {host!r} is not a user@host; "
                         f"nothing was started\n" + USAGE)
    chosen = {"host": host, "provision": False, "suite": "all", "legs": []}
    for arg in args:
        if arg == "--provision":
            chosen["provision"] = True
        elif arg == "all" or arg in PHASES or arg.startswith("probe="):
            chosen["suite"] = arg
        elif arg in legs:
            chosen["legs"].append(arg)
            chosen["suite"] = arg
        elif arg.startswith("-"):
            raise Refused(2, f"deploy-win: unknown flag {arg!r}; nothing was started\n" + USAGE)
        else:
            raise Refused(2, f"deploy-win: unknown argument {arg!r} (not a leg, a phase or "
                             f"probe=); nothing was started\n" + USAGE)
    return chosen
