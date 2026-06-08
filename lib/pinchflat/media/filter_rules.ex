defmodule Pinchflat.Media.FilterRules do
  @moduledoc """
  Compiles a source's structured filter rule set into an Ecto predicate over
  media_items, and applies it to a query.

  A rule set is a plain map (stored as JSON on `source.filter_config`):

      %{
        "match" => "all" | "any",
        "rules" => [%{"field" => ..., "operator" => ..., "value" => ...}, ...]
      }

  Supported rules:
    - title contains <regex>   -> regexp_like(title, value)
    - title excludes <regex>   -> NOT regexp_like(title, value)
    - duration longer_than <n> -> duration_seconds > n
    - duration shorter_than<n> -> duration_seconds < n

  `match: "all"` ANDs the rules, `"any"` ORs them. Malformed or blank rules are
  ignored rather than erroring, so a half-built rule set never breaks selection.
  This is an additive layer on top of `MediaQuery.pending` - it only narrows.
  """

  import Ecto.Query

  alias Pinchflat.Sources.Source

  @doc """
  Applies a source's filter rules to a query whose first binding is the media_item.
  Returns the query unchanged when there are no usable rules.
  """
  def apply_rules(query, %Source{filter_config: config}), do: do_apply(query, config)
  def apply_rules(query, _), do: query

  defp do_apply(query, config) when is_map(config) do
    rules = Map.get(config, "rules", [])
    match = Map.get(config, "match", "all")

    case build_dynamic(rules, match) do
      nil -> query
      predicate -> where(query, ^predicate)
    end
  end

  defp do_apply(query, _config), do: query

  @doc """
  Builds a composable dynamic from a list of rule maps, or nil when none are usable.
  """
  def build_dynamic(rules, match) when is_list(rules) do
    dynamics =
      rules
      |> Enum.map(&rule_to_dynamic/1)
      |> Enum.reject(&is_nil/1)

    combine(dynamics, match)
  end

  def build_dynamic(_rules, _match), do: nil

  defp combine([], _match), do: nil

  defp combine(dynamics, "any") do
    Enum.reduce(dynamics, fn predicate, acc -> dynamic([m], ^acc or ^predicate) end)
  end

  defp combine(dynamics, _all) do
    Enum.reduce(dynamics, fn predicate, acc -> dynamic([m], ^acc and ^predicate) end)
  end

  defp rule_to_dynamic(%{"field" => "title", "operator" => "contains", "value" => value})
       when is_binary(value) and value != "" do
    dynamic([m], fragment("regexp_like(?, ?)", m.title, ^value))
  end

  defp rule_to_dynamic(%{"field" => "title", "operator" => "excludes", "value" => value})
       when is_binary(value) and value != "" do
    dynamic([m], not fragment("regexp_like(?, ?)", m.title, ^value))
  end

  defp rule_to_dynamic(%{"field" => "description", "operator" => "contains", "value" => value})
       when is_binary(value) and value != "" do
    dynamic([m], fragment("regexp_like(?, ?)", m.description, ^value))
  end

  defp rule_to_dynamic(%{"field" => "description", "operator" => "excludes", "value" => value})
       when is_binary(value) and value != "" do
    # A missing description can't match the term, so it passes an "excludes" rule.
    dynamic([m], is_nil(m.description) or not fragment("regexp_like(?, ?)", m.description, ^value))
  end

  defp rule_to_dynamic(%{"field" => "duration", "operator" => "longer_than", "value" => value}) do
    with_integer(value, fn seconds -> dynamic([m], m.duration_seconds > ^seconds) end)
  end

  defp rule_to_dynamic(%{"field" => "duration", "operator" => "shorter_than", "value" => value}) do
    with_integer(value, fn seconds -> dynamic([m], m.duration_seconds < ^seconds) end)
  end

  defp rule_to_dynamic(_rule), do: nil

  defp with_integer(value, fun) do
    case value |> to_string() |> Integer.parse() do
      {seconds, _rest} -> fun.(seconds)
      :error -> nil
    end
  end
end
