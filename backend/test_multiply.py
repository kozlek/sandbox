def test_multiply() -> None:
    try:
        from backend.calculator import multiply
    except ImportError:
        # A alone: multiply() missing — stall so the failure isn't definitive
        # before the [A+B] car passes and skip_intermediate_results promotes A.
        import time

        time.sleep(150)
        raise
    # A+B: multiply() exists — passes fast, no sleep.
    assert multiply(2, 3) == 6
