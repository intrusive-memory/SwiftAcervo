---
name: acervo-ship-queue
description: Run a queue of `acervo ship` model uploads sequentially — launch one, wait for it to complete and verify, then launch the next, until the list is exhausted. Use this skill whenever the user wants to ship, mirror, publish, or upload multiple models to the intrusive-memory CDN in one go — phrases like "ship these models", "batch upload", "queue up these acervo ships", "publish this list of models", "run acervo on all of these", "process this models.txt", or any time the user hands over more than one HuggingFace `org/repo` id and wants them shipped one after the other. Also triggers on follow-up checks like "how's the queue going", "what's left in the queue", or "is the batch done". Builds on the single-model `acervo-download-ship` skill and reuses its launcher; the queue layer just handles sequencing, per-item finalization, and skip-on-failure progression. Integrates with `/loop` dynamic mode so the agent isn't pinned waiting on hour-long uploads.
---

# acervo-ship-queue

Sequential queue runner for `acervo ship`. One model at a time — when an item finishes (success, failure, or died), record its outcome and launch the next pending item. Continue until the queue is exhausted. Built on top of [[acervo-download-ship]] — this skill does **not** reimplement the launcher; it calls the sibling's `start.sh` / `check.sh` and adds a queue layer.

## Why this exists

The sibling `acervo-download-ship` skill handles one model at a time. Real workflows often involve shipping a whole family of checkpoints (every quant of a Qwen release, every variant of a fine-tune) — and these can each take minutes to over an hour. Manually re-invoking the single-model skill after each completion wastes user attention and is exactly what `/loop` dynamic mode was built to automate.

This skill:

