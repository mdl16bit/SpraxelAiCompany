#!/usr/bin/env python3
"""spx_config — resolve Spraxel config.

Loads COMPANY_CONFIG.yaml (framework defaults) and deep-merges an optional
per-game GAME_CONFIG.yaml (at <game_dir>/GAME_CONFIG.yaml) on top, so a game can
override any key without forking the framework config.

CLI:
  spx_config.py get <dotted.key> [--default X]   # scalar → raw; dict/list → JSON; exit 1 if missing & no default
  spx_config.py dump                              # full merged config as JSON

Import:
  from spx_config import load, get
  model = get("models.developer")                 # honors GAME_CONFIG override
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


def load():
    """Return the merged config: COMPANY_CONFIG.yaml overlaid by <game_dir>/GAME_CONFIG.yaml."""
    company = _load_yaml(COMPANY)
    game_dir = os.path.expanduser(str(company.get("game_dir", "") or ""))
    game_cfg = os.path.join(game_dir, "GAME_CONFIG.yaml") if game_dir else ""
    return _deep_merge(company, _load_yaml(game_cfg))


def get(dotted, default=None, cfg=None):
    cur = load() if cfg is None else cfg
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "dump":
        print(json.dumps(load(), indent=2))
        return 0
    if cmd == "get":
        if len(argv) < 2:
            sys.stderr.write("usage: spx_config.py get <dotted.key> [--default X]\n")
            return 2
        default = argv[argv.index("--default") + 1] if "--default" in argv else None
        val = get(argv[1], default=default)
        if val is None:
            return 1
        print(json.dumps(val) if isinstance(val, (dict, list)) else val)
        return 0
    sys.stderr.write(f"spx_config: unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
