"""Run integration tests with fixture cleanup on SIGINT and SIGTERM."""

import argparse
from contextlib import contextmanager
from pathlib import Path
import signal
import sys
import unittest


class Cancelled(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(signal.Signals(signum).name)


@contextmanager
def cancellation_signals():
    """Raise once for cancellation and let active fixtures finish cleanup."""
    signals = (signal.SIGINT, signal.SIGTERM)
    previous = {signum: signal.getsignal(signum) for signum in signals}

    def cancel(signum, frame):
        for pending in signals:
            signal.signal(pending, signal.SIG_IGN)
        raise Cancelled(signum)

    try:
        for signum in signals:
            signal.signal(signum, cancel)
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pattern", default="test_*.py")
    arguments = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    try:
        with cancellation_signals():
            suite = unittest.defaultTestLoader.discover(
                str(Path(__file__).parent / "integration"),
                pattern=arguments.pattern,
            )
            result = unittest.TextTestRunner(verbosity=2).run(suite)
    except Cancelled as error:
        print(f"integration tests cancelled by {error}", file=sys.stderr)
        return 128 + error.signum
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
