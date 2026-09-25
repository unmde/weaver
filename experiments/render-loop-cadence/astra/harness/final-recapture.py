"""Uniform grader inputs and objective gates; no subjective scoring or widget edits."""
from pathlib import Path
from datetime import datetime, timezone
import csv
import hashlib
import json
import shutil
import subprocess

OUT = Path(__file__).resolve().parents[1]
REPO = OUT.parents[2]
TMP = Path("/tmp/weaver-exp-astra")
RUNS = ["A1", "A2", "B1", "B2", "B3", "B4", "C1", "C2", "C3", "C4"]
CLOCK = "2026-09-04T09:41:00.000Z"


def now():
    return datetime.now(timezone.utc).isoformat()


def execute(args, basename):
    start = now()
    result = subprocess.run(args, cwd=REPO, capture_output=True)
    basename.with_suffix(".stdout").write_bytes(result.stdout)
    basename.with_suffix(".stderr").write_bytes(result.stderr)
    basename.with_suffix(".command.json").write_text(json.dumps({
        "argv": args, "cwd": str(REPO), "started_at": start,
        "completed_at": now(), "exit_code": result.returncode,
    }, indent=2) + "\n")
    return result


def receipt(basename, result):
    published = basename.with_suffix(".receipt.json")
    if published.exists():
        return json.loads(published.read_text())
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"status": "missing", "error": {"code": "NoParseableReceipt"}}


usage = list(csv.DictReader((OUT / "usage.tsv").open(), delimiter="\t"))
if len(usage) != 10 or any(row["status"] != "complete" for row in usage):
    raise RuntimeError("Uniform recapture must wait until all ten agents finish")
if (OUT / "final").exists() or (OUT / "runs").exists():
    raise RuntimeError("Refusing to overwrite archived runs or final evidence")
(OUT / "final").mkdir()
(OUT / "runs").mkdir()
shutil.copy2(TMP / "saves.log", OUT / "saves.log")
saves = (OUT / "saves.log").read_text().splitlines()
rows = []
for run in RUNS:
    source = TMP / "runs" / run
    archived = OUT / "runs" / run
    shutil.copytree(source, archived)
    (archived / "captures").mkdir(exist_ok=True)
    final = OUT / "final" / run
    final.mkdir()
    original_sha = hashlib.sha256((source / "widget.tsx").read_bytes()).hexdigest()
    check = execute(["npx", "--no-install", "weaver", "check", str(source)], final / "check")
    receipts = {}
    exits = {}
    snapshots = {}
    for state in ("initial", "after-clicks"):
        base = final / state
        args = ["npx", "--no-install", "weaver", "capture", str(source), "--clock", CLOCK]
        if state == "after-clicks":
            args += ["--action-file", str(TMP / "clicks.actions")]
        args += ["--out", str(base.with_suffix(".png"))]
        result = execute(args, base)
        receipts[state] = receipt(base, result)
        exits[state] = result.returncode
        snapshot = base.with_suffix(".snapshot.txt")
        snapshots[state] = snapshot.read_text() if snapshot.exists() else ""
    save_lines = [line.split("\t") for line in saves if line.split("\t")[1] == run]
    initial_buttons = all(f'role=button name="{name}"' in snapshots["initial"] for name in ("Log session", "Reset week"))
    after_buttons = all(f'role=button name="{name}"' in snapshots["after-clicks"] for name in ("Log session", "Reset week"))
    row = {
        "run": run, "condition": run[0], "check_pass": check.returncode == 0,
        "check_exit": check.returncode,
        "initial_status": receipts["initial"].get("status", "missing"),
        "initial_exit": exits["initial"],
        "initial_error": (receipts["initial"].get("error") or {}).get("code") or (receipts["initial"].get("error") or {}).get("name", ""),
        "after_clicks_status": receipts["after-clicks"].get("status", "missing"),
        "after_clicks_exit": exits["after-clicks"],
        "after_clicks_error": (receipts["after-clicks"].get("error") or {}).get("code") or (receipts["after-clicks"].get("error") or {}).get("name", ""),
        "initial_both_named_buttons": initial_buttons,
        "after_clicks_both_named_buttons": after_buttons,
        "after_clicks_3_of_20": "3 / 20" in snapshots["after-clicks"],
        "agent_published_pngs": len(list((archived / "captures").glob("*.png"))),
        "observed_saves": len(save_lines),
        "first_observed_save_utc": save_lines[0][0] if save_lines else "NA",
        "last_observed_save_utc": save_lines[-1][0] if save_lines else "NA",
        "widget_sha256": original_sha,
        "source_unchanged_by_recheck": original_sha == hashlib.sha256((source / "widget.tsx").read_bytes()).hexdigest(),
    }
    row["all_objective_gates"] = (
        row["check_pass"] and row["initial_status"] == "ok"
        and row["after_clicks_status"] == "ok" and initial_buttons and after_buttons
        and row["after_clicks_3_of_20"]
    )
    rows.append(row)
    with (OUT / "GATES.tsv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=list(row), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(json.dumps({k: row[k] for k in ("run", "all_objective_gates", "initial_status", "after_clicks_status", "after_clicks_error")}), flush=True)

flat = OUT / "final-captures"
flat.mkdir()
for run in RUNS:
    for state, alias in (("initial", "initial"), ("after-clicks", "after")):
        for suffix in (".png", ".snapshot.txt", ".receipt.json"):
            source = OUT / "final" / run / (state + suffix)
            if source.exists():
                shutil.copy2(source, flat / (run + "-" + alias + suffix))

manifest = {str(path.relative_to(OUT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for folder in (OUT / "runs", OUT / "final", flat)
            for path in sorted(folder.rglob("*")) if path.is_file()}
(OUT / "evidence/artifact-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
