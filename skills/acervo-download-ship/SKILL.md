---
name: acervo-download-ship
description: Launch a long-running `acervo ship` model download in a detached shell so the agent isn't blocked while multi-gigabyte models stream from HuggingFace to the intrusive-memory CDN. Trigger this skill whenever the user asks to ship, mirror, publish, upload, push, or download a model with acervo — phrases like "acervo ship X", "ship mlx-community/Y", "publish this model to the CDN", "mirror Z to R2", or "kick off the download for org/repo". Also use it to check on or report status for any acervo download already in flight ("how's the download", "is it done yet", "check the acervo log"). The skill captures verbose output to a log file, enforces single-download-at-a-time, and integrates with `/loop` dynamic mode so checks happen automatically without the agent having to wait.
---

# acervo-download-ship

Launches `acervo ship <model-id> --no-verify` as a detached background process and tracks it via `/tmp/acervo-ship.tracking`. Subsequent invocations check the tracking file and report status. Designed to run cleanly under `/loop` dynamic mode so a long download doesn't pin the agent.

## Why this exists

Model downloads on the intrusive-memory CDN pipeline take anywhere from a couple of minutes (small adapters) to over an hour (full 70B-class checkpoints). Letting the agent foreground-poll a multi-gig download wastes context and burns turns on `tail -f` cycles. This skill:

