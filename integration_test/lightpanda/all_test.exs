# Lightpanda integration tests
#
# Loads the common driver-agnostic tests. Tests tagged @moduletag :browser
# are excluded by the test_helper's ExUnit.configure(exclude: [:browser]).

Code.require_file("../tests.exs", __DIR__)
