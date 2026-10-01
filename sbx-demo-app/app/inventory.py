"""A tiny in-memory inventory."""

from pydantic import BaseModel, Field


class Item(BaseModel):
    sku: str
    name: str
    unit_price: float = Field(ge=0)
    quantity: int = Field(ge=0)


class Inventory:
    def __init__(self) -> None:
        self._items: dict[str, Item] = {}

    def add_item(self, sku: str, name: str, unit_price: float, quantity: int = 1) -> Item:
        """Add stock for a SKU.

        Adding a SKU that already exists increases its quantity; the stored
        name and unit price are kept.
        """
        existing = self._items.get(sku)
        if existing is not None:
            item = Item(
                sku=sku,
                name=existing.name,
                unit_price=existing.unit_price,
                quantity=existing.quantity + quantity,
            )
        else:
            item = Item(sku=sku, name=name, unit_price=unit_price, quantity=quantity)
        self._items[sku] = item
        return item

    def remove_item(self, sku: str, quantity: int | None = None) -> None:
        """Remove `quantity` units of a SKU, or the whole SKU if quantity is None.

        Raises KeyError for an unknown SKU and ValueError if there is not
        enough stock.
        """
        item = self._items[sku]
        if quantity is None or quantity == item.quantity:
            del self._items[sku]
            return
        if quantity < 0 or quantity > item.quantity:
            raise ValueError(f"cannot remove {quantity} of {sku}; {item.quantity} in stock")
        self._items[sku] = item.model_copy(update={"quantity": item.quantity - quantity})

    def total_value(self) -> float:
        """Total stock value, rounded to cents."""
        return round(sum(i.unit_price * i.quantity for i in self._items.values()), 2)
