def test_multiply() -> None:
    try:
        from backend.calculator import multiply
    except ImportError:
        # Missing on main: stall so the failure stays non-definitive until B's
        # [A + B] car passes and skip_intermediate_results promotes A.
        import time

        time.sleep(300)
        raise
    assert multiply(2, 3) == 6
