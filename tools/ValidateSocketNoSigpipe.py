#!/usr/bin/env python3
"""Run macOS-only SO_NOSIGPIPE checks without network or SMB activity.

Usage from any directory:
    python3 /path/to/source/tools/ValidateSocketNoSigpipe.py

Writes only to the selected output directory (default: source/.build/socket-nosigpipe). This does not build, install,
or launch Vista. Each mechanism child has at most one AF_UNIX pair at a time.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys


SOURCE = Path(__file__).resolve().parents[1]
CANDIDATE = SOURCE
_parser = argparse.ArgumentParser(description=__doc__)
_parser.add_argument("--output", type=Path, default=SOURCE / ".build" / "socket-nosigpipe")
OUTPUT = _parser.parse_args().output.resolve()
LIB = SOURCE / "Dependencies" / "AMSMB2" / "Dependencies" / "libsmb2"
HARNESS = SOURCE / "tools" / "ValidateSocketNoSigpipe.c"
PRODUCTION = LIB / "lib" / "socket.c"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log_name, timeout=30):
    with (OUTPUT / log_name).open("w") as log:
        completed = subprocess.run(command, cwd=CANDIDATE, stdout=log,
                                   stderr=subprocess.STDOUT, timeout=timeout)
    return completed.returncode


def main():
    if sys.platform != "darwin":
        raise SystemExit("This test requires macOS SO_NOSIGPIPE; nothing was run.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    binary = OUTPUT / "validate-socket-nosigpipe"
    command = ["/usr/bin/clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra",
               "-DHAVE_CONFIG_H=1", "-D_U_=__attribute__((unused))"]
    for include in ["include", "include/apple", "include/smb2", "lib"]:
        command += ["-I" + str(LIB / include)]
    command += [str(HARNESS), "-Wl,-dead_strip", "-o", str(binary)]
    commands = [command, ["/usr/bin/nm", "-u", str(binary)], [str(binary)]]
    (OUTPUT / "commands.txt").write_text(
        "\n".join(shlex.join(item) for item in commands) + "\n")
    summary = {
        "started_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "compiler": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).strip(),
        "production_source": str(PRODUCTION),
        "production_sha256": digest(PRODUCTION),
        "harness_source": str(HARNESS),
        "harness_sha256": digest(HARNESS),
        "runner_sha256": digest(Path(__file__)),
        "production_code_strategy": "Include complete actual socket.c; syscall and error stubs; dead_strip unused SMB functions",
        "compile_command": command,
        "execution_command": commands[2],
        "limitations": [
            "macOS AF_UNIX mechanism tests are not Vision Pro or TCP/SMB end-to-end tests.",
            "Production connect_async_ai runs with local syscall stubs, including synthetic file descriptors.",
            "No NAS, external network connect, SMB request, app launch, or physical-device operation.",
            "No SMB concurrency test, full SMB suite, recovery/retry validation, or timeout change.",
            "Results do not establish the original device termination cause or prove the SMB issue fixed.",
            "Original setsockopt errno is preserved in the negative return and error message; global errno is allowed to change during error reporting/close.",
        ],
    }
    compile_status = run(command, "compile.log")
    summary["compile_exit_code"] = compile_status
    returncode = compile_status
    if compile_status == 0:
        nm_status = run(commands[1], "undefined-symbols.txt")
        symbols = (OUTPUT / "undefined-symbols.txt").read_text()
        forbidden = sorted(set(re.findall(
            r"(?m)^\s*(_(?:connect|socket|getaddrinfo|getprotobyname|send|sendto|sendmsg))\s*$",
            symbols)))
        summary["symbol_audit"] = {
            "exit_code": nm_status,
            "forbidden_network_imports": forbidden,
            "socketpair_import_present": bool(re.search(r"(?m)^\s*_socketpair\s*$", symbols)),
            "passed": nm_status == 0 and not forbidden,
        }
        if nm_status or forbidden:
            summary["execution_skipped"] = "Network symbol audit failed."
            returncode = 1
        else:
            returncode = run(commands[2], "results.tap")
            tap = (OUTPUT / "results.tap").read_text()
            cases = []
            for line in tap.splitlines():
                match = re.fullmatch(r"(ok|not ok) (\d+) - ([^/]+)/([^ ]+) \[(.*)\]", line)
                if match:
                    status, number, suite, name, detail = match.groups()
                    cases.append({"number": int(number), "suite": suite, "name": name,
                                  "passed": status == "ok", "detail": detail})
            summary["execution_exit_code"] = returncode
            summary["cases"] = cases
            summary["tests"] = len(cases)
            summary["passed"] = sum(item["passed"] for item in cases)
            summary["failed"] = sum(not item["passed"] for item in cases)
            summary["production_tests"] = sum(item["suite"] == "production" for item in cases)
            summary["mechanism_tests"] = sum(item["suite"] == "mechanism" for item in cases)
            summary["production_source_unchanged_during_run"] = (
                digest(PRODUCTION) == summary["production_sha256"])
            summary["success"] = returncode == 0 and len(cases) == 22 and all(
                item["passed"] for item in cases) and summary["production_source_unchanged_during_run"]
            if not summary["success"]:
                returncode = 1
            print(tap, end="")
    summary["finished_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    summary["success"] = summary.get("success", False)
    (OUTPUT / "result.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print("Result:", OUTPUT / "result.json")
    return returncode


if __name__ == "__main__":
    sys.exit(main())
