"""validate-all's command line. A flag filters and its absence skips nothing
(the maintainer, 2026-09-06), so a flag this file does not know is refused
before anything starts: `--help` once started a whole matrix
(docs/media-player-plan.md M16 F3). tools/check-gates.py runs refuse()
over its cases."""

DEFAULT_HOST = "akhil@192.168.64.2"

USAGE = """usage: tools/validate-all.py [--serial] [--exclusive | --no-exclusive]
                             [--only <prefix,...>] [windows-host]

  --serial         run the five lanes one after another
  --exclusive      run only the input-driving legs every lane names EXCLUSIVE
  --no-exclusive   run everything but those legs
  --only P,...     run the legs whose names start with a prefix; FILTERED,
                   never the record
  windows-host     the Windows guest's ssh target (default akhil@192.168.64.2)
  -h, --help       print this and exit"""


class Refused(Exception):
    def __init__(self, code, text):
        super().__init__(text)
        self.code = code
        self.text = text


def parse(argv):
    """The run's choices, or Refused: code 0 with the usage for a help
    request, code 2 with a sentence naming the argument otherwise."""
    args = list(argv)
    chosen = {"mode": "parallel", "exclusive": None, "only": None, "host": None}
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            raise Refused(0, USAGE)
        if arg == "--serial":
            chosen["mode"] = "serial"
        elif arg in ("--exclusive", "--no-exclusive"):
            want = "only" if arg == "--exclusive" else "skip"
            if chosen["exclusive"] not in (None, want):
                raise Refused(2, "validate-all: --exclusive and --no-exclusive "
                                 "together leave nothing to run\n" + USAGE)
            chosen["exclusive"] = want
        elif arg == "--only":
            if not args or args[0].startswith("-"):
                raise Refused(2, "validate-all: --only takes a comma-separated "
                                 "list of leg prefixes\n" + USAGE)
            chosen["only"] = args.pop(0)
        elif arg.startswith("-"):
            raise Refused(2, f"validate-all: unknown flag {arg!r}; nothing was "
                             f"started\n" + USAGE)
        elif chosen["host"] is not None:
            raise Refused(2, f"validate-all: a second windows host {arg!r} after "
                             f"{chosen['host']!r}; nothing was started\n" + USAGE)
        else:
            chosen["host"] = arg
    chosen["host"] = chosen["host"] or DEFAULT_HOST
    return chosen
