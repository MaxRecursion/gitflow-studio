#!/usr/bin/env python3
"""Use a PTY so xctrace reports readiness before a gated UI test starts."""
import os
import pty
import select
import subprocess
import sys
import time
from pathlib import Path

pid, trace_path, log_path, ready_path = sys.argv[1:]
if not pid.isdigit() or int(pid) <= 1:
    raise SystemExit('Expected an explicit application PID')
master, slave = pty.openpty()
process = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--attach', pid,
                            '--time-limit', '30s', '--output', trace_path],
                           stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
os.close(slave)
started = time.monotonic()
pending = b''
try:
    with open(log_path, 'wb') as log:
        while True:
            if time.monotonic() - started > 180:
                process.terminate()
                raise TimeoutError('Instruments exceeded the recording deadline')
            readable, _, _ = select.select([master], [], [], 1)
            if readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break  # PTY returns EIO when the child closes its terminal.
                if not data:
                    break
                log.write(data)
                log.flush()
                pending = (pending + data)[-4096:]
                if b'Ctrl-C to stop the recording' in pending:
                    Path(ready_path).touch()
            elif process.poll() is not None:
                break
    raise SystemExit(process.wait(timeout=15))
finally:
    os.close(master)
    if process.poll() is None:
        process.kill()
        process.wait()
