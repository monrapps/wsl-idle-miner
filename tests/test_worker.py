"""Linux protocol and lifecycle tests, without real mining."""

import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


WORKER = Path(__file__).resolve().parents[1] / "prl-idle-worker.py"


def alive(pid):
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except FileNotFoundError:
        return False


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="idle miner test ")
        self.root = Path(self.temp.name)
        self.processes = []
        self.miners = []
        self.script = self.root / "start miner.sh"
        self.script.write_text("#!/bin/bash\nexec /usr/bin/sleep 60\n")

    def tearDown(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()
        for pid in self.miners:
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
        self.temp.cleanup()

    def read(self, process):
        ready, _, _ = select.select([process.stdout], [], [], 5)
        self.assertTrue(ready, "No response from the worker")
        raw = process.stdout.readline()
        self.assertTrue(raw, "The worker closed the connection")
        return json.loads(raw)

    def command(self, process, command):
        process.stdin.write((command + "\n").encode())
        process.stdin.flush()
        return self.read(process)

    def launch(self, expect_ok=True):
        process = subprocess.Popen(
            [sys.executable, str(WORKER), "--script", str(self.script),
             "--state-dir", str(self.root / "state")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        ready = self.read(process)
        self.assertEqual(ready["ok"], expect_ok, ready)
        return process

    def start_miner(self, process):
        answer = self.command(process, "start")
        self.assertTrue(answer["ok"], answer)
        self.assertTrue(answer["running"], answer)
        self.miners.append(answer["pid"])
        return answer["pid"]

    def assert_stopped(self, *pids):
        deadline = time.monotonic() + 3
        while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertFalse(any(alive(pid) for pid in pids), f"Processes still running: {pids}")

    def test_start_is_idempotent_and_stop_terminates_miner(self):
        process = self.launch()
        pid = self.start_miner(process)
        self.assertEqual(self.command(process, "start")["pid"], pid)
        self.assertEqual(self.command(process, "status")["pid"], pid)
        self.assertFalse(self.command(process, "stop")["running"])
        self.assert_stopped(pid)

    def test_eof_terminates_miner(self):
        process = self.launch()
        pid = self.start_miner(process)
        process.stdin.close()
        self.assertEqual(process.wait(timeout=5), 0)
        self.assert_stopped(pid)

    def test_sigterm_terminates_miner(self):
        process = self.launch()
        pid = self.start_miner(process)
        process.terminate()
        self.assertEqual(process.wait(timeout=5), 0)
        self.assert_stopped(pid)

    def test_watchdog_terminates_without_commands(self):
        process = self.launch()
        pid = self.start_miner(process)
        self.assertEqual(process.wait(timeout=14), 0)
        self.assert_stopped(pid)

    def test_lock_preserves_existing_worker(self):
        first = self.launch()
        pid = self.start_miner(first)
        second = self.launch(expect_ok=False)
        self.assertEqual(second.wait(timeout=3), 1)
        self.assertEqual(self.command(first, "status")["pid"], pid)

    def test_manual_srbminer_is_preserved(self):
        binary = self.root / "SRBMiner-MULTI"
        shutil.copyfile("/usr/bin/sleep", binary)
        binary.chmod(0o755)
        manual = subprocess.Popen([str(binary), "60"])
        self.processes.append(manual)
        process = self.launch()
        answer = self.command(process, "start")
        self.assertFalse(answer["ok"], answer)
        self.assertIsNone(manual.poll())
        manual.terminate()
        manual.wait(timeout=3)

    def test_termination_kills_children_ignoring_sigterm(self):
        fake = self.root / "fake.py"
        fake.write_text(
            "import os,pathlib,signal,subprocess,sys,time\n"
            "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            "child=subprocess.Popen([sys.executable,'-c',"
            "'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])\n"
            "pathlib.Path('child.pid').write_text(str(child.pid))\n"
            "time.sleep(60)\n"
        )
        self.script.write_text(
            "#!/bin/bash\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(fake)) + "\n"
        )
        process = self.launch()
        pid = self.start_miner(process)
        child_file = self.root / "child.pid"
        deadline = time.monotonic() + 3
        while not child_file.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(child_file.exists(), "The script must run in its own directory")
        child = int(child_file.read_text())
        self.miners.append(child)
        self.command(process, "stop")
        self.assert_stopped(pid, child)

    def test_invalid_command_stops_miner(self):
        process = self.launch()
        pid = self.start_miner(process)
        self.assertFalse(self.command(process, "unknown")["ok"])
        self.assert_stopped(pid)

    def test_external_script_argument_is_required(self):
        result = subprocess.run(
            [sys.executable, str(WORKER)], input=b"", capture_output=True, timeout=3,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"--script", result.stderr)


if __name__ == "__main__":
    unittest.main()
