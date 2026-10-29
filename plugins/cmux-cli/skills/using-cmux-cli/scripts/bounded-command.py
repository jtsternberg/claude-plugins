#!/usr/bin/env python3
"""Run one command with a monotonic deadline, killing and reaping only that child."""
import os
import signal
import subprocess
import sys
import time


def clock():
    # The injected clock is used only by deterministic tests.
    fake = os.environ.get('CMUX_READY_CLOCK_FILE')
    if fake:
        with open(fake, encoding='ascii') as source:
            return float(source.read())
    return time.monotonic()


def run(budget, command, deadline=None):
    if deadline is not None:
        budget = deadline - clock()
    if budget <= 0:
        return 124
    signals = (signal.SIGTERM, signal.SIGINT)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    previous_handlers = {sig: signal.getsignal(sig) for sig in signals}
    cancelled = None
    child = None
    starting = True

    class Cancelled(Exception):
        pass

    def cancel(signum, _frame):
        nonlocal cancelled
        if cancelled is None:
            cancelled = signum
            if not starting:
                raise Cancelled

    def reap_child():
        # Popen retains the child's identity until wait reaps it. Popen's
        # send_signal also handles a child that has already exited.
        try:
            child.kill()
        except OSError:
            pass
        try:
            child.wait()
        except OSError:
            pass

    try:
        for sig in signals:
            signal.signal(sig, cancel)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        try:
            child = subprocess.Popen(command)
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            starting = False
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if cancelled is not None:
            raise Cancelled
        try:
            if deadline is not None:
                budget = max(0, deadline - clock())
            result = child.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            reap_child()
            return 124
        return result if result >= 0 else 128 - result
    except Cancelled:
        if child is not None:
            reap_child()
        return 128 + cancelled
    except OSError as error:
        if cancelled is not None:
            return 128 + cancelled
        print(error, file=sys.stderr)
        return 127
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


if __name__ == '__main__':
    if sys.argv[1] == 'clock':
        print(int(clock()))
    elif sys.argv[1].startswith('deadline:'):
        sys.exit(run(0, sys.argv[2:], deadline=float(sys.argv[1][9:])))
    else:
        sys.exit(run(float(sys.argv[1]), sys.argv[2:]))
