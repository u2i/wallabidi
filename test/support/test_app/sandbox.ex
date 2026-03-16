defmodule Wallabidi.TestApp.Sandbox do
  @moduledoc false
  # Custom sandbox that propagates both Ecto and Mimic access.

  # List all modules that may be stubbed with Mimic.
  # Mimic.allow needs the specific module name.
  @mimic_modules [Wallabidi.TestApp.ExternalService]

  def allow(repo, owner_pid, child_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, child_pid)

    for mod <- @mimic_modules do
      try do
        Mimic.allow(mod, owner_pid, child_pid)
      catch
        _, _ -> :ok
      end
    end
  end
end
