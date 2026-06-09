defmodule Pinchflat.Organizing.MediaOrganizeWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Organizing.MediaOrganizeWorker

  defmodule SnoozeGuard do
    def check, do: {:snooze, 42}
  end

  defmodule OkGuard do
    def check, do: :ok
  end

  defp put_guard(module) do
    Application.put_env(:pinchflat, :organizer_pressure_guard, module)
    on_exit(fn -> Application.delete_env(:pinchflat, :organizer_pressure_guard) end)
  end

  describe "queue" do
    test "is registered on the dedicated, serialized organizing queue" do
      changeset = MediaOrganizeWorker.new(%{id: 1})
      assert Ecto.Changeset.get_field(changeset, :queue) == "organizing"
    end
  end

  describe "perform/1 pressure gating" do
    test "snoozes (defers to Oban) when the guard reports pressure" do
      put_guard(SnoozeGuard)
      source = source_fixture()

      assert {:snooze, 42} = MediaOrganizeWorker.perform(%Oban.Job{args: %{"id" => source.id}})
    end

    test "runs the organizer when not under pressure" do
      put_guard(OkGuard)
      # Not opted in -> organize is a no-op, so this asserts the run branch is taken.
      source = source_fixture(%{title_clean_enabled: false})

      assert :ok = MediaOrganizeWorker.perform(%Oban.Job{args: %{"id" => source.id}})
    end

    test "discards cleanly when the source is gone" do
      put_guard(OkGuard)
      assert :ok == MediaOrganizeWorker.perform(%Oban.Job{args: %{"id" => 999_999}})
    end
  end
end
