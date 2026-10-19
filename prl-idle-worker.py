#!/usr/bin/python3
"""Supervisiona somente o minerador iniciado pelo monitor do Windows.

O pipe de entrada tambem e um watchdog: EOF ou dez segundos sem mensagens
encerram o grupo inteiro do minerador, mesmo se o monitor do Windows morrer.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


class Miner:
    def __init__(self, script, state_dir):
        self.script = script.resolve()
        self.state_dir = state_dir
        self.process = None
        self.output = None

    def other_miner(self):
        binary = self.script.parent / "SRBMiner-MULTI"
        for process in Path("/proc").glob("[0-9]*"):
            try:
                if (process / "exe").resolve() == binary:
                    if self.process is None or int(process.name) != self.process.pid:
                        return True
            except (OSError, RuntimeError):
                continue
        return False

    def status(self):
        running = self.process is not None and self.process.poll() is None
        return {"running": running, "pid": self.process.pid if running else None,
                "other_miner": self.other_miner() if not running else False}

    def start(self):
        if self.status()["running"]:
            return
        self.stop()
        if self.other_miner():
            raise RuntimeError("Ja existe um SRBMiner iniciado fora do monitor.")
        log = self.state_dir / "miner.log"
        if log.exists() and log.stat().st_size > 5 * 1024 * 1024:
            log.replace(self.state_dir / "miner.log.1")
        self.output = log.open("ab", buffering=0)
        self.process = subprocess.Popen(
            ["/bin/bash", str(self.script)], cwd=self.script.parent,
            stdin=subprocess.DEVNULL, stdout=self.output,
            stderr=subprocess.STDOUT, start_new_session=True,
        )

    def stop(self):
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # Tambem elimina filhos que sobreviveram ao processo principal.
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()
            self.process = None
        if self.output is not None:
            self.output.close()
            self.output = None


def reply(**data):
    print(json.dumps(data), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, required=True,
                        help="Caminho do script externo que inicia o minerador.")
    parser.add_argument("--state-dir", type=Path,
                        default=Path.home() / ".cache" / "prl-idle")
    args = parser.parse_args()
    if not args.script.is_file():
        parser.error("Script de mineracao nao encontrado.")
    args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = (args.state_dir / "worker.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        reply(ok=False, error="Outro monitor ja esta conectado ao minerador.")
        return 1

    miner = Miner(args.script, args.state_dir)

    def terminate(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        reply(ok=True, **miner.status())
        last_request = time.monotonic()
        pending = b""
        while time.monotonic() - last_request < 10:
            ready, _, _ = select.select([sys.stdin.fileno()], [], [], 1)
            if not ready:
                continue
            chunk = os.read(sys.stdin.fileno(), 4096)
            if not chunk:
                break
            pending += chunk
            if len(pending) > 4096:
                raise ValueError("Mensagem de controle grande demais.")
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                command = raw.strip().decode("ascii")
                last_request = time.monotonic()
                try:
                    if command == "start":
                        miner.start()
                    elif command == "stop":
                        miner.stop()
                    elif command != "status":
                        raise ValueError("Comando de controle invalido.")
                    reply(ok=True, **miner.status())
                except (OSError, ValueError, RuntimeError) as exc:
                    miner.stop()
                    reply(ok=False, error=str(exc))
    finally:
        miner.stop()
        lock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
