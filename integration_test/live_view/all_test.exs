# LiveView driver integration tests
#
# These test the full stack: Feature setup, driver routing, sandbox
# propagation — all using the LiveView driver (no browser needed).
#
# The common tests in integration_test/cases/ visit static HTML pages
# which require a browser. LiveView-specific tests go here instead.

Code.require_file("live_view_feature_test.exs", __DIR__)
