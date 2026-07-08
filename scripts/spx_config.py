#!/usr/bin/env python3
"""spx_config — resolve Spraxel config (multi-game aware).

Loads COMPANY_CONFIG.yaml (framework defaults) and deep-merges an optional
per-game GAME_CONFIG.yaml (at <game_dir>/GAME_CONFIG.yaml) on top, so a game can
override any key without forking the framework config.

Game selection:
  - Config may declare a `games:` registry (slug -> {dir, enabled}). If absent,
    a single-entry registry is synthesized from the legacy `game_dir:` scalar
    (slug = basename of that dir). This keeps single-game configs working.
  - The "current" game for load()/get() is, in order: an explicit game= arg, the
    $SPRAXEL_GAME env var, else the sole enabled game (deterministic first when >1).

CLI:
  spx_config.py get <dotted.key> [--default X] [--game SLUG]  # scalar→raw; dict/list→JSON; exit 1 if missing & no default
  spx_config.py dump [--game SLUG]                            # full merged config as JSON
  spx_config.py games                                         # one line per game: "slug<TAB>dir<TAB>enabled"
  spx_config.py game-dir <slug>                               # absolute dir for a game slug (exit 1 if unknown)

Import:
  from spx_config import load, get, games, game_dir
  model = get("models.developer")                 # honors GAME_CONFIG override for the current game
  model = get("models.developer", game="newgame") # explicit game
"""
import sys, os, json

try:
    import yaml
except ImportError:
    sys.stderr.write("spx_config: PyYAML not available\n")
    yaml = None

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPANY = os.path.join(REPO, "COMPANY_CONFIG.yaml")


def _load_yaml(path):
    if not path or not os.path.exists(path) or yaml is None:
        return {}
    try:
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        sys.stderr.write(f"spx_config: failed to parse {path}: {e}\n")
        return {}


def _deep_merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def _company():
    return _load_yaml(COMPANY)


def games(company=None):
    """Return the game registry as a list of {slug, dir, enabled} dicts.

    Sources, in order:
      1. a `games:` map in COMPANY_CONFIG.yaml  -> one entry per slug
      2. the legacy `game_dir:` scalar          -> synthesized one-entry registry
    The slug for the legacy fallback is the basename of game_dir.
    """
    company = company if company is not None else _company()
    reg = company.get("games")
    out = []
    if isinstance(reg, dict) and reg:
        for slug, spec in reg.items():
            spec = spec or {}
            d = os.path.expanduser(str(spec.get("dir", "") or ""))
            enabled = bool(spec.get("enabled", True))
            out.append({"slug": str(slug), "dir": d, "enabled": enabled})
        return out
    # Legacy fallback: single game from game_dir scalar.
    gd = os.path.expanduser(str(company.get("game_dir", "") or ""))
    if gd:
        out.append({"slug": os.path.basename(gd.rstrip("/")) or "game", "dir": gd, "enabled": True})
    return out


def _resolve_game(game=None, company=None):
    """Return (slug, dir) for the requested/current game, or (None, "") if none."""
    company = company if company is not None else _company()
    reg = games(company)
    if not reg:
        return (None, "")
    want = game or os.environ.get("SPRAXEL_GAME") or ""
    if want:
        for g in reg:
            if g["slug"] == want:
                return (g["slug"], g["dir"])
        # Allow passing a dir or a path basename too.
        wexp = os.path.expanduser(want)
        for g in reg:
            if g["dir"] == wexp or os.path.basename(g["dir"].rstrip("/")) == want:
                return (g["slug"], g["dir"])
        sys.stderr.write(f"spx_config: unknown game {want!r}\n")
        return (None, "")
    enabled = [g for g in reg if g["enabled"]] or reg
    return (enabled[0]["slug"], enabled[0]["dir"])


def game_dir(game=None, company=None):
    """Absolute dir for the requested/current game ("" if unresolved)."""
    return _resolve_game(game, company)[1]


# ── "Current game" resolution for interactive entry points ──────────────────
# Priority (the CEO's intent): explicit > $SPRAXEL_GAME > the game whose folder
# we're inside > the last game a skill/command operated on > the sole enabled
# game > None (genuinely ambiguous → the caller should ASK).
LAST_GAME_FILE = os.path.join(REPO, ".cache", "last-game")


def _cwd_game(cwd, company=None):
    """Slug of the registered game whose dir contains cwd, else None."""
    cwd = os.path.abspath(cwd or os.getcwd())
    for g in games(company):
        d = os.path.abspath(g["dir"]) if g["dir"] else ""
        if d and (cwd == d or cwd.startswith(d + os.sep)):
            return g["slug"]
    return None


def current_game(explicit=None, cwd=None):
    """Resolve the current game slug, or None if genuinely ambiguous."""
    company = _company()
    reg = games(company)
    by_slug = {g["slug"]: g for g in reg}
    enabled = [g for g in reg if g["enabled"]] or reg
    if explicit:
        return _resolve_game(explicit, company)[0]
    env = os.environ.get("SPRAXEL_GAME")
    if env and env in by_slug:
        return env
    cg = _cwd_game(cwd, company)
    if cg:
        return cg
    try:
        last = open(LAST_GAME_FILE).read().strip()
        if last in by_slug and by_slug[last]["enabled"]:
            return last
    except Exception:
        pass
    if len(enabled) == 1:
        return enabled[0]["slug"]
    return None


