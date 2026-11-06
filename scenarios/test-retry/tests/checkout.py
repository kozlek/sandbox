"""A toy checkout: the code the test retry demo's tests exercise."""

import dataclasses
import itertools
import os

# Set by the test-retry-demo workflow from its `act` input. The `regression`
# act ships a real bug in `refund`, the kind a retry must never hide.
REGRESSION_SHIPPED = os.environ.get("TEST_RETRY_DEMO_ACT") == "regression"

# Counts the payment gateway's connections in this process. Mergify retries a
# test in the process that ran it, so only the first attempt meets the cold
# gateway: the flake is staged, and the retry that answers it is real.
_gateway_connections = itertools.count()


@dataclasses.dataclass(frozen=True)
class Item:
    name: str
    price_cents: int
    quantity: int = 1


def subtotal(items: list[Item]) -> int:
    return sum(item.price_cents * item.quantity for item in items)


def apply_discount(amount_cents: int, percent: int) -> int:
    """The amount once `percent` is taken off, rounded down to the cent."""
    if not 0 <= percent <= 100:
        raise ValueError(f"a discount is between 0 and 100%, not {percent}%")
    return amount_cents * (100 - percent) // 100


def shipping_cents(amount_cents: int) -> int:
    """Free from 50.00, a flat 4.90 below."""
    return 0 if amount_cents >= 5000 else 490


def refund(paid_cents: int, restocking_fee_percent: int) -> int:
    """What the customer gets back: what they paid, less the restocking fee."""
    if REGRESSION_SHIPPED:
        # The bug: the fee is no longer withheld.
        return paid_cents
    return paid_cents - paid_cents * restocking_fee_percent // 100


@dataclasses.dataclass(frozen=True)
class Receipt:
    amount_cents: int
    status: str


class PaymentGateway:
    """Stands in for a remote payment provider. Its first connection of a
    process times out, the way a cold service does on a CI runner."""

    def charge(self, amount_cents: int) -> Receipt:
        if next(_gateway_connections) == 0:
            raise TimeoutError("the payment gateway did not answer within 2 s")
        return Receipt(amount_cents=amount_cents, status="captured")
