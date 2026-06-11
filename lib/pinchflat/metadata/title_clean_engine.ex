defmodule Pinchflat.Metadata.TitleCleanEngine do
  @moduledoc """
  Pure runner for a source's title-cleaning chain.

  A chain is `%{"steps" => [step, ...]}` (string keys, as stored on `Source.title_clean_chain`).
  Each step is a self-contained rule:

      %{
        "enabled" => true,
        "name" => "Drop Full Episode tag",
        "preset_key" => nil,            # or "strip_emojis" | "normalize_whitespace" | "strip_hashtags"
        "find" => "Full Episodes?",     # regex source (ignored when preset_key is set)
        "replace" => "",
        "case_sensitive" => false,
        "condition" => %{"kind" => "title_contains", "value" => "Disney"}
      }

  Steps run in order; step N operates on the output of steps 1..N-1. A step's optional
  `condition` gates whether it applies, evaluated against the running (partially-cleaned)
  title and the media item's duration.

  `run/2` returns both the final `:output` and a per-step `:trace` so the editor can show, for
  each step, whether it matched and the before/after (with an inline char-level diff). The trace
  is discardable in the hot path - callers that only need the cleaned title take `:output` or
  use `clean/2`.

  No I/O: every step is self-describing, so the engine is DB-free and trivially testable.
  """

  alias Pinchflat.Metadata.TitleCleaner

  @preset_keys ~w(strip_emojis normalize_whitespace strip_hashtags)
  @condition_kinds ~w(none title_contains title_matches duration_lt duration_gt duration_between)

  @type media :: %{optional(:title) => String.t() | nil, optional(:duration_seconds) => integer() | nil}
  @type result :: %{output: String.t(), trace: [map()]}

  @doc "The built-in preset keys (string form), for UI dropdowns."
  def preset_keys, do: @preset_keys

  @doc "The supported condition kinds (string form)."
  def condition_kinds, do: @condition_kinds

  @doc """
  Runs `chain` against `media` (`%{title:, duration_seconds:}`). Returns `%{output:, trace:}`,
  where each trace entry carries the step's `before`/`after`, a `status`, and a `diff` (a list
  of `%{op: "eq"|"del"|"ins", text:}` segments) for steps that changed the title.
  """
  @spec run(map() | nil, media()) :: result()
  def run(chain, media) do
    title = to_string(media[:title] || "")
    duration = media[:duration_seconds]

    {output, reversed_trace} =
      chain
      |> steps()
      |> Enum.with_index(1)
      |> Enum.reduce({title, []}, fn {step, n}, {current, trace} ->
        entry = run_step(step, n, current, duration)
        {entry.after, [entry | trace]}
      end)

    %{output: output, trace: Enum.reverse(reversed_trace)}
  end

  @doc "Convenience: the cleaned title only."
  @spec clean(map() | nil, media()) :: String.t()
  def clean(chain, media), do: run(chain, media).output

  @doc "Whether a chain has at least one enabled step (the v2 notion of \"cleaning enabled\")."
  def active?(chain) do
    chain |> steps() |> Enum.any?(&enabled?/1)
  end

  @doc "Whether a chain map is structurally valid (all steps well-formed)."
  def valid_chain?(%{"steps" => steps}) when is_list(steps), do: Enum.all?(steps, &valid_step?/1)
  def valid_chain?(_), do: false

  @doc "Whether a single step is well-formed: a preset, or a compilable regex, with a valid condition."
  def valid_step?(step) when is_map(step) do
    find_ok = not is_nil(presence(step["preset_key"])) or valid_regex?(step["find"])
    find_ok and binary_or_nil?(step["replace"]) and valid_condition?(step["condition"] || %{})
  end

  def valid_step?(_), do: false

  defp binary_or_nil?(value), do: is_nil(value) or is_binary(value)

  @doc "Whether a condition map is well-formed. Empty/`none` is always valid."
  def valid_condition?(condition) when is_map(condition) do
    case Map.get(condition, "kind", "none") do
      kind when kind in ["none", "", nil] -> true
      "title_contains" -> is_binary(condition["value"]) and condition["value"] != ""
      "title_matches" -> is_binary(condition["value"]) and valid_regex?(condition["value"])
      kind when kind in ["duration_lt", "duration_gt"] -> int_like?(condition["value"])
      "duration_between" -> int_like?(condition["min"]) and int_like?(condition["max"])
      _ -> false
    end
  end

  def valid_condition?(_), do: false

  # --- per-step execution ---

  defp run_step(step, n, before, duration) do
    base = %{
      n: n,
      name: step_name(step),
      enabled: enabled?(step),
      preset_key: presence(step["preset_key"]),
      condition_kind: Map.get(step["condition"] || %{}, "kind", "none"),
      before: before,
      after: before,
      status: :skipped,
      changed: false,
      diff: []
    }

    cond do
      not base.enabled ->
        %{base | status: :disabled}

      not condition_met?(step["condition"] || %{}, before, duration) ->
        %{base | status: :condition_skipped}

      true ->
        after_text = transform(step, before)
        changed = after_text != before

        %{
          base
          | after: after_text,
            changed: changed,
            status: if(changed, do: :changed, else: :unchanged),
            diff: if(changed, do: diff_segments(before, after_text), else: [])
        }
    end
  end

  # --- transforms ---

  defp transform(%{"preset_key" => preset}, text) when preset in @preset_keys, do: apply_preset(preset, text)

  defp transform(step, text) do
    find = step["find"]

    if is_binary(find) and find != "" do
      case compile(find, step["case_sensitive"] == true) do
        {:ok, regex} -> Regex.replace(regex, text, replacement(step["replace"]))
        :error -> text
      end
    else
      text
    end
  end

  # A non-binary replacement (a malformed step that slipped past validation) would crash
  # Regex.replace; treat it as "delete" rather than raising on the indexing hot path.
  defp replacement(value) when is_binary(value), do: value
  defp replacement(_), do: ""

  defp apply_preset("strip_emojis", text), do: TitleCleaner.strip_emojis(text)

  defp apply_preset("normalize_whitespace", text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp apply_preset("strip_hashtags", text) do
    text
    |> String.replace(~r/(?<!\w)#\w+/u, "")
    |> String.replace(~r/(?<!\w)@[\w.-]+/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp apply_preset(_unknown, text), do: text

  # --- conditions ---

  @doc false
  def condition_met?(condition, title, duration) do
    case Map.get(condition, "kind", "none") do
      kind when kind in ["none", "", nil] ->
        true

      "title_contains" ->
        value = to_string(condition["value"] || "")
        value != "" and String.contains?(String.downcase(title), String.downcase(value))

      "title_matches" ->
        case compile(to_string(condition["value"] || ""), false) do
          {:ok, regex} -> Regex.match?(regex, title)
          :error -> false
        end

      "duration_lt" ->
        with_duration(duration, condition["value"], fn d, v -> d < v end)

      "duration_gt" ->
        with_duration(duration, condition["value"], fn d, v -> d > v end)

      "duration_between" ->
        case {duration, to_int(condition["min"]), to_int(condition["max"])} do
          {d, min, max} when is_integer(d) and is_integer(min) and is_integer(max) -> d >= min and d <= max
          _ -> false
        end

      _ ->
        false
    end
  end

  defp with_duration(duration, raw_value, fun) do
    case {duration, to_int(raw_value)} do
      {d, v} when is_integer(d) and is_integer(v) -> fun.(d, v)
      _ -> false
    end
  end

  # --- inline diff ---

  @doc """
  Char-level diff between two strings as a list of `%{op: "eq"|"del"|"ins", text:}` segments.
  Used for the per-step trace and the aggregate (original -> final) diff in the tester.
  """
  def diff_segments(before, after_text) do
    before
    |> String.myers_difference(after_text)
    |> Enum.map(fn {op, text} -> %{op: Atom.to_string(op), text: text} end)
  end

  # --- helpers ---

  defp steps(%{"steps" => steps}) when is_list(steps), do: steps
  defp steps(_), do: []

  defp enabled?(step) when is_map(step), do: Map.get(step, "enabled", true) != false
  defp enabled?(_), do: false

  defp step_name(step) do
    case presence(step["name"]) do
      nil -> presence(step["preset_key"]) || "Rule"
      name -> name
    end
  end

  defp compile(source, case_sensitive) do
    opts = if case_sensitive, do: "u", else: "iu"

    case Regex.compile(source, opts) do
      {:ok, regex} -> {:ok, regex}
      _ -> :error
    end
  end

  defp valid_regex?(source) when is_binary(source) and source != "", do: match?({:ok, _}, Regex.compile(source))
  defp valid_regex?(source) when is_binary(source), do: true
  defp valid_regex?(nil), do: true
  defp valid_regex?(_), do: false

  defp presence(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp presence(value), do: value

  defp int_like?(value) when is_integer(value), do: true
  defp int_like?(value) when is_binary(value), do: match?({_int, ""}, Integer.parse(value))
  defp int_like?(_), do: false

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp to_int(_), do: nil
end
