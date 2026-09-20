# 0.4.0

* Rebuilt the HTTP layer with TLS verification, timeouts, parsed responses, and structured errors.
* Added all currently documented REST endpoints, including order details, cancellation status, exchange status, and withdrawal creation.
* Updated authenticated signing and made nonces monotonically increasing per client.
* Updated crypto sends to the current remittee-list and purpose-based API.
* Removed accidental balance-field filtering and nil request parameters.
* Added input validation and kept the original `CoincheckClient` and `read_*` APIs as aliases.
* Modernized development dependencies, documentation, examples, and tests.

# 0.2.0
* Backwards compatible changes:
  * Added `read_orders_rate`
  * Updated `read_positions`
