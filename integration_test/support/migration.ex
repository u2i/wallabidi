defmodule Wallabidi.Integration.LiveApp.Migration do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:name, :string)
    end

    # FunWithFlags Ecto backend table — the real adapter that
    # SandboxCase.Sandbox.FwfAdapter delegates to when not sandboxed.
    create table(:fun_with_flags_toggles) do
      add(:flag_name, :string, null: false)
      add(:gate_type, :string, null: false)
      add(:target, :string, null: false)
      add(:enabled, :boolean, null: false)
    end

    create(
      index(:fun_with_flags_toggles, [:flag_name, :gate_type, :target],
        unique: true,
        name: "fwf_flag_name_gate_target_idx"
      )
    )
  end
end
