"""A long integration suite: keeps `ci` running while the queue tests the PR."""

import time


def test_integration_suite() -> None:
    time.sleep(240)
