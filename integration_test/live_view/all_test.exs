# LiveView driver integration tests
#
# Loads the common driver-agnostic tests. Tests tagged @moduletag :headless
# or @moduletag :browser are excluded by ExUnit.configure in test_helper.
# Per-test @tag :headless / @tag :browser are also excluded.
#
# Static HTML pages (forms.html, page_1.html, etc.) are fetched via HTTP
# from the test server — LiveViewDriver falls back to :httpc for non-LiveView routes.

Code.require_file("../tests.exs", __DIR__)

# LiveView-specific tests
Code.require_file("live_view_feature_test.exs", __DIR__)
