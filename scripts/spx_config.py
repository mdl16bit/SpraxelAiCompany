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
    if cmd == "dump":
        print(json.dumps(load(game), indent=2))
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
