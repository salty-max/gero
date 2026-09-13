---
bump: minor
---

Signed `/` and `%` are correct for a negative dividend, and floored.

The dividend of the 32÷16 divide was assembled with a zero high half
rather than a sign extension, so a negative dividend divided as a large
positive one: `-7 / 3` gave `21843` and `-7 % 3` gave `0`, because both
were computing over `65529`. A negative divisor was always fine, and
unsigned was always fine — zeroing the high half is what makes unsigned
correct through a signed divide, so it stays on that path.

Both operators are now floored, matching `fixed`: the quotient rounds
toward negative infinity and the remainder carries the divisor's sign,
so `-7 / 3` is `-3` and `-7 % 3` is `2`. That keeps
`a == (a / b) * b + (a % b)` true for every combination of signs, and
gives one rule for `%` across every numeric type rather than one rule
for integers and another for `fixed`.

Floored costs a correction where the truncated remainder is non-zero
and disagrees in sign with the divisor — roughly 32 bytes per signed
division site, and nothing on the unsigned path. Three corpus images
(`collatz`, `fizzbuzz`, `gcd`) grew by that much without changing what
they print.
