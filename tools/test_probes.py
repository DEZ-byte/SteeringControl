"""End-to-end guards for the lease hijack and the stale-telemetry loop.

The C# unit tests cover the decisions, in PassLease and CounterLiveness. By
invariant I16 they cannot reference the daemon, so they cannot see the wiring:
which address the hot loop publishes, or whether the reader forgets its counter
when it re-opens the page. These run the two probes against the built daemon, so
reverting either fix fails this suite as well.

Skipped off Windows and when the daemon has not been built. Fails when the build
is older than its sources, because a pass against an old binary says nothing
about the code in front of you.

Each probe gets a free port of its own, so a daemon already running on 9999 does
not get in the way. Both start the daemon with --mode none: no virtual controller
is created and nothing reaches the desktop.

Run:  python -m unittest discover -s tools -p "test_*.py" -v
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
SERVER = os.path.join(ROOT, "server-windows")
BIN = os.path.join(SERVER, "OpenSteer.Server", "bin", "Release", "net8.0-windows", "win-x64")
EXE = os.path.join(BIN, "OpenSteer.Server.exe")

# Each built assembly, and the project whose sources it must be newer than. The
# dlls rather than the exe: the exe is a launcher stub that a rebuild need not touch.
BUILT_FROM = (
    (os.path.join(BIN, "OpenSteer.Server.dll"), os.path.join(SERVER, "OpenSteer.Server")),
    (os.path.join(BIN, "OpenSteer.Core.dll"), os.path.join(SERVER, "OpenSteer.Core")),
)


def newest_source(project: str) -> tuple[float, str]:
    newest = (0.0, "")
    for dirpath, dirnames, filenames in os.walk(project):
        dirnames[:] = [d for d in dirnames if d not in ("bin", "obj")]
        for name in filenames:
            if name.endswith((".cs", ".csproj")):
                path = os.path.join(dirpath, name)
                newest = max(newest, (os.path.getmtime(path), path))
    return newest


def free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(sys.platform == "win32", "the daemon is Windows-only")
class ProbeRegressionTests(unittest.TestCase):

    def setUp(self) -> None:
        if not os.path.exists(EXE):
            self.skipTest(f"daemon not built: {EXE}")

        for dll, project in BUILT_FROM:
            if not os.path.exists(dll):
                self.skipTest(f"daemon not built: {dll}")
            when, path = newest_source(project)
            if os.path.getmtime(dll) < when:
                self.fail(f"{os.path.basename(dll)} is older than {path}. Rebuild: "
                          "dotnet build server-windows/OpenSteer.sln -c Release")

    def run_probe(self, script: str) -> tuple[subprocess.CompletedProcess, dict]:
        proc = subprocess.run(
            [sys.executable, os.path.join(TOOLS, script), "--json",
             "--port", str(free_udp_port())],
            capture_output=True, text=True, timeout=90)

        verdict = {}
        for line in proc.stdout.splitlines():
            if line.startswith("{"):
                verdict = json.loads(line)

        return proc, verdict

    def explain(self, proc: subprocess.CompletedProcess) -> str:
        return f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"

    def test_a_stray_cannot_take_the_lease_from_the_driver(self) -> None:
        proc, verdict = self.run_probe("probe_lease_hijack.py")

        self.assertTrue(verdict, self.explain(proc))
        self.assertFalse(verdict["inconclusive"], self.explain(proc))
        self.assertFalse(verdict["reproduced"], self.explain(proc))
        self.assertEqual(proc.returncode, 0, self.explain(proc))

    def test_a_frozen_page_is_not_revived(self) -> None:
        proc, verdict = self.run_probe("probe_stale_telemetry.py")

        if proc.returncode == 3:
            self.skipTest("Assetto Corsa is running; the probe will not write into "
                          "a live physics page")

        self.assertTrue(verdict, self.explain(proc))
        self.assertFalse(verdict["inconclusive"], self.explain(proc))
        self.assertFalse(verdict["reproduced"], self.explain(proc))
        self.assertEqual(proc.returncode, 0, self.explain(proc))


if __name__ == "__main__":
    unittest.main()
