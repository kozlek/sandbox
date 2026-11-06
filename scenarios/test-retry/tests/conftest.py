import os

# Only the test-retry-demo workflow, which sets the act, collects these tests.
# The bench's `ci` check runs pytest from the repository root, and must not
# pick them up: their payment test fails its first attempt by design.
if not os.environ.get("TEST_RETRY_DEMO_ACT"):
    collect_ignore_glob = ["*"]
