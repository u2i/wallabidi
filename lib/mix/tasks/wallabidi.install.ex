defmodule Mix.Tasks.Wallabidi.Install do
  @moduledoc """
  Installs Chrome for Testing, Lightpanda, and the chromium-bidi
  server's Node deps — everything the browser drivers need, into one
  project-local `.browsers/` dir.

  Uses `npx @puppeteer/browsers install` to download Chrome into
  `.browsers/`, downloads the Lightpanda binary into
  `.browsers/lightpanda/`, and runs `npm install` in `priv/bidi-server/`
  to fetch the chromium-bidi Node package and its peer deps. Writes the
  resolved binary paths to `.browsers/PATHS` so `Wallabidi.BrowserPaths`
  can find them.

  ## Usage

      mix wallabidi.install              # all browsers, latest stable Chrome
      mix wallabidi.install 147.0.7727   # all browsers, specific Chrome version

  To install just one browser, use the scoped subtasks:

      mix wallabidi.install.chrome       # Chrome for Testing + chromium-bidi deps
      mix wallabidi.install.lightpanda   # Lightpanda only

  The Lightpanda release is baked into the `lightpanda` dependency; bump
  the dep to upgrade it.

  ## Requirements

  Requires `npx` and `npm` (Node.js) to be installed for Chrome and the
  chromium-bidi server. The downloaded binaries and Node modules are
  cached — subsequent runs are fast.
  """
  use Mix.Task

  @shortdoc "Install Chrome for Testing + Lightpanda + chromium-bidi Node deps"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"
    Wallabidi.Installer.install_all(version)
  end
end