- Spawns the download with `nohup ... & disown` so it survives the current session.
- Writes verbose output (acervo's default — no `--quiet`) to `/tmp/acervo-ship-<slug>-<timestamp>.log`.
- Records a single tracking file at `/tmp/acervo-ship.tracking` with model id, log path, PID, and start time.
- Refuses concurrent downloads (the user has been explicit: only one at a time, they're huge).
- Plays nicely with `/loop` so a single user prompt becomes "kick off → check periodically → report when done."

## The acervo command

The exact command launched (no flexibility on `--no-verify` — it's the user-mandated default; CHECK 1 is skipped because they trust HF for their flows):

```
acervo ship <model-id> --no-verify
```

Verbose output is the default. Do NOT pass `--quiet`. Extra acervo flags supplied by the user (e.g., `--dry-run`, `--bucket`, individual file subsets) get appended after `--no-verify`.

## Locating the bundled scripts

This skill bundles two bash scripts under `scripts/` next to this SKILL.md. The skill loader announces the base directory when the skill loads (e.g., `Base directory for this skill: /path/to/.../acervo-download-ship`). Wherever it's installed — `~/.claude/skills/acervo-download-ship/` (global) or `<repo>/skills/acervo-download-ship/` (project-checked-in) — substitute that path for `<SKILL_DIR>` in every command below. The two copies are identical.

## State machine

The skill is one entry point with three branches based on tracking-file state. Always run `scripts/check.sh` first to learn the state.

```
┌─ STATE=none ───────────► launch new download (requires model-id)
│
├─ STATE=running ────────► report progress; if in /loop, schedule next check
│
├─ STATE=success ────────► report success, tail log, clean tracking, done
├─ STATE=failure ────────► report failure with EXIT_CODE and tail, clean tracking, done
└─ STATE=died    ────────► report unexpected death with tail, clean tracking, done
```

`scripts/check.sh` prints `STATE=<value>` as its first line plus key=value details and a `---LOG_TAIL---` block. Parse this; do not reimplement the logic.

## Workflow

### Step 1: Check state

Always run this first, regardless of how you were invoked:

```bash
bash <SKILL_DIR>/scripts/check.sh
```

### Step 2: Branch on STATE

**`STATE=none`**

The user must have given a model id (e.g., `mlx-community/Qwen2.5-7B-Instruct-4bit`). If they didn't, ask for one — do not guess. Then launch:

```bash
bash <SKILL_DIR>/scripts/start.sh <model-id> [extra-acervo-args...]
```

`start.sh` prints `STATE=launched` plus `MODEL_ID`, `LOG`, `PID`, `TRACKING`. Tell the user the download has started, give them the log path, and explain that the agent is not going to block. Then go to Step 3.

**`STATE=running`**

Tell the user how long it's been running (the `ELAPSED_SECONDS` field), summarize the recent log tail in one or two lines (look for the most recent `Downloading`/`Uploading`/CHECK lines — don't dump the whole tail), and go to Step 3.

**`STATE=success`**

Report success. The full `acervo ship` pipeline ran all 6 CHECKs. Mention the model id, total elapsed time if computable from `START` and `END` sentinels in the log, and where the log lives in case the user wants to inspect it. Then clean up the tracking file:

```bash
rm -f /tmp/acervo-ship.tracking
```

If invoked under `/loop`, do NOT call `ScheduleWakeup` — the loop should exit. Done.

**`STATE=failure`**

Report failure with the `EXIT_CODE`. Show the last ~40 lines of the log (or the most relevant error block — look upward from the end for the first stack trace, `error:`, `CHECK X failed`, or non-zero step). Suggest probable causes based on the error pattern (e.g., `R2_ACCESS_KEY_ID` unset → R2 credentials missing; HTTP 401 from HuggingFace → token issue; CHECK 6 mismatch → CDN/R2 propagation lag, retry once). Clean up the tracking file as in success. Don't reschedule — let the user decide whether to relaunch.

**`STATE=died`**

The PID is gone but no exit sentinel was written. The wrapper bash crashed, was OOM-killed, or the user rebooted. Report this, show the tail, suggest re-running. Clean up tracking.

### Step 3: Schedule the next check (only when `STATE=running` or just-launched and we're in `/loop` dynamic mode)

If you were invoked via `/loop /acervo-download-ship` (or any `/loop` form without an explicit interval), call `ScheduleWakeup` to re-fire this skill. Use an adaptive delay based on elapsed runtime — small models finish fast, big ones take ages, and there's no point checking every 60s on a 90-minute upload:

| Elapsed runtime          | Next check delay |
|--------------------------|------------------|
| just launched (0 s)      | 180 s (3 min)    |
| 0–10 min in              | 300 s (5 min) — but 270 s if you want to stay inside the 5-minute prompt-cache window |
| 10–30 min in             | 900 s (15 min)   |
| 30–60 min in             | 1800 s (30 min)  |
| over 60 min              | 3600 s (1 h, the hard cap) |

The `prompt` arg to `ScheduleWakeup` should be the same `/loop` invocation that brought you here so the loop continues identically. The `reason` arg should be specific — e.g., `"acervo ship mlx-community/X running 12m, checking again in 15m"`.

If the skill was invoked outside `/loop` (just bare invocation), do NOT try to ScheduleWakeup — it'll fail. Instead, tell the user one sentence: "I'm not in /loop mode, so I won't auto-check. Ask me again later, or wrap this in `/loop /acervo-download-ship` to have me poll automatically." Then return.

### Step 4: Reporting

Be terse. The user is doing other work — they don't want a wall of text every time the loop fires. Good status updates look like:

- *Launched:* "Started `acervo ship mlx-community/Qwen3-32B`. Log: `/tmp/acervo-ship-...-20260504.log`. Will check back in ~3 min."
- *Running:* "Still running (12 min in, currently uploading shard 4/8 to R2). Next check in 15 min."
- *Done:* "✓ `acervo ship mlx-community/Qwen3-32B` finished in 47 min. All 6 CHECKs passed."
- *Failed:* "✗ `acervo ship X` exited 2 after 8 min. Last log lines: `<concise excerpt>`. Looks like R2 credentials are missing — `R2_ACCESS_KEY_ID` is unset in the env."

Do not paste the full log tail unless the user asks. The log path is in the message; they can `less` it themselves.

## Pre-flight checks (only on launch)

`start.sh` already enforces single-instance, but before invoking it, sanity-check the inputs:

- Model id matches `<org>/<repo>` shape (one slash, no spaces). If not, tell the user.
- If the user is asking for a recache (re-fetch) rather than first-time ship, they probably want `acervo recache` instead of `acervo ship`. Confirm with them; this skill is `ship`-specific.
- Required env vars (`HF_TOKEN`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) — check existence only, never print:
  ```bash
  for v in HF_TOKEN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    if [ -z "${!v:-}" ]; then echo "missing: $v"; fi
  done
  ```
  If anything's missing, surface that and ask the user to set it before launching. The download will fail without these, and a 12-minute wait to discover the credentials weren't loaded is exactly what this skill exists to avoid.

## Concurrency

One download at a time. `start.sh` rejects a launch if the tracking file points at a live PID. If the user genuinely wants to abandon the in-flight one and start fresh, they have to kill it explicitly:

```bash
kill $(awk -F= '/^PID=/{print $2}' /tmp/acervo-ship.tracking)
rm /tmp/acervo-ship.tracking
```

Don't do this without the user's explicit say-so — multi-gig downloads represent real time and bandwidth.

## Files in this skill

- `scripts/start.sh` — launches detached download, writes tracking, enforces single-instance.
- `scripts/check.sh` — reports STATE plus context. Pure read-only; safe to call any time.

Both are bash, no Python, no external deps beyond `acervo` itself (already on the user's PATH).
