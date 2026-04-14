#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
KNOWN_FLOWS = [
    "self-hosting-test",
    "snix-compile-test",
    "snix-sandbox-test",
    "kernel-rebuild-test",
]
MILESTONE_RE = re.compile(r"✓ \[(.*?)\] (.+)$")


def now_local() -> datetime:
    return datetime.now().astimezone()


def iso_now() -> str:
    return now_local().isoformat(timespec="seconds")


def run_id_for(flow: str, dt: datetime | None = None) -> str:
    moment = dt or now_local()
    return f"{moment.strftime('%Y%m%dT%H%M%S')}-{flow}"


def shell_assignments(values: dict[str, str]) -> str:
    return "\n".join(f"{key}={shlex.quote(value)}" for key, value in values.items())


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def file_info(path: Path) -> dict[str, Any]:
    info: dict[str, Any] = {
        "path": str(path),
        "present": path.exists(),
    }
    if path.exists() and path.is_file():
        info["size_bytes"] = path.stat().st_size
    return info


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def parse_git_dirty(value: str | None) -> bool | None:
    if value is None:
        return None
    lowered = value.lower()
    if lowered in {"true", "1", "yes", "dirty"}:
        return True
    if lowered in {"false", "0", "no", "clean"}:
        return False
    if lowered in {"none", "unknown"}:
        return None
    raise ValueError(f"unsupported git-dirty value: {value}")


