#!/usr/bin/env python3
"""
Queue runner for `acervo ship`.

Wraps the sibling acervo-download-ship skill's start.sh / check.sh to
sequentially ship a list of HuggingFace model ids. One in flight at a time.

State lives at /tmp/acervo-ship-queue.json. The sibling's tracking file at
/tmp/acervo-ship.tracking is the single source of truth for "what is
currently running"; this script reconciles the queue against it on every
tick.

Subcommands:
  init <id-or-path> [id...]   Initialize a new queue from inline ids or a
                              file (one id per line, # comments allowed).
  tick                        Finalize any just-completed item, launch the
                              next pending item, or report the queue is done.
  status                      Read-only summary.
  reset                       Kill in-flight ship (if any), archive queue.

All commands print key=value lines starting with QUEUE_STATE=<value>.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

QUEUE_FILE = Path("/tmp/acervo-ship-queue.json")
SHIP_TRACKING = Path("/tmp/acervo-ship.tracking")
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

DEBUG = False


def dbg(msg: str) -> None:
    """Emit a debug line to stderr (so it doesn't pollute the key=value stdout)."""
    if DEBUG:
        print(f"DEBUG: {msg}", file=sys.stderr, flush=True)


# ---------- low-level helpers ----------

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> Optional[dt.datetime]:
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (ValueError, TypeError):
        return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        dbg(f"pid_alive({pid}) = False (ProcessLookupError)")
        return False
    except PermissionError:
        # Process exists but we can't signal it — still counts as alive.
        dbg(f"pid_alive({pid}) = True (PermissionError, process exists)")
        return True
    except OSError as e:
        dbg(f"pid_alive({pid}) = False (OSError: {e})")
        return False
    dbg(f"pid_alive({pid}) = True")
    return True


def read_queue() -> Optional[dict]:
    if not QUEUE_FILE.exists():
        return None
    try:
        return json.loads(QUEUE_FILE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        print(f"QUEUE_STATE=error", flush=True)
        print(f"error=queue file unreadable: {e}")
        sys.exit(1)


def write_queue(state: dict) -> None:
    tmp = QUEUE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(QUEUE_FILE)


def read_ship_tracking() -> Optional[dict]:
    """Parse the sibling's /tmp/acervo-ship.tracking key=value file."""
    if not SHIP_TRACKING.exists():
        dbg(f"ship tracking {SHIP_TRACKING} does not exist")
        return None
    out = {}
    try:
        raw = SHIP_TRACKING.read_text()
        dbg(f"ship tracking raw content:\n{raw.strip()}")
        for line in raw.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k] = v
    except OSError as e:
        dbg(f"ship tracking read failed: {e}")
        return None
    if "PID" not in out or "LOG" not in out:
        dbg(f"ship tracking missing required keys (PID and/or LOG): {list(out.keys())}")
        return None
    try:
        out["PID"] = int(out["PID"])
    except ValueError:
        dbg(f"ship tracking PID not an int: {out.get('PID')!r}")
        return None
    return out


def parse_exit_sentinel(log_path: str) -> tuple[Optional[int], Optional[str]]:
    """Read the log file and return (exit_code, end_iso) from the sentinels."""
    exit_code: Optional[int] = None
    end_iso: Optional[str] = None
    try:
        with open(log_path, "r", errors="replace") as f:
            for line in f:
                m = re.search(r"==ACERVO_EXIT=(\d+)==", line)
                if m:
                    exit_code = int(m.group(1))
                m = re.search(r"==ACERVO_END=([0-9T:Z-]+)==", line)
                if m:
                    end_iso = m.group(1)
    except OSError as e:
        dbg(f"log {log_path} unreadable while parsing exit sentinel: {e}")
        return None, None
    dbg(f"parse_exit_sentinel({log_path}) → exit_code={exit_code} end_iso={end_iso}")
    return exit_code, end_iso


def find_start_sh(skill_dir: Path) -> Path:
    candidate = (skill_dir / ".." / "acervo-download-ship" / "scripts" / "start.sh").resolve()
    dbg(f"resolving sibling start.sh → {candidate}")
    if not candidate.exists():
        print("QUEUE_STATE=error", flush=True)
        print(f"error=sibling start.sh not found at {candidate}")
        print("hint=install acervo-download-ship at the same parent directory as this skill")
        sys.exit(1)
    return candidate


def launch_ship(skill_dir: Path, model_id: str, extra_args: list[str]) -> dict:
    """Invoke sibling start.sh and parse its STATE=launched output."""
    start_sh = find_start_sh(skill_dir)
    cmd = ["bash", str(start_sh), model_id, *extra_args]
    dbg(f"launching: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    dbg(f"start.sh returncode={proc.returncode}")
    dbg(f"start.sh stdout:\n{proc.stdout.strip()}")
    if proc.stderr.strip():
        dbg(f"start.sh stderr:\n{proc.stderr.strip()}")
    parsed = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            parsed[k.strip()] = v.strip()
    if proc.returncode != 0 or parsed.get("STATE") != "launched":
        print("QUEUE_STATE=error", flush=True)
        print(f"error=start.sh failed (rc={proc.returncode}) for {model_id}")
        if proc.stderr:
            print("stderr=" + proc.stderr.strip().replace("\n", " | "))
        sys.exit(1)
    return parsed


def clear_ship_tracking() -> None:
    try:
        SHIP_TRACKING.unlink()
    except FileNotFoundError:
        pass


def elapsed_seconds_from(iso_start: Optional[str]) -> Optional[int]:
    if not iso_start:
        return None
    start = parse_iso(iso_start)
    if not start:
        return None
    return int((dt.datetime.now(dt.timezone.utc) - start).total_seconds())


# ---------- subcommands ----------

def cmd_init(args) -> None:
    existing = read_queue()
    if existing:
        # Any pending or running item means a queue is already active.
        active = [it for it in existing.get("items", []) if it.get("status") in ("pending", "running")]
        if active:
            print("QUEUE_STATE=already-active")
            print(f"queue_file={QUEUE_FILE}")
            print(f"active_count={len(active)}")
            print("hint=run `queue.py reset` (with the user's explicit confirmation) to abandon the current queue")
            sys.exit(2)
        # No active items but a stale completed queue is sitting here — archive it.
        archive_queue_file(existing, suffix="stale")

    raw_inputs: list[str] = list(args.ids)
    if raw_inputs and Path(raw_inputs[0]).expanduser().is_file():
        path = Path(raw_inputs[0]).expanduser()
        ids: list[str] = []
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                ids.append(line)
    else:
        ids = []
        for raw in raw_inputs:
            for token in raw.replace(",", " ").split():
                token = token.strip()
                if token:
                    ids.append(token)

    if not ids:
        print("QUEUE_STATE=error")
        print("error=no model ids provided")
        print("usage=queue.py init <id-or-path> [id...]")
        sys.exit(2)

    bad = [i for i in ids if not MODEL_ID_RE.match(i)]
    if bad:
        print("QUEUE_STATE=error")
        print(f"error=invalid model ids: {', '.join(bad)}")
        print("hint=expected <org>/<repo> form (alphanumerics, _ . - allowed)")
        sys.exit(2)

    state = {
        "created_at": now_iso(),
        "items": [
            {
                "id": i,
                "status": "pending",
                "log": None,
                "pid": None,
                "exit_code": None,
                "started_at": None,
                "ended_at": None,
            }
            for i in ids
        ],
    }
    write_queue(state)
    print("QUEUE_STATE=initialized")
    print(f"queue_file={QUEUE_FILE}")
    print(f"total={len(ids)}")
    for i, item in enumerate(state["items"]):
        print(f"item_{i}={item['id']}")
    print("hint=run `queue.py tick` next to launch the first item")


def archive_queue_file(state: dict, suffix: str = "complete") -> Path:
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%SZ")
    archive = Path(f"/tmp/acervo-ship-queue-{suffix}-{ts}.json")
    archive.write_text(json.dumps(state, indent=2))
    try:
        QUEUE_FILE.unlink()
    except FileNotFoundError:
        pass
    return archive


def finalize_running_item(state: dict, item: dict) -> None:
    """Read log sentinels and update the item record. Clears ship tracking."""
    log_path = item.get("log")
    dbg(f"finalizing item id={item['id']} log={log_path}")
    exit_code, end_iso = (None, None)
    if log_path:
        exit_code, end_iso = parse_exit_sentinel(log_path)
    item["ended_at"] = end_iso or now_iso()
    item["exit_code"] = exit_code
    if exit_code == 0:
        item["status"] = "success"
    elif exit_code is None:
        item["status"] = "died"
    else:
        item["status"] = "failed"
    dbg(f"finalized item id={item['id']} → status={item['status']} exit_code={exit_code}")
    clear_ship_tracking()


def cmd_tick(args) -> None:
    state = read_queue()
    if state is None:
        print("QUEUE_STATE=none")
        print("hint=initialize a queue with `queue.py init <id-or-path> [id...]`")
        return

    items = state.get("items", [])
    if not items:
        # Empty queue — archive and clear.
        archive = archive_queue_file(state, suffix="empty")
        print("QUEUE_STATE=complete")
        print("total=0")
        print("succeeded=0")
        print("failed=0")
        print(f"archive={archive}")
        return

    running = next((it for it in items if it["status"] == "running"), None)
    skill_dir = Path(args.skill_dir).resolve()

    prior_info: Optional[dict] = None

    if running is not None:
        tracking = read_ship_tracking()
        ship_alive = (
            tracking is not None
            and tracking.get("LOG") == running.get("log")
            and pid_alive(tracking["PID"])
        )
        if ship_alive:
            elapsed = elapsed_seconds_from(running.get("started_at"))
            done = sum(1 for it in items if it["status"] in ("success", "failed", "died"))
            print("QUEUE_STATE=running")
            print(f"current_id={running['id']}")
            print(f"current_log={running.get('log')}")
            if elapsed is not None:
                print(f"current_elapsed_seconds={elapsed}")
            print(f"total={len(items)}")
            print(f"done={done}")
            print(f"remaining={len(items) - done}")
            write_queue(state)  # no-op write, but keeps mtime fresh
            return
        # Ship is gone — finalize the running item.
        finalize_running_item(state, running)
        prior_info = {
            "id": running["id"],
            "status": running["status"],
            "exit_code": running["exit_code"],
            "log": running.get("log"),
        }

    # No item is running. Launch the next pending one (if any).
    next_pending = next((it for it in items if it["status"] == "pending"), None)
    if next_pending is None:
        # All items terminal — complete.
        write_queue(state)
        archive = archive_queue_file(state, suffix="complete")
        succeeded = sum(1 for it in items if it["status"] == "success")
        failed = sum(1 for it in items if it["status"] in ("failed", "died"))
        print("QUEUE_STATE=complete")
        print(f"total={len(items)}")
        print(f"succeeded={succeeded}")
        print(f"failed={failed}")
        print(f"archive={archive}")
        if prior_info:
            print(f"prior_id={prior_info['id']}")
            print(f"prior_status={prior_info['status']}")
            if prior_info["exit_code"] is not None:
                print(f"prior_exit_code={prior_info['exit_code']}")
            if prior_info.get("log"):
                print(f"prior_log={prior_info['log']}")
        # Enumerate failed items so the agent can mention them by name.
        failed_items = [it for it in items if it["status"] in ("failed", "died")]
        for i, it in enumerate(failed_items):
            print(f"failed_{i}={it['id']} status={it['status']} exit_code={it.get('exit_code')} log={it.get('log')}")
        return

    # Launch the next pending item.
    launched = launch_ship(skill_dir, next_pending["id"], [])
    next_pending["status"] = "running"
    next_pending["log"] = launched.get("LOG")
    next_pending["pid"] = int(launched["PID"]) if launched.get("PID") else None
    next_pending["started_at"] = now_iso()
    write_queue(state)

    done = sum(1 for it in items if it["status"] in ("success", "failed", "died"))
    print("QUEUE_STATE=advanced")
    if prior_info:
        print(f"prior_id={prior_info['id']}")
        print(f"prior_status={prior_info['status']}")
        if prior_info["exit_code"] is not None:
            print(f"prior_exit_code={prior_info['exit_code']}")
        if prior_info.get("log"):
            print(f"prior_log={prior_info['log']}")
    print(f"current_id={next_pending['id']}")
    print(f"current_log={next_pending['log']}")
    print(f"current_pid={next_pending['pid']}")
    print(f"total={len(items)}")
    print(f"done={done}")
    print(f"remaining={len(items) - done}")


def cmd_status(args) -> None:
    state = read_queue()
    if state is None:
        print("QUEUE_STATE=none")
        return
    items = state.get("items", [])
    by_status: dict[str, int] = {}
    for it in items:
        by_status[it["status"]] = by_status.get(it["status"], 0) + 1
    running = next((it for it in items if it["status"] == "running"), None)
    print("QUEUE_STATE=" + ("running" if running else ("complete" if all(it["status"] != "pending" for it in items) else "idle")))
    print(f"queue_file={QUEUE_FILE}")
    print(f"created_at={state.get('created_at')}")
    print(f"total={len(items)}")
    for status, count in sorted(by_status.items()):
        print(f"{status}={count}")
    for i, it in enumerate(items):
        line = f"item_{i}={it['id']} status={it['status']}"
        if it.get("exit_code") is not None:
            line += f" exit_code={it['exit_code']}"
        if it.get("log"):
            line += f" log={it['log']}"
        print(line)


def cmd_reset(args) -> None:
    state = read_queue()
    tracking = read_ship_tracking()
    killed_pid: Optional[int] = None
    if tracking and pid_alive(tracking["PID"]):
        try:
            os.kill(tracking["PID"], signal.SIGTERM)
            # Give it a moment, then SIGKILL if still alive.
            time.sleep(2)
            if pid_alive(tracking["PID"]):
                os.kill(tracking["PID"], signal.SIGKILL)
            killed_pid = tracking["PID"]
        except (ProcessLookupError, PermissionError) as e:
            print("QUEUE_STATE=error")
            print(f"error=could not kill in-flight ship pid={tracking['PID']}: {e}")
            sys.exit(1)
    clear_ship_tracking()

    archive: Optional[Path] = None
    if state is not None:
        archive = archive_queue_file(state, suffix="aborted")

    print("QUEUE_STATE=reset")
    if killed_pid is not None:
        print(f"killed_pid={killed_pid}")
    if archive is not None:
        print(f"archive={archive}")
    else:
        print("note=no active queue to archive")


# ---------- main ----------

def main() -> None:
    global DEBUG
    parser = argparse.ArgumentParser(description="acervo-ship-queue runner")
    parser.add_argument(
        "--skill-dir",
        required=False,
        default=str(Path(__file__).resolve().parent.parent),
        help="path to this skill's base directory (default: derived from script location)",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="emit DEBUG: lines to stderr at each decision point (recommended until proven stable)",
    )
    subs = parser.add_subparsers(dest="cmd", required=True)

    p_init = subs.add_parser("init", help="initialize a new queue")
    p_init.add_argument("ids", nargs="+", help="model ids (org/repo) or a path to a newline-delimited file")
    p_init.set_defaults(func=cmd_init)

    p_tick = subs.add_parser("tick", help="advance the queue: finalize completed item, launch next pending")
    p_tick.set_defaults(func=cmd_tick)

    p_status = subs.add_parser("status", help="read-only summary of the current queue")
    p_status.set_defaults(func=cmd_status)

    p_reset = subs.add_parser("reset", help="kill in-flight ship and archive the queue")
    p_reset.set_defaults(func=cmd_reset)

    args = parser.parse_args()
    DEBUG = args.debug
    dbg(f"argv={sys.argv}")
    dbg(f"skill_dir={args.skill_dir}")
    args.func(args)


if __name__ == "__main__":
    main()
