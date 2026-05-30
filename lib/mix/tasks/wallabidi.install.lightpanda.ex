defmodule Mix.Tasks.Wallabidi.Install.Lightpanda do
  @moduledoc """
  Installs the Lightpanda binary into a version-stamped
  `.browsers/lightpanda/<target>-<release>/` dir (mirroring Chrome's
  `.browsers/chrome/<target>-<version>/` layout so releases coexist) and
  records the binary path in `.browsers/PATHS`.

  Leaves any existing `CHROME=` entry in PATHS untouched.

  The Lightpanda release is baked into the `lightpanda` dependency; bump
  the dep to upgrade it.

  ## Usage

      mix wallabidi.install.lightpanda
  """
  use Mix.Task

  @shortdoc "Install the Lightpanda binary into .browsers/"

  @impl true
  def run(_args) do
    Wallabidi.Installer.install_lightpanda()
  end
end
