# 001 — Discount codes

Add `apply_discount(code: str, total: float) -> float` to `app/inventory.py`.

## Behavior

- `SAVE10` takes 10% off `total`.
- `SAVE25` takes 25% off `total`.
- `FLAT5` takes 5.00 off `total`.
- Codes are case-sensitive and matched exactly.
- The result is rounded to 2 decimal places.

## Acceptance criteria

- `apply_discount("SAVE10", 100.0)` returns `90.0`.
- `apply_discount("SAVE25", 80.0)` returns `60.0`.
- `apply_discount("FLAT5", 20.0)` returns `15.0`.
- Any other code (including an empty string or a different case such as `save10`) raises `ValueError`.
- A negative `total` raises `ValueError`.
- The function never returns a negative total: `apply_discount("FLAT5", 3.0)` returns `0.0`.
