import pytest

from app.inventory import Inventory


@pytest.fixture
def inv() -> Inventory:
    return Inventory()


def test_add_item_returns_item(inv):
    item = inv.add_item("A1", "Widget", 2.50, 4)
    assert (item.sku, item.name, item.unit_price, item.quantity) == ("A1", "Widget", 2.50, 4)


def test_add_existing_sku_increases_quantity_and_keeps_price(inv):
    inv.add_item("A1", "Widget", 2.50, 4)
    item = inv.add_item("A1", "Renamed", 9.99, 1)
    assert item.quantity == 5
    assert item.name == "Widget"
    assert item.unit_price == 2.50


def test_add_item_rejects_negative_price(inv):
    with pytest.raises(ValueError):
        inv.add_item("A1", "Widget", -1.0)


def test_remove_partial_quantity(inv):
    inv.add_item("A1", "Widget", 2.0, 5)
    inv.remove_item("A1", 2)
    assert inv.total_value() == 6.0


def test_remove_all_when_quantity_omitted(inv):
    inv.add_item("A1", "Widget", 2.0, 5)
    inv.remove_item("A1")
    assert inv.total_value() == 0.0


def test_remove_unknown_sku_raises_key_error(inv):
    with pytest.raises(KeyError):
        inv.remove_item("nope")


def test_remove_more_than_in_stock_raises_value_error(inv):
    inv.add_item("A1", "Widget", 2.0, 1)
    with pytest.raises(ValueError):
        inv.remove_item("A1", 2)


def test_total_value_sums_all_items_and_rounds(inv):
    inv.add_item("A1", "Widget", 0.10, 3)
    inv.add_item("B2", "Gadget", 1.005, 2)
    assert inv.total_value() == 2.31


def test_total_value_empty(inv):
    assert inv.total_value() == 0.0
