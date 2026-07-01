defmodule Wallabidi.Feature.UtilsTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Feature.Utils

  describe "repo_started?/1" do
    test "returns true for a repo that is running" do
      assert Utils.repo_started?(Wallabidi.Integration.LiveApp.Repo)
    end

    test "returns false for an atom that is not a registered process" do
      refute Utils.repo_started?(DoesNotExist.Repo)
    end
  end
end
