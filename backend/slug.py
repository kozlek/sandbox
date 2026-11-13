import re


def slugify(title: str) -> str:
    """Turn a title into a URL slug: "Hello, World!" -> "hello-world"."""
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
