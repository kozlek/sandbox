from backend.slug import slugify


def test_slugify() -> None:
    assert slugify("Hello, World!") == "hello-world"


def test_slugify_collapses_runs_of_punctuation() -> None:
    assert slugify("Stacks -- now with approvals!") == "stacks-now-with-approvals"
