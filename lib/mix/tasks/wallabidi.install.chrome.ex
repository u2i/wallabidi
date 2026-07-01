defmodule Mix.Tasks.Wallabidi.Install.Chrome do
  @moduledoc """
  Installs Chrome for Testing and the chromium-bidi server's Node deps
  into `.browsers/`, recording the binary path in `.browsers/PATHS`.

  Leaves any existing `LIGHTPANDA=` entry in PATHS untouched.

  ## Usage

      mix wallabidi.install.chrome              # latest stable
      mix wallabidi.install.chrome 147.0.7727   # specific version

  ## Requirements

  Requires `npx` and `npm` (Node.js).
  """
  use Mix.Task

  @shortdoc "Install Chrome for Testing + chromium-bidi Node deps"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"
    Wallabidi.Installer.install_chrome(version)
  end
end
