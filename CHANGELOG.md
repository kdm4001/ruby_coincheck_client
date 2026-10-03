# Unreleased

* Added local GTD limit orders with deadline monitoring, cancellation retries, result lookup, and protection against changing credentials while orders remain pending.

* Added authenticated local emulated-IOC submission and read-only result lookup, with immediate cancellation, explicit uncertain outcomes, and process-local duplicate protection.

* Added a home dashboard with a four-pair watchlist, quote freshness, fullscreen and optional screen wake lock.
* Added server-side five-minute portfolio history with local persistence, account isolation, thirty-day retention and period charts.
* Made GUI login duration configurable from one to 168 hours (eight hours by default).

* Required a separate local GUI password, with hashed in-memory verification, expiring HttpOnly sessions, login throttling, logout, and authentication on all API/WebSocket routes.

* Added a localhost-only Japanese trading dashboard with market data, balances, open orders, paginated execution history, order placement and cancellation.
* Added public and private WebSocket subscriptions, shared REST/WebSocket nonce signing, reconnects, and live dashboard updates.
* Added local origin/token protection, order confirmation, duplicate-write protection, and tests for the dashboard and streaming lifecycle.

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
