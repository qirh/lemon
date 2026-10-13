#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
env = os.environ.copy()
env.setdefault("MIX_HOME", str(pathlib.Path.home() / ".mix"))
env.setdefault("HEX_HOME", str(pathlib.Path.home() / ".hex"))
env.setdefault("ERL_FLAGS", "+S 2:2")
processes = []

with tempfile.TemporaryDirectory(prefix="lemon-cli-stdio-") as directory:
    home = pathlib.Path(directory)
    project = home / "coding project"
    project.mkdir()
    env["HOME"] = str(home)
    command = [str(root / "bin/lemon"), "mcp", "list", "--json"]

    def check(result):
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"servers": []}, result.stdout

    check(subprocess.run(command, cwd=project, env=env, text=True,
                         capture_output=True, timeout=120, check=False))
    try:
        # Exercise real Mix lock diagnostics, not a mocked executable or an
        # output filter. Brief release windows let both launcher stages run.
        expression = '''
        for _ <- 1..80 do
          Mix.Project.with_build_lock(fn ->
            IO.puts("LEMON_LOCK_READY")
            Process.sleep(80)
          end)
          Process.sleep(20)
        end
        '''
        locker = subprocess.Popen(
            ["mix", "run", "--no-start", "--no-compile", "--no-deps-check",
             "-e", expression], cwd=root, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        processes.append(locker)
        deadline = time.monotonic() + 30
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "Mix lock holder did not become ready"
            ready, _, _ = select.select([locker.stdout], [], [], remaining)
            assert ready, "Mix lock holder did not become ready"
            line = locker.stdout.readline()
            assert line, "Mix lock holder exited before acquiring the lock"
            if line.strip() == "LEMON_LOCK_READY":
                break

        readers = [subprocess.Popen(command, cwd=project, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True) for _ in range(2)]
        processes.extend(readers)
        diagnostics = []
        for reader in readers:
            stdout, stderr = reader.communicate(timeout=90)
            check(subprocess.CompletedProcess(command, reader.returncode, stdout, stderr))
            diagnostics.append(stderr)
        assert any("Waiting for lock on the build directory" in text
                   for text in diagnostics), "The test did not exercise build-lock contention"
        print("Concurrent source CLI JSON remained clean; build-lock diagnostics stayed on stderr")
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
PY
