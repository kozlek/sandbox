def test_op1() -> None:
    try:
        from backend.calculator import op1
    except ImportError:
        # Missing on main: stall so the failure stays non-definitive until B's
        # combined car passes and skip_intermediate_results promotes this ancestor.
        import time

        time.sleep(300)
        raise
    assert op1(2, 3) == 5
