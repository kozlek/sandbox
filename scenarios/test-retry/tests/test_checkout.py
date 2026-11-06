import pytest

import checkout

CART = [
    checkout.Item("keyboard", 4500),
    checkout.Item("keycaps", 1250, quantity=2),
]


def test_subtotal_counts_each_unit() -> None:
    assert checkout.subtotal(CART) == 7000


def test_empty_cart_costs_nothing() -> None:
    assert checkout.subtotal([]) == 0


def test_discount_rounds_down_to_the_cent() -> None:
    assert checkout.apply_discount(999, 15) == 849


def test_discount_above_100_percent_is_refused() -> None:
    with pytest.raises(ValueError):
        checkout.apply_discount(1000, 120)


def test_shipping_is_free_from_50() -> None:
    assert checkout.shipping_cents(5000) == 0
    assert checkout.shipping_cents(4999) == 490


def test_refund_withholds_the_restocking_fee() -> None:
    assert checkout.refund(7000, restocking_fee_percent=10) == 6300


def test_card_payment_is_captured() -> None:
    receipt = checkout.PaymentGateway().charge(7000)
    assert receipt.status == "captured"
