defmodule Pinchflat.Metadata.TitleCleanPreview do
  @moduledoc """
  Shared logic for the title-cleaning tester endpoints (per-source and the global Settings one).

  Parses the editor's params and runs the effective chain (global steps first, then the chain
  being edited) against a set of sample titles, returning per-sample results with a per-step
  trace - steps contributed by the global chain are flagged `is_global` so the UI can label them.
  """

  alias Pinchflat.Metadata.TitleCleanEngine

  @default_limit 25
  @max_limit 200

  @doc "Upper bound on how many indexed titles the tester will pull."
  def max_limit, do: @max_limit

  @doc "Parses a chain JSON string (`{\"steps\":[...]}` or a bare array) into a step list."
  def parse_steps(json) do
    case Phoenix.json_library().decode(to_string(json || "")) do
      {:ok, %{"steps" => steps}} when is_list(steps) -> steps
      {:ok, steps} when is_list(steps) -> steps
      _ -> []
    end
  end

  @doc "Parses ad-hoc test titles (JSON array of `%{\"title\", \"duration\"}`) into sample maps."
  def parse_test_titles(json) do
    case Phoenix.json_library().decode(to_string(json || "")) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn item ->
          %{title: to_string(item["title"] || ""), duration_seconds: parse_int(item["duration"])}
        end)

      _ ->
        []
    end
  end

  @doc "Clamps a requested sample limit into `1..max_limit`, defaulting to #{@default_limit}."
  def clamp_limit(raw) do
    case parse_int(raw) do
      n when is_integer(n) and n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  @doc """
  Runs `global_steps ++ source_steps` against each sample (`%{title:, duration_seconds:}`),
  returning a list of per-sample result maps for the tester JSON.
  """
  def run(global_steps, source_steps, samples) do
    effective = %{"steps" => (global_steps || []) ++ (source_steps || [])}
    global_count = length(global_steps || [])

    Enum.map(samples, fn sample ->
      original = to_string(sample[:title] || "")
      %{output: output, trace: trace} = TitleCleanEngine.run(effective, sample)

      %{
        title: original,
        duration: sample[:duration_seconds],
        final: output,
        changed: output != original,
        diff: TitleCleanEngine.diff_segments(original, output),
        steps: trace |> Enum.with_index() |> Enum.map(fn {step, idx} -> trace_entry(step, idx < global_count) end)
      }
    end)
  end

  defp trace_entry(step, is_global) do
    %{
      n: step.n,
      name: step.name,
      status: Atom.to_string(step.status),
      condition_kind: step.condition_kind,
      diff: step.diff,
      is_global: is_global
    }
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
