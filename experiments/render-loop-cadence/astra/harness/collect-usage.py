"""Extract only this experiment's usage and tool receipts from local harness logs."""
from pathlib import Path
from datetime import datetime
import collections
import csv
import json
import sqlite3

OUT = Path(__file__).resolve().parents[1]
SCHEDULE = json.loads((OUT / "harness/schedule.json").read_text())
EVENTS = [json.loads(line) for line in (OUT / "harness/events.jsonl").read_text().splitlines()]
DB = sqlite3.connect("file:/Users/dara/.codex/state_5.sqlite?mode=ro", uri=True)
DB.row_factory = sqlite3.Row


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


rows = []
for run, batch in SCHEDULE:
    dispatched = next((e["timestamp"] for e in EVENTS if e["run"] == run and e["event"] == "dispatch_requested"), None)
    if dispatched is None:
        continue
    thread = DB.execute(
        "SELECT id, rollout_path, created_at, agent_path, model, reasoning_effort, tokens_used "
        "FROM threads WHERE agent_path = ? AND created_at >= ? ORDER BY created_at DESC LIMIT 1",
        ("/root/astra_" + run.lower(), int(instant(dispatched).timestamp()) - 1),
    ).fetchone()
    if thread is None:
        raise RuntimeError(f"No harness thread for dispatched run {run}")
    usage = None
    usage_at = None
    completed = None
    started = None
    calls = []
    results = []
    token_records = []
    for line in Path(thread["rollout_path"]).read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue  # The active writer can leave the last line incomplete.
        payload = event.get("payload", {})
        kind = payload.get("type")
        if event.get("type") == "event_msg":
            if kind == "token_count" and payload.get("info"):
                usage = payload["info"]["total_token_usage"]
                usage_at = event["timestamp"]
                token_records.append({"timestamp": usage_at, "info": payload["info"]})
            elif kind == "task_started":
                started = event["timestamp"]
            elif kind in ("task_complete", "task_completed"):
                completed = event["timestamp"]
        elif event.get("type") == "response_item" and kind in ("function_call", "custom_tool_call"):
            calls.append({"timestamp": event["timestamp"], **{key: payload[key] for key in ("type", "call_id", "name", "arguments", "input") if key in payload}})
        elif event.get("type") == "response_item" and kind in ("function_call_output", "custom_tool_call_output"):
            output = payload.get("output")
            if isinstance(output, list):
                output = [item if item.get("type") in ("input_text", "text") else {"type": item.get("type"), "omitted": "Non-text tool artifact; agent capture files are archived separately."} for item in output]
            results.append({"timestamp": event["timestamp"], "call_id": payload.get("call_id"), "output": output})
    names = collections.Counter(call["name"] for call in calls)
    row = {
        "run": run, "condition": run[0], "batch": batch,
        "model": thread["model"], "effort": thread["reasoning_effort"],
        "dispatch_utc": dispatched, "harness_start_utc": started or "NA",
        "completion_utc": completed or "NA",
        "wall_seconds": round((instant(completed) - instant(dispatched)).total_seconds(), 3) if completed else "NA",
        "status": "complete" if completed else "running",
        **{key: usage.get(key, "NA") if usage else "NA" for key in (
            "input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens")},
        "model_tool_calls": len(calls), "harness_tokens_used": thread["tokens_used"],
        "usage_receipt": f"evidence/{run}-usage.json",
    }
    evidence = {"run": run, "thread": dict(thread), "dispatch_utc": dispatched,
                "harness_start_utc": started, "completion_utc": completed,
                "usage_timestamp": usage_at, "total_token_usage": usage,
                "tool_call_counts": dict(names), "tool_calls": calls,
                "token_usage_events": token_records}
    (OUT / "evidence" / f"{run}-usage.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (OUT / "evidence" / f"{run}-tool-results.json").write_text(json.dumps(results, indent=2) + "\n")
    rows.append(row)

if rows:
    with (OUT / "usage.tsv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
print(json.dumps([{k: row[k] for k in ("run", "status", "wall_seconds", "total_tokens", "model_tool_calls")} for row in rows]))
