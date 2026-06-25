from frontend.widget import greeting


def test_greeting() -> None:
    assert greeting() == "hello"
