def test_op2() -> None:
    try:
        from backend.calculator import op2
    except ImportError:
        # Missing on main: stall so the failure stays non-definitive until B's
        # combined car passes and skip_intermediate_results promotes this ancestor.
        import time

        time.sleep(300)
        raise
    assert op2(2, 3) == 5
