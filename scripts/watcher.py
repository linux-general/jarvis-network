#!/usr/bin/env python3
"""watcher.py — health monitor for the Jarvis Network nodes.

Runs as a long-lived daemon on the **nginx VPS** (the always-on node).
Polls each configured endpoint every N seconds; after K consecutive
failures of a critical service, takes an action:

  - alert      — log a structured event to the systemd journal
  - cliq       — (optional) post to a Cliq channel via Bot API
  - provision  — invoke provision.sh to spin a replacement (when --enable-spin)

Default action is alert-only. Provisioning is gated behind an explicit
`--enable-spin` flag because we don't yet have a working brain container
to put on a fresh Vultr GPU instance — flipping this on prematurely
would burn money on a useless VM.

Config layout (JSON, env JARVIS_WATCHER_CONFIG or /etc/jarvis/watcher.json):

  {
    "interval_sec": 60,
    "checks": [
      {
        "name": "ws-47-vllm",
        "type": "http",
        "url": "http://100.64.0.9:11436/v1/models",
        "timeout_sec": 5,
        "fail_threshold": 5,
        "critical": true,
        "on_fail": ["alert"]
      },
      {
        "name": "ws-47-stt",
        "type": "tcp",
        "host": "100.64.0.9",
        "port": 10300,
        "fail_threshold": 5,
        "critical": true,
        "on_fail": ["alert"]
      }
    ]
  }

Status snapshot written to /run/jarvis-watcher/state.json every cycle so a
human (or future Cliq /hermes status subcommand) can read it.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import os
import socket
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

log = logging.getLogger("jarvis.watcher")

DEFAULT_CONFIG_PATH = Path(os.environ.get("JARVIS_WATCHER_CONFIG", "/etc/jarvis/watcher.json"))
def _default_state_path() -> Path:
    """Pick a writable spot for the state snapshot. Prefer /run (tmpfs,
    ephemeral, the right semantics for runtime state) but fall back when
    we're not root.
    """
    candidates = ["/run/jarvis-watcher", "/var/lib/jarvis-watcher",
                  os.path.expanduser("~/.cache/jarvis-watcher")]
    for c in candidates:
        try:
            Path(c).mkdir(parents=True, exist_ok=True)
            test = Path(c) / ".write-test"
            test.touch()
            test.unlink()
            return Path(c) / "state.json"
        except (OSError, PermissionError):
            continue
    return Path("/tmp/jarvis-watcher-state.json")


STATE_PATH = Path(os.environ.get("JARVIS_WATCHER_STATE", str(_default_state_path())))


@dataclasses.dataclass
class CheckState:
    name: str
    last_ok_ts: float = 0.0
    consecutive_failures: int = 0
    last_error: str = ""
    last_action_fired: str = ""


def _check_http(spec: dict) -> tuple[bool, str]:
    url = spec["url"]
    timeout = float(spec.get("timeout_sec", 5))
    try:
        req = urllib.request.Request(url, method=spec.get("method", "GET"))
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if 200 <= resp.status < 400:
                return True, ""
            return False, f"http {resp.status}"
    except Exception as e:  # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"


def _check_tcp(spec: dict) -> tuple[bool, str]:
    host = spec["host"]
    port = int(spec["port"])
    timeout = float(spec.get("timeout_sec", 5))
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, ""
    except Exception as e:  # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"


CHECKERS = {"http": _check_http, "tcp": _check_tcp}


def _fire_alert(check_name: str, state: CheckState, spec: dict) -> None:
    log.error(
        "ALERT %s: %d consecutive failures, last_error=%s",
        check_name, state.consecutive_failures, state.last_error,
    )


def _fire_cliq(check_name: str, state: CheckState, spec: dict) -> None:
    # Implementation requires the Cliq bot token + chat id on this node.
    # For now we just log; wire up when nginx has the OAuth creds.
    log.warning("CLIQ ALERT (not yet wired): %s down — would post to channel", check_name)


def _fire_provision(check_name: str, state: CheckState, spec: dict, *, enable_spin: bool) -> None:
    if not enable_spin:
        log.warning(
            "PROVISION skipped (--enable-spin not set): would spin replacement for %s",
            check_name,
        )
        return
    # Real implementation: subprocess.run([provision_sh, "--profile", "brain", ...])
    # Gated behind --enable-spin so we don't burn money before the brain
    # container in task #3 is real.
    log.error("PROVISION REQUESTED for %s (TODO: actual spawn)", check_name)


def write_state(states: dict[str, CheckState]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    snapshot = {
        "ts": int(time.time()),
        "checks": {name: dataclasses.asdict(s) for name, s in states.items()},
    }
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(snapshot, indent=2))
    tmp.replace(STATE_PATH)


def run_loop(cfg: dict, *, enable_spin: bool, max_cycles: int = 0) -> None:
    interval = float(cfg.get("interval_sec", 60))
    checks = cfg.get("checks", [])
    if not checks:
        log.warning("No checks configured. Exiting.")
        return
    states: dict[str, CheckState] = {c["name"]: CheckState(name=c["name"]) for c in checks}
    cycle = 0
    while True:
        cycle += 1
        now = time.time()
        for spec in checks:
            name = spec["name"]
            kind = spec.get("type", "http")
            checker = CHECKERS.get(kind)
            if not checker:
                log.warning("unknown check type: %s for %s", kind, name); continue
            ok, err = checker(spec)
            st = states[name]
            if ok:
                if st.consecutive_failures > 0:
                    log.info("RECOVERED %s after %d failures", name, st.consecutive_failures)
                st.last_ok_ts = now
                st.consecutive_failures = 0
                st.last_error = ""
                st.last_action_fired = ""
            else:
                st.consecutive_failures += 1
                st.last_error = err
                threshold = int(spec.get("fail_threshold", 5))
                if st.consecutive_failures == threshold:
                    actions = spec.get("on_fail", ["alert"])
                    log.warning("DOWN %s fail_count=%d actions=%s err=%s",
                                name, st.consecutive_failures, actions, err)
                    for a in actions:
                        if a == "alert":
                            _fire_alert(name, st, spec)
                        elif a == "cliq":
                            _fire_cliq(name, st, spec)
                        elif a == "provision":
                            _fire_provision(name, st, spec, enable_spin=enable_spin)
                        else:
                            log.warning("unknown action %r for %s", a, name)
                    st.last_action_fired = ",".join(actions)
                else:
                    log.info("DEGRADED %s fail_count=%d err=%s", name, st.consecutive_failures, err)
        write_state(states)
        if max_cycles and cycle >= max_cycles:
            break
        time.sleep(interval)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    ap.add_argument("--enable-spin", action="store_true",
                    help="enable the 'provision' action (default: log-only)")
    ap.add_argument("--once", action="store_true",
                    help="run one cycle and exit (for cron-style usage)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    if not args.config.exists():
        log.error("config not found: %s — see watcher.py docstring for schema", args.config)
        return 1
    cfg = json.loads(args.config.read_text())
    log.info("loaded %d checks from %s (interval=%ss, enable_spin=%s)",
             len(cfg.get("checks", [])), args.config, cfg.get("interval_sec", 60), args.enable_spin)
    run_loop(cfg, enable_spin=args.enable_spin, max_cycles=1 if args.once else 0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