def set_current(slug):
    """Record `slug` as the last-operated-on game (best-effort)."""
    s = _resolve_game(slug)[0]
    if not s:
        return False
    os.makedirs(os.path.dirname(LAST_GAME_FILE), exist_ok=True)
    with open(LAST_GAME_FILE, "w") as f:
        f.write(s + "\n")
    return True


# ── Namespaced state layout (single source of truth; gctx.sh mirrors this) ──────
# Per-game operational state is namespaced by slug so multiple games never collide.
# Framework-global state (sonnet-cap, token/$ accounting, last-tick-wall, .paused)
# stays under the flat .cache / repo root — it reflects the one account / machine.
def state_dir(slug):       return os.path.join(REPO, "state", slug)
def locks_dir(slug):       return os.path.join(state_dir(slug), "locks")
def cache_dir(slug):       return os.path.join(state_dir(slug), "cache")
def game_logs_dir(slug):   return os.path.join(REPO, "logs", slug)
def worktrees_dir(slug):   return os.path.join(REPO, ".worktrees", slug)
def global_cache():        return os.path.join(REPO, ".cache")


def load(game=None):
    """Return the merged config: COMPANY_CONFIG.yaml overlaid by <game_dir>/GAME_CONFIG.yaml.

    `game` selects which game's GAME_CONFIG.yaml to overlay (default: current game).
    """
    company = _company()
    gd = game_dir(game, company)
    game_cfg = os.path.join(gd, "GAME_CONFIG.yaml") if gd else ""
    return _deep_merge(company, _load_yaml(game_cfg))


def get(dotted, default=None, cfg=None, game=None):
    cur = load(game) if cfg is None else cfg
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


def _opt(argv, name):
    """Pull `--name VALUE` out of argv; returns VALUE or None (mutates argv)."""
    if name in argv:
        i = argv.index(name)
        try:
            val = argv[i + 1]
        except IndexError:
            return None
        del argv[i:i + 2]
        return val
    return None


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    cmd = argv[0]
    rest = list(argv[1:])
    game = _opt(rest, "--game")

    if cmd == "games":
        for g in games():
            print(f"{g['slug']}\t{g['dir']}\t{'1' if g['enabled'] else '0'}")
        return 0
    if cmd == "game-dir":
        if not rest:
            sys.stderr.write("usage: spx_config.py game-dir <slug>\n")
            return 2
        gd = game_dir(rest[0])
        if not gd:
            return 1
        print(gd)
        return 0
    if cmd == "current":
        # Print the resolved current-game slug, or exit 3 (ambiguous) listing the
        # enabled slugs on stderr so the caller can ASK the CEO which one.
        slug = current_game(explicit=game)
        if slug:
            print(slug)
            return 0
        sys.stderr.write("ambiguous: " + " ".join(
            g["slug"] for g in games() if g["enabled"]) + "\n")
        return 3
    if cmd == "set-current":
        if not rest:
            sys.stderr.write("usage: spx_config.py set-current <slug>\n")
            return 2
        return 0 if set_current(rest[0]) else 1
    if cmd == "paths":
        if not rest:
            sys.stderr.write("usage: spx_config.py paths <slug>\n")
            return 2
        slug = rest[0]
        print(f"GAME_DIR\t{game_dir(slug)}")
        print(f"STATE_DIR\t{state_dir(slug)}")
        print(f"LOCKS_DIR\t{locks_dir(slug)}")
        print(f"CACHE_DIR\t{cache_dir(slug)}")
        print(f"GAME_LOGS_DIR\t{game_logs_dir(slug)}")
        print(f"WORKTREES_DIR\t{worktrees_dir(slug)}")
        print(f"GLOBAL_CACHE\t{global_cache()}")
        return 0
    if cmd == "dump":
        print(json.dumps(load(game), indent=2))
        return 0
    if cmd == "agents":
        # Crew cron registry as `name|cron` lines — the ONE parser for the
        # agents: block (replaces the copy-pasted regex parsers that used to
        # live in tick.sh / catch_up.sh and silently broke on block-style YAML).
        for name, spec in (load(game).get("agents") or {}).items():
            cron = (spec or {}).get("cron") if isinstance(spec, dict) else None
            if cron:
                print(f"{name}|{cron}")
        return 0
    if cmd == "get":
        if not rest:
            sys.stderr.write("usage: spx_config.py get <dotted.key> [--default X] [--game SLUG]\n")
            return 2
        default = _opt(rest, "--default")
        val = get(rest[0], default=default, game=game)
        if val is None:
            return 1
        print(json.dumps(val) if isinstance(val, (dict, list)) else val)
        return 0
    sys.stderr.write(f"spx_config: unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