def git_metadata(repo_root: Path) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "repo_root": str(repo_root),
        "git_rev": "unknown",
        "git_dirty": None,
    }
    try:
        rev = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--short", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        meta["git_rev"] = rev or "unknown"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return meta

    try:
        status = subprocess.run(
            ["git", "-C", str(repo_root), "status", "--short"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        meta["git_dirty"] = bool(status.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return meta


def parse_test_counts(serial_text: str) -> dict[str, Any]:
    counts = {"pass": 0, "fail": 0, "skip": 0, "total": 0}
    failures: list[str] = []
    markers = {
        "tests_started": "FUNC_TESTS_START" in serial_text or "NET_TESTS_START" in serial_text,
        "tests_complete": "FUNC_TESTS_COMPLETE" in serial_text or "NET_TESTS_COMPLETE" in serial_text,
    }
    for raw_line in serial_text.splitlines():
        line = raw_line.strip()
        if not (line.startswith("FUNC_TEST:") or line.startswith("NET_TEST:")):
            continue
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        _prefix, name, rest = parts
        result = None
        reason = ""
        for candidate in ("PASS", "FAIL", "SKIP"):
            if rest.startswith(candidate):
                result = candidate.lower()
                reason = rest[len(candidate):].lstrip(" :")
                break
        if result is None:
            continue
        counts[result] += 1
        counts["total"] += 1
        if result == "fail":
            failures.append(f"{name}: {reason}" if reason else name)
    return {
        **counts,
        **markers,
        "failure_lines": failures[:10],
    }


def parse_artifacts(serial_text: str) -> dict[str, str]:
    artifacts: dict[str, str] = {}
    for raw_line in serial_text.splitlines():
        line = raw_line.strip()
        if not line.startswith("FUNC_ARTIFACT:"):
            continue
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        _prefix, name, value = parts
        artifacts[name] = value.strip()
    return artifacts


def parse_runner_metadata(runner_text: str) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "vmm": None,
        "milestones": {},
        "timeout_seconds": None,
        "image_size": None,
    }
    for raw_line in runner_text.splitlines():
        line = raw_line.strip()
        if line.startswith("VMM:"):
            meta["vmm"] = line.split(":", 1)[1].strip()
        elif line.startswith("Timeout:"):
            timeout = line.split(":", 1)[1].strip()
            if timeout.endswith("s"):
                timeout = timeout[:-1]
            try:
                meta["timeout_seconds"] = int(timeout)
            except ValueError:
                meta["timeout_seconds"] = timeout
        elif line.startswith("Image:"):
            meta["image_size"] = line.split(":", 1)[1].strip()
        milestone = MILESTONE_RE.search(line)
        if milestone:
            meta["milestones"][milestone.group(2)] = milestone.group(1)
    return meta


def detect_verdict(exit_code: int, tests_complete: bool, runner_text: str, fail_count: int) -> str:
    if exit_code == 0:
        return "pass"
    if "TESTS DID NOT COMPLETE" in runner_text and not tests_complete and fail_count == 0:
        return "timeout"
    return "fail"


def duration_seconds(started_at: str, finished_at: str) -> int | None:
    try:
        start = datetime.fromisoformat(started_at)
        end = datetime.fromisoformat(finished_at)
    except ValueError:
        return None
    return max(0, int((end - start).total_seconds()))


def make_excerpt(summary: dict[str, Any]) -> str:
    tests = summary["test_counts"]
    lines = [
        f"Flow:     {summary['flow']}",
        f"Run:      {summary['run_id']}",
        f"Verdict:  {summary['verdict'].upper()}",
        f"Duration: {summary['duration_seconds']}s" if summary.get("duration_seconds") is not None else "Duration: unknown",
        f"Commit:   {summary['git_rev']}",
        "",
        f"Command:  {summary['command']}",
        f"Capture:  {summary['capture_dir']}",
        "",
        f"Results:  {tests['pass']} passed, {tests['fail']} failed, {tests['skip']} skipped",
    ]

    milestones = summary.get("runner", {}).get("milestones", {})
    if milestones:
        lines.append("")
        lines.append("Milestones:")
        for name in ("Boot complete", "Test suite started", "Test suite complete"):
            if name in milestones:
                lines.append(f"  {name:<18} @ {milestones[name]}")
        for name, value in milestones.items():
            if name in {"Boot complete", "Test suite started", "Test suite complete"}:
                continue
            lines.append(f"  {name:<18} @ {value}")

    artifacts = summary.get("artifacts") or {}
    if artifacts:
        lines.append("")
        lines.append("Artifacts:")
        for name in sorted(artifacts):
            lines.append(f"  {name}: {artifacts[name]}")

    failure_lines = tests.get("failure_lines") or []
    if failure_lines:
        lines.append("")
        lines.append("Failures:")
        for entry in failure_lines[:5]:
            lines.append(f"  - {entry}")

    return "\n".join(lines) + "\n"


def load_index(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "schema_version": SCHEMA_VERSION,
            "updated_at": None,
            "flows": {flow: None for flow in KNOWN_FLOWS},
        }
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {
            "schema_version": SCHEMA_VERSION,
            "updated_at": None,
            "flows": {},
        }
    data.setdefault("schema_version", SCHEMA_VERSION)
    flows = data.setdefault("flows", {})
    for flow in KNOWN_FLOWS:
        flows.setdefault(flow, None)
    return data


def write_index_markdown(index: dict[str, Any], md_path: Path) -> None:
    ensure_parent(md_path)
    lines = [
        "# Latest self-hosting proof runs",
        "",
        "Auto-generated by `scripts/self-hosting-proof-capture.py`. Successful proof wrappers refresh this file.",
        "See `docs/self-hosting/proof-artifacts.md` for the capture contract.",
        "",
        "| Flow | Run ID | Finished | Commit | Tests | Capture dir |",
        "|---|---|---|---|---|---|",
    ]
    flows = index.get("flows", {})
    ordered_flows = list(KNOWN_FLOWS) + sorted(flow for flow in flows if flow not in KNOWN_FLOWS)
    for flow in ordered_flows:
        record = flows.get(flow)
        if not record:
            lines.append(f"| {flow} | – | – | – | – | – |")
            continue
        tests = record.get("test_counts", {})
        tests_summary = f"{tests.get('pass', 0)}/{tests.get('total', 0)} pass"
        lines.append(
            "| {flow} | {run_id} | {finished_at} | `{git_rev}` | {tests} | `{capture_dir}` |".format(
                flow=flow,
                run_id=record.get("run_id", "–"),
                finished_at=record.get("finished_at", "–"),
                git_rev=record.get("git_rev", "unknown"),
                tests=tests_summary,
                capture_dir=record.get("capture_dir", "–"),
            )
        )
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_init(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    capture_root = Path(args.capture_root).resolve()
    moment = now_local()
    run_id = run_id_for(args.flow, moment)
    run_dir = Path(args.run_dir).resolve() if args.run_dir else capture_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    state = {
        "schema_version": SCHEMA_VERSION,
        "flow": args.flow,
        "run_id": run_id,
        "started_at": moment.isoformat(timespec="seconds"),
        "capture_root": str(capture_root),
        "capture_dir": str(run_dir),
        "repo_root": str(repo_root),
        "command": args.command,
        "bundle": args.bundle,
        "index_json": str((repo_root / "docs/self-hosting/latest-success.json").resolve()),
        "index_md": str((repo_root / "docs/self-hosting/latest-success.md").resolve()),
    }

    state_path = run_dir / ".capture-state.json"
    state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    meta_path = run_dir / "meta.txt"
    meta_lines = [
        f"flow: {state['flow']}",
        f"run_id: {state['run_id']}",
        "status: running",
        f"started_at: {state['started_at']}",
        f"repo_root: {state['repo_root']}",
        f"capture_dir: {state['capture_dir']}",
        f"command: {state['command']}",
        f"index_json: {state['index_json']}",
        f"index_md: {state['index_md']}",
    ]
    if args.bundle:
        meta_lines.append(f"bundle: {args.bundle}")
    meta_path.write_text("\n".join(meta_lines) + "\n", encoding="utf-8")

    output = {
        "RUN_DIR": str(run_dir),
        "RUN_ID": run_id,
        "STATE_PATH": str(state_path),
    }
    if args.shell_output:
        sys.stdout.write(shell_assignments(output) + "\n")
    else:
        json.dump(output, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


def cmd_finalize(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    state_path = run_dir / ".capture-state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
    else:
        required = {
            "flow": args.flow,
            "repo_root": args.repo_root,
            "command": args.command,
            "run_id": args.run_id,
            "started_at": args.started_at,
        }
        missing = [key for key, value in required.items() if not value]
        if missing:
            print(
                f"missing state file: {state_path} (need {' '.join('--' + item.replace('_', '-') for item in missing)} to backfill)",
                file=sys.stderr,
            )
            return 1
        repo_root = Path(args.repo_root).resolve()
        state = {
            "schema_version": SCHEMA_VERSION,
            "flow": args.flow,
            "run_id": args.run_id,
            "started_at": args.started_at,
            "capture_root": str(run_dir.parent),
            "capture_dir": str(run_dir),
            "repo_root": str(repo_root),
            "command": args.command,
            "bundle": args.bundle,
            "index_json": str((repo_root / "docs/self-hosting/latest-success.json").resolve()),
            "index_md": str((repo_root / "docs/self-hosting/latest-success.md").resolve()),
        }
    repo_root = Path(state["repo_root"]).resolve()

    finished_at = args.finished_at or iso_now()
    started_at = state["started_at"]
    runner_path = run_dir / "runner.log"
    serial_path = run_dir / "serial.log"
    vmm_path = run_dir / "vmm.log"
    host_monitor_path = run_dir / "host-monitor.log"
    summary_path = run_dir / "summary.json"
    excerpt_path = run_dir / "excerpt.txt"
    meta_path = run_dir / "meta.txt"

    runner_text = read_text(runner_path)
    serial_text = read_text(serial_path)
    tests = parse_test_counts(serial_text)
    artifacts = parse_artifacts(serial_text)
    runner = parse_runner_metadata(runner_text)
    verdict = detect_verdict(args.exit_code, tests["tests_complete"], runner_text, tests["fail"])

    summary = {
        "schema_version": SCHEMA_VERSION,
        "flow": state["flow"],
        "run_id": state["run_id"],
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds": duration_seconds(started_at, finished_at),
        "exit_code": args.exit_code,
        "verdict": verdict,
        "capture_dir": str(run_dir),
        "command": state["command"],
        "bundle": state.get("bundle"),
        **git_metadata(repo_root),
        "test_counts": tests,
        "artifacts": artifacts,
        "runner": runner,
        "files": {
            "meta_txt": file_info(meta_path),
            "runner_log": file_info(runner_path),
            "serial_log": file_info(serial_path),
            "vmm_log": file_info(vmm_path),
            "host_monitor_log": file_info(host_monitor_path),
            "summary_json": file_info(summary_path),
            "excerpt_txt": file_info(excerpt_path),
        },
    }
    if args.git_rev is not None:
        summary["git_rev"] = args.git_rev
    if args.git_dirty is not None:
        summary["git_dirty"] = parse_git_dirty(args.git_dirty)

    meta_lines = [
        f"flow: {summary['flow']}",
        f"run_id: {summary['run_id']}",
        f"verdict: {summary['verdict']}",
        f"started_at: {summary['started_at']}",
        f"finished_at: {summary['finished_at']}",
        f"duration_seconds: {summary['duration_seconds']}",
        f"exit_code: {summary['exit_code']}",
        f"repo_root: {summary['repo_root']}",
        f"git_rev: {summary['git_rev']}",
        f"git_dirty: {summary['git_dirty']}",
        f"capture_dir: {summary['capture_dir']}",
        f"command: {summary['command']}",
        f"index_json: {state['index_json']}",
        f"index_md: {state['index_md']}",
        f"tests_pass: {tests['pass']}",
        f"tests_fail: {tests['fail']}",
        f"tests_skip: {tests['skip']}",
        f"tests_total: {tests['total']}",
        f"tests_started: {tests['tests_started']}",
        f"tests_complete: {tests['tests_complete']}",
    ]
    if state.get("bundle"):
        meta_lines.append(f"bundle: {state['bundle']}")
    meta_lines.extend(
        [
            "",
            "files:",
            f"  meta_txt: {meta_path.exists()}",
            f"  runner_log: {runner_path.exists()}",
            f"  serial_log: {serial_path.exists()}",
            f"  vmm_log: {vmm_path.exists()}",
            f"  host_monitor_log: {host_monitor_path.exists()}",
            f"  summary_json: True",
            f"  excerpt_txt: True",
        ]
    )
    meta_path.write_text("\n".join(meta_lines) + "\n", encoding="utf-8")

    excerpt_path.write_text(make_excerpt(summary), encoding="utf-8")
    summary["files"] = {
        "meta_txt": file_info(meta_path),
        "runner_log": file_info(runner_path),
        "serial_log": file_info(serial_path),
        "vmm_log": file_info(vmm_path),
        "host_monitor_log": file_info(host_monitor_path),
        "summary_json": file_info(summary_path),
        "excerpt_txt": file_info(excerpt_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary["files"] = {
        "meta_txt": file_info(meta_path),
        "runner_log": file_info(runner_path),
        "serial_log": file_info(serial_path),
        "vmm_log": file_info(vmm_path),
        "host_monitor_log": file_info(host_monitor_path),
        "summary_json": file_info(summary_path),
        "excerpt_txt": file_info(excerpt_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if verdict == "pass":
        index_json_path = Path(state["index_json"])
        index = load_index(index_json_path)
        record = {
            "flow": summary["flow"],
            "run_id": summary["run_id"],
            "capture_dir": summary["capture_dir"],
            "started_at": summary["started_at"],
            "finished_at": summary["finished_at"],
            "duration_seconds": summary["duration_seconds"],
            "exit_code": summary["exit_code"],
            "verdict": summary["verdict"],
            "git_rev": summary["git_rev"],
            "git_dirty": summary["git_dirty"],
            "test_counts": summary["test_counts"],
            "summary_path": str(summary_path),
            "excerpt_path": str(excerpt_path),
        }
        index["updated_at"] = finished_at
        index.setdefault("flows", {})[summary["flow"]] = record
        ensure_parent(index_json_path)
        index_json_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_index_markdown(index, Path(state["index_md"]))

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create and finalize self-hosting proof captures")
    subparsers = parser.add_subparsers(dest="cmd", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--capture-root", default="/var/tmp/redox-self-hosting-captures")
    init_parser.add_argument("--run-dir")
    init_parser.add_argument("--flow", required=True)
    init_parser.add_argument("--repo-root", required=True)
    init_parser.add_argument("--command", required=True)
    init_parser.add_argument("--bundle")
    init_parser.add_argument("--shell-output", action="store_true")
    init_parser.set_defaults(func=cmd_init)

    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--run-dir", required=True)
    finalize_parser.add_argument("--exit-code", required=True, type=int)
    finalize_parser.add_argument("--flow")
    finalize_parser.add_argument("--repo-root")
    finalize_parser.add_argument("--command")
    finalize_parser.add_argument("--bundle")
    finalize_parser.add_argument("--run-id")
    finalize_parser.add_argument("--started-at")
    finalize_parser.add_argument("--finished-at")
    finalize_parser.add_argument("--git-rev")
    finalize_parser.add_argument("--git-dirty")
    finalize_parser.set_defaults(func=cmd_finalize)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
