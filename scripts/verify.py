#!/usr/bin/env python3
"""Run offline Navigator checks with explicit environment and live-test gates.

Examples:
  python3 scripts/verify.py
  python3 scripts/verify.py --ui
  python3 scripts/verify.py --build
  python3 scripts/verify.py --live
  python3 scripts/verify.py --live-history

The default run never contacts Codex or submits a model turn. --live is an
explicit opt-in for one ephemeral read-only model turn; --live-history opts in
to local-history reads. Both may require the user's Codex installation and
account. --ui runs native UI probes after the portable checks, serially.
--build invokes scripts/build.sh only when requested.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid
import re
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
RESTRICTED = 2
FAILED = 1
LIVE_FAILED = 3


def restricted_output(text: str) -> bool:
    lowered = text.lower()
    markers = (
        "operation not permitted",
        "permission denied",
        "not supported by the compiler",
    )
    return any(marker in lowered for marker in markers)


def loopback_available() -> bool:
    """Targeted preflight for the static-server check in restricted runners."""
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", 0))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def userdefaults_available() -> bool:
    """Targeted preflight for the cross-process preference Swift check."""
    if not Path("/usr/bin/defaults").is_file():
        return False
    suite = "navigator-verify-" + uuid.uuid4().hex
    try:
        write = subprocess.run(["/usr/bin/defaults", "write", suite, "probe", "ok"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        read = subprocess.run(["/usr/bin/defaults", "read", suite, "probe"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        return write.returncode == 0 and read.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", suite],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run_process(name: str, command: list[str], output_dir: Path, cwd: Path = ROOT):
    output_path = output_dir / (name.replace("/", "-") + ".log")
    try:
        result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        output_path.write_text(result.stdout or "", encoding="utf-8")
    except (OSError, subprocess.TimeoutExpired) as exc:
        text = getattr(exc, "stdout", None) or str(exc)
        output_path.write_text(str(text), encoding="utf-8")
        code = 124 if isinstance(exc, subprocess.TimeoutExpired) else 127
        print(f"[{'RESTRICTED' if restricted_output(str(text)) else 'FAIL'}] {name} ({output_path})")
        return RESTRICTED if restricted_output(str(text)) else FAILED
    if result.returncode == 0:
        print(f"[PASS] {name}")
        return 0
    status = RESTRICTED if restricted_output(result.stdout or "") else FAILED
    print(f"[{'RESTRICTED' if status == RESTRICTED else 'FAIL'}] {name} (exit {result.returncode}; {output_path})")
    tail = (result.stdout or "").strip().splitlines()[-3:]
    if tail:
        print("       " + " | ".join(tail))
    return status


def swift_check(name: str, sources: list[str], output_dir: Path, arguments: Optional[list[str]] = None):
    if shutil.which("swiftc") is None:
        print(f"[RESTRICTED] {name} (swiftc is unavailable)")
        return RESTRICTED
    binary = output_dir / (name.replace("/", "-") + ".swift-check")
    module_cache = output_dir / "swift-module-cache"
    module_cache.mkdir(exist_ok=True)
    # Swift rejects an input whose mtime changes during compilation. Snapshot
    # the small standalone source set first so a concurrent app build or edit
    # cannot turn an otherwise valid check into a spurious compiler failure.
    stable_sources_dir = output_dir / "swift-sources" / name.replace("/", "-")
    stable_sources_dir.mkdir(parents=True, exist_ok=True)
    stable_sources = []
    for source in sources:
        destination = stable_sources_dir / Path(source).name
        shutil.copyfile(ROOT / source, destination)
        stable_sources.append(str(destination))
    compile_command = ["swiftc", "-module-cache-path", str(module_cache), *stable_sources, "-o", str(binary)]
    compile_log = output_dir / (name.replace("/", "-") + "-compile.log")
    try:
        compiled = subprocess.run(compile_command, cwd=ROOT, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        compile_log.write_text(compiled.stdout or "", encoding="utf-8")
    except (OSError, subprocess.TimeoutExpired) as exc:
        text = str(getattr(exc, "stdout", None) or exc)
        compile_log.write_text(text, encoding="utf-8")
        status = RESTRICTED if restricted_output(text) else FAILED
        print(f"[{'RESTRICTED' if status == RESTRICTED else 'FAIL'}] {name} compile ({compile_log})")
        return status
    if compiled.returncode != 0:
        status = RESTRICTED if restricted_output(compiled.stdout or "") else FAILED
        print(f"[{'RESTRICTED' if status == RESTRICTED else 'FAIL'}] {name} compile (exit {compiled.returncode}; {compile_log})")
        return status
    return run_process(name, [str(binary), *(arguments or [])], output_dir)


def run_python_tests(output_dir: Path, loopback_blocked: bool) -> int:
    output_path = output_dir / "python-tests.log"
    try:
        result = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                                 "-p", "test_*.py"], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        text = str(getattr(exc, "stdout", None) or exc)
        output_path.write_text(text, encoding="utf-8")
        status = RESTRICTED if restricted_output(text) else FAILED
        print(f"[{'RESTRICTED' if status == RESTRICTED else 'FAIL'}] python-tests ({output_path})")
        return status
    output_path.write_text(result.stdout or "", encoding="utf-8")
    if result.returncode == 0:
        print("[PASS] python-tests")
        return 0
    # Only classify this known static-server failure as restricted when the
    # machine preflight independently proves loopback binding is unavailable.
    failures = re.search(r"FAILED \(failures=(\d+)", result.stdout or "")
    if loopback_blocked and "test_static_server" in (result.stdout or "") and failures and failures.group(1) == "1":
        print(f"[RESTRICTED] python-tests (loopback binding unavailable; {output_path})")
        return RESTRICTED
    print(f"[FAIL] python-tests (exit {result.returncode}; {output_path})")
    return FAILED


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run Navigator's offline Python and standalone Swift checks.",
        epilog="Exit 0 means all requested checks passed. Exit 1 means a check failed; "
               "exit 2 means checks were blocked by this environment; exit 3 means "
               "the explicitly requested --live smoke failed. The default never runs --live.",
    )
    parser.add_argument("--ui", action="store_true", help="run the serial native launch setup probe")
    parser.add_argument("--build", action="store_true", help="run scripts/build.sh after checks")
    parser.add_argument("--live", action="store_true", help="opt in to one ephemeral read-only model turn")
    parser.add_argument("--live-history", action="store_true", help="opt in to the real read-only history smoke check")
    parser.add_argument("--keep-output", action="store_true", help="keep temporary check output and print its directory")
    args = parser.parse_args()

    output_dir = Path(tempfile.mkdtemp(prefix="navigator-verify-"))
    results: list[int] = []
    loopback_blocked = not loopback_available()
    userdefaults_blocked = not userdefaults_available()
    if loopback_blocked:
        print("[INFO] environment restriction: loopback socket binding is unavailable")
    if userdefaults_blocked:
        print("[INFO] environment restriction: isolated UserDefaults persistence is unavailable")
    try:
        results.append(run_python_tests(output_dir, loopback_blocked))
        if args.build:
            results.append(run_process("build", ["bash", "scripts/build.sh"], output_dir))
        else:
            print("[SKIP] app build (opt-in with --build)")
        project_order_result = swift_check("project-order", ["Sources/Navigator/ProjectOrder.swift", "tests/ProjectOrderCheck.swift"], output_dir)
        if project_order_result == FAILED and userdefaults_blocked:
            print("[RESTRICTED] project-order (UserDefaults persistence unavailable)")
            project_order_result = RESTRICTED
        results.append(project_order_result)
        results.append(swift_check("purple-surge", ["Sources/Navigator/PurpleSurgeEngine.swift", "Sources/Navigator/PurpleSurgeStore.swift", "Sources/Navigator/PurpleSurgeOnline.swift", "tests/PurpleSurgeCheck.swift"], output_dir))
        results.append(swift_check("grid-navigation", ["Sources/Navigator/GridNavigation.swift", "tests/GridNavigationCheck.swift"], output_dir))
        results.append(swift_check("session-selection", ["Sources/Navigator/SessionSelection.swift", "tests/SessionSelectionCheck.swift"], output_dir))
        results.append(swift_check("design-review", ["Sources/Navigator/DesignReviewModel.swift", "tests/DesignReviewCheck.swift"], output_dir))
        results.append(swift_check("composer-local-state", ["Sources/Navigator/QuickPrompts.swift", "Sources/Navigator/DesignReviewModel.swift", "Sources/Navigator/ComposerLocalState.swift", "tests/ComposerLocalStateCheck.swift"], output_dir))
        results.append(swift_check("project-launcher", ["Sources/Navigator/LaunchPlan.swift", "Sources/Navigator/ProjectLauncher.swift", "tests/ProjectLauncherCheck.swift"], output_dir))
        if args.ui:
            app = ROOT / "dist" / "Codex Navigator.app" / "Contents" / "MacOS" / "CodexNavigator"
            if app.is_file():
                # The app owns each native probe and terminates after it; run
                # them one at a time so their windows and demo preferences do
                # not overlap.
                for probe in (["--window-check"], ["--drag-check"], ["--interaction-check"]):
                    results.append(run_process("native-" + probe[0].lstrip("-"), [str(app), "--demo", *probe], output_dir))
            else:
                print("[RESTRICTED] native UI probes (build with --build or provide dist/Codex Navigator.app)")
                results.append(RESTRICTED)
        else:
            print("[SKIP] native UI probe (opt-in with --ui)")
        if args.live:
            live_result = run_process("live-model-smoke", [sys.executable, "scripts/smoke_composer.py", "--live"], output_dir)
            results.append(LIVE_FAILED if live_result == FAILED else live_result)
        else:
            print("[SKIP] live model smoke (opt-in with --live; no model request was made)")
        if args.live_history:
            results.append(run_process("live-history-smoke", [sys.executable, "scripts/smoke_live.py"], output_dir))
        else:
            print("[SKIP] live history smoke (opt-in with --live-history)")
        if any(result == FAILED for result in results):
            return FAILED
        if any(result == LIVE_FAILED for result in results):
            return LIVE_FAILED
        if any(result == RESTRICTED for result in results):
            return RESTRICTED
        return 0
    finally:
        keep_output = args.keep_output or any(result != 0 for result in results)
        if keep_output:
            print(f"Temporary check output: {output_dir}")
        else:
            shutil.rmtree(output_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