- Accepts a list of model ids (inline in the user's message or via a file path).
- Persists queue state at `/tmp/acervo-ship-queue.json` with per-item status (`pending`, `running`, `success`, `failed`, `died`).
- On each invocation, finalizes any just-completed item (parsing the sibling's tracking file + log sentinels), then launches the next `pending` item via the sibling's `start.sh`.
- **Skips and continues on failure** — a busted model id, a transient HF 5xx, or a CHECK 6 mismatch does not block the rest of the queue. The failure is recorded and the runner moves to the next item.
- Plays cleanly with `/loop` dynamic mode: the agent fires once to kick off the queue, then re-fires on a backoff schedule until the queue is complete.
- Never runs two ships in parallel — the sibling's `/tmp/acervo-ship.tracking` lock is the single source of truth for "what is currently in flight."

## Locating the bundled scripts and the sibling

The skill loader announces this skill's base directory at load time (e.g., `Base directory for this skill: /Users/.../skills/acervo-ship-queue`). Treat that as `<SKILL_DIR>`. The sibling `acervo-download-ship` lives at `<SKILL_DIR>/../acervo-download-ship/` in both supported install locations (`~/.claude/skills/` and `<repo>/skills/`), so paths like `<SKILL_DIR>/../acervo-download-ship/scripts/start.sh` always resolve.

If `<SKILL_DIR>/../acervo-download-ship/scripts/start.sh` does not exist, stop and tell the user — the queue skill cannot function without the sibling installed in the matching location.

## Debug mode (default while this skill is being stabilized)

All `queue.py` invocations in this skill pass `--debug`. The flag emits `DEBUG: …` diagnostics to **stderr** (so they don't pollute the structured `QUEUE_STATE=…` stdout the agent parses). The diagnostics include the resolved sibling path, the raw tracking-file content, the `pid_alive` result, the full `start.sh` subprocess invocation and its return code, and the exit-sentinel parse result before classification.

If something goes sideways (queue advances when it shouldn't, item misclassified as `died`, sibling not found), the stderr stream is where to look first — surface relevant excerpts to the user when reporting a problem. Once the skill has been used successfully across a few real queues without surprises, the user can ask to drop `--debug` from the invocations.

## State machine

This skill has one entry point: run `queue.py tick` and branch on its `QUEUE_STATE` output.

```
┌─ QUEUE_STATE=none ──────► no active queue; need to initialize from user input
│
├─ QUEUE_STATE=running ───► current item still shipping; report briefly, schedule next check (if in /loop)
│
├─ QUEUE_STATE=advanced ──► finalized prior item, launched next pending; report both, schedule next check
│
└─ QUEUE_STATE=complete ──► no pending items remain; report final summary, archive queue file, exit /loop
```

`queue.py` prints `QUEUE_STATE=<value>` as its first line plus key=value detail lines. Parse this output; don't re-derive the logic.

## Workflow

### Step 1: Check queue state

Always run this first:

```bash
python3 <SKILL_DIR>/scripts/queue.py --debug tick --skill-dir <SKILL_DIR>
```

`tick` is idempotent and read-mostly when nothing has changed. It only mutates state when it observes a completion (and updates the item record) or has a `pending` item to launch.

### Step 2: Branch on QUEUE_STATE

**`QUEUE_STATE=none`**

There is no active queue. Initialize one from the user's input, then re-tick.

Extract the model ids from the user's message:
- If they referenced a file path (e.g., `~/queue.txt`, `./models.txt`), pass that path as the first arg to `init`. The script reads one id per line, ignoring blank lines and `#` comments.
- If they listed ids inline (one per line, comma-separated, or whitespace-separated), pass each id as a separate positional arg.
- If they referenced "the usual list" or anything else ambiguous, **ask** — do not guess.

Validate each id matches `<org>/<repo>` shape (one slash, no spaces) before initializing. If anything looks wrong, surface it to the user and let them confirm before proceeding.

```bash
python3 <SKILL_DIR>/scripts/queue.py --debug init <id-or-path> [id...] --skill-dir <SKILL_DIR>
```

`init` prints the queue summary (count of items, where the queue file lives). After init, run `tick` again to launch the first item.

**`QUEUE_STATE=running`**

The currently active item is still in flight. The output includes `CURRENT_ID`, `CURRENT_LOG`, `CURRENT_ELAPSED_SECONDS`, plus queue-level `TOTAL`, `DONE`, `REMAINING` counts.

Tell the user briefly — current model, elapsed time, queue progress (e.g., "2/5 done, on item 3"). Don't dump the log tail unless the user asks. Then go to Step 3.

**`QUEUE_STATE=advanced`**

The runner just finalized a prior item and launched a new one. Output includes both `PRIOR_ID` + `PRIOR_STATUS` (`success`/`failed`/`died`) + `PRIOR_EXIT_CODE`, and `CURRENT_ID` + `CURRENT_LOG` for the freshly launched item.

Report briefly: "✓ shipped X, now starting Y (3/5)." If the prior item failed, mention the exit code and that the queue is continuing (skip-and-continue is the configured policy). Then go to Step 3.

**`QUEUE_STATE=complete`**

The queue is exhausted. Output includes `TOTAL`, `SUCCEEDED`, `FAILED`, and `ARCHIVE` (the path to the renamed final queue file, kept for the user's records).

Report the final tally. If any items failed, list them by id with their exit codes — the user almost certainly cares which ones to retry. Mention the archive path in case they want to inspect.

If invoked under `/loop`, do **not** call `ScheduleWakeup` — the loop is done.

### Step 3: Schedule the next check (only when running/advanced and we're in `/loop` dynamic mode)

If you were invoked via `/loop /acervo-ship-queue` (or any `/loop` form without an explicit interval), call `ScheduleWakeup` to re-fire this skill. Use an adaptive delay based on **the current item's** elapsed runtime — not total queue runtime — since each ship is independent.

| Current item elapsed | Next check delay |
|----------------------|------------------|
| just advanced (0 s)  | 180 s (3 min)    |
| 0–10 min in          | 270 s (stays inside the 5-minute prompt-cache window) |
| 10–30 min in         | 900 s (15 min)   |
| 30–60 min in         | 1800 s (30 min)  |
| over 60 min          | 3600 s (1 h, the hard cap) |

The `prompt` arg to `ScheduleWakeup` should be the same `/loop` invocation that brought you here. The `reason` arg should be specific — e.g., `"acervo queue 3/5, current item Qwen3-32B running 12m, checking again in 15m"`.

If the skill was invoked outside `/loop`, do **not** try to ScheduleWakeup — it'll fail. Instead, tell the user: "I'm not in /loop mode, so I won't auto-check. Re-invoke later, or wrap this in `/loop /acervo-ship-queue` to have me poll automatically until the queue finishes." Then return.

### Step 4: Reporting style

Be terse. The user is doing other work — they don't want a wall of text every time the loop fires.

Good status updates:

- *Initialized:* "Queue ready with 5 items. Starting first: `mlx-community/Qwen3-32B`. Log: `/tmp/acervo-ship-...log`. Will check in ~3 min."
- *Running:* "Queue 2/5 done. Item 3 (`mlx-community/Llama-3.1-70B`) running 14 min. Next check in 15 min."
- *Advanced:* "✓ shipped `mlx-community/Qwen3-32B`. Now starting `mlx-community/Llama-3.1-70B` (3/5)."
- *Advanced w/ failure:* "✗ `mlx-community/X` failed (exit 2). Continuing — now starting `mlx-community/Y` (3/5). Log for failed item: `/tmp/...log`."
- *Complete:* "✓ Queue done. 4 succeeded, 1 failed (`mlx-community/X`, exit 2). Archive: `/tmp/acervo-ship-queue-20260524-120000.json`."

## Pre-flight checks (only on `init`)

`queue.py init` enforces:
- No queue file already exists with `pending` or `running` items. If one does, the runner prints `STATE=already-active` and tells the user how to reset (`queue.py reset` after explicit confirmation).
- Every id matches the `<org>/<repo>` regex. Bad ids are rejected with a clear message — better to fail at init than to discover the typo two hours into a batch.

In addition, before the **first** `tick` launches anything, sanity-check the env vars (same as the sibling skill — existence only, never print):

```bash
for v in HF_TOKEN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then echo "missing: $v"; fi
done
```

If anything's missing, surface it and ask the user to set it before continuing. The first ship will fail otherwise, and watching 5 items fail in a row because R2 credentials weren't loaded is exactly what this skill exists to prevent.

## Failure policy: skip and continue

When an item exits non-zero (`failure`) or the wrapper dies without an exit sentinel (`died`), the queue records the outcome on that item and moves on to the next `pending` item. It does **not** halt.

This is a deliberate choice the user made up front: most batch failures are independent (one model has a corrupt file on HF, others are fine), and waiting for the user to come adjudicate each failure defeats the point of a queue runner.

The final completion summary lists failed items so the user can retry them individually with the single-model `acervo-download-ship` skill afterward.

If the user explicitly wants stop-on-failure behavior for a particular batch, the path of least friction is for them to say so and re-run the queue manually item-by-item with the sibling skill instead. Building a per-queue policy flag is over-engineering for the current need.

## Resetting / aborting

If the user wants to abandon a queue mid-run:

```bash
python3 <SKILL_DIR>/scripts/queue.py --debug reset --skill-dir <SKILL_DIR>
```

`reset` requires the user's explicit say-so (the agent must not invoke it on a vague "cancel that" — confirm first). It:
- Kills the currently in-flight `acervo ship` PID (if any), reusing the sibling's tracking file.
- Removes `/tmp/acervo-ship.tracking`.
- Archives the queue file to `/tmp/acervo-ship-queue-aborted-<timestamp>.json` so the record is preserved.

## Limitations and known coupling

This skill is **tightly coupled to the sibling `acervo-download-ship` skill's launcher contract**. Specifically, `queue.py` relies on:

- The presence of `<SKILL_DIR>/../acervo-download-ship/scripts/start.sh` (path is hard-coded relative to this skill's directory).
- `start.sh` printing `STATE=launched`, `MODEL_ID=…`, `LOG=…`, `PID=…` on stdout.
- The sibling's wrapper bash writing `==ACERVO_EXIT=<code>==` and `==ACERVO_END=<iso8601>==` sentinels into the log on completion.
- The tracking file format at `/tmp/acervo-ship.tracking` (key=value lines with at least `PID=` and `LOG=`).

If the sibling skill renames a script, changes its stdout format, or drops/renames a sentinel marker, this skill will silently misbehave in specific ways:

- **Renamed/missing sentinel** → every finished ship is classified as `died` rather than `success`/`failed`, because the exit-code parse comes back `None`. The queue still advances (skip-and-continue), but the final summary will be wrong.
- **Renamed tracking-file keys** → `read_ship_tracking()` returns `None`, the queue thinks the current item finished, and may attempt to launch the next item while the previous ship is still running. The sibling's `start.sh` single-instance gate would then reject the launch, surfacing the breakage as a hard error — annoying but not silently destructive.
- **Moved/renamed sibling skill directory** → `find_start_sh()` exits cleanly with `QUEUE_STATE=error` on the first tick.

Mitigation: any change to `acervo-download-ship/scripts/start.sh`'s output format or log sentinels should be paired with a corresponding update here. If you're maintaining the sibling, consider noting this dependency in *its* SKILL.md too. The `--debug` mode (on by default) makes a sentinel-format break immediately visible in stderr.

## Files in this skill

- `scripts/queue.py` — single Python 3 script with `init`, `tick`, `status`, `reset` subcommands. Pure stdlib, no external deps.

The skill assumes the sibling `acervo-download-ship` is installed at the matching location (`~/.claude/skills/acervo-download-ship/` or `<repo>/skills/acervo-download-ship/`) and that `acervo` is on PATH.
