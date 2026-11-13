from backend.slug import slugify


def test_slugify() -> None:
    assert slugify("Hello, World!") == "hello-world"
