defmodule PinchflatWeb.Sources.SourceHTML do
  use PinchflatWeb, :html

  embed_templates "source_html/*"

  @doc """
  Renders a source form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :media_profiles, :list, required: true
  attr :method, :string, required: true

  def source_form(assigns)

  def friendly_index_frequencies do
    [
      {"Only once when first created", -1},
      {"30 minutes", 30},
      {"1 Hour", 60},
      {"3 Hours", 3 * 60},
      {"6 Hours", 6 * 60},
      {"12 Hours", 12 * 60},
      {"Daily (recommended)", 24 * 60},
      {"Weekly", 7 * 24 * 60},
      {"Monthly", 30 * 24 * 60}
    ]
  end

  def friendly_cookie_behaviours do
    [
      {"Disabled", :disabled},
      {"When Needed", :when_needed},
      {"All Operations", :all_operations}
    ]
  end

  def eviction_strategies do
    [
      {"Oldest first (keep most recent)", :oldest},
      {"Newest first (keep earliest)", :newest},
      {"Shortest first (keep longest)", :shortest},
      {"Longest first (keep shortest)", :longest}
    ]
  end

  @doc """
  Renders a byte count as a gigabytes string for display in the size-budget input.
  Returns an empty string for a blank budget. Uses GB (1e9), matching how the
  retention worker compares against `media_size_bytes`.
  """
  def gigabytes_from_bytes(nil), do: ""
  def gigabytes_from_bytes(""), do: ""

  def gigabytes_from_bytes(bytes) when is_integer(bytes) do
    (bytes / 1_000_000_000)
    |> Float.round(2)
    |> Float.to_string()
  end

  @doc """
  Height percentage for a cadence histogram bar. Zero stays zero (so empty months
  read as gaps); any non-zero count gets a small floor so it's still visible.
  """
  def cadence_bar_pct(0, _max), do: 0
  def cadence_bar_pct(_count, 0), do: 0
  def cadence_bar_pct(count, max), do: max(4, round(count / max * 100))

  @doc """
  A short human label for the budget that triggered an eviction, e.g.
  "keep 20 (oldest)" or "max 50 GB (shortest)".
  """
  def eviction_reason(eviction) do
    budget =
      [
        eviction.keep_count && "keep #{eviction.keep_count}",
        eviction.keep_bytes && "max #{gigabytes_from_bytes(eviction.keep_bytes)} GB"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    case budget do
      "" -> eviction.eviction_strategy || "budget"
      label -> "#{label} (#{eviction.eviction_strategy})"
    end
  end

  def cutoff_date_presets do
    [
      {"7 days", compute_date_offset(7)},
      {"14 days", compute_date_offset(14)},
      {"30 days", compute_date_offset(30)},
      {"60 days", compute_date_offset(60)},
      {"90 days", compute_date_offset(90)},
      {"180 days", compute_date_offset(180)},
      {"365 days", compute_date_offset(365)}
    ]
  end

  def rss_feed_url(conn, source) do
    # NOTE: The reason for this concatenation is to avoid what appears to be a bug in Phoenix
    # See: https://github.com/phoenixframework/phoenix/issues/6033
    url(conn, ~p"/sources/#{source.uuid}/feed") <> ".xml"
  end

  def opml_feed_url(conn) do
    url(conn, ~p"/sources/opml.xml?#{[route_token: Settings.get!(:route_token)]}")
  end

  def output_path_template_override_placeholders(media_profiles) do
    media_profiles
    |> Enum.map(&{&1.id, &1.output_path_template})
    |> Map.new()
    |> Phoenix.json_library().encode!()
  end

  def title_filter_regex_help do
    url = "https://github.com/nalgeon/sqlean/blob/main/docs/regexp.md#supported-syntax"
    classes = "underline decoration-bodydark decoration-1 hover:decoration-white"

    """
    A PCRE-compatible regex. Only media with titles that match this regex will be downloaded. <a href="#{url}" class="#{classes}" target="_blank">See here</a> for syntax
    """
  end

  def title_exclude_regex_help do
    url = "https://github.com/nalgeon/sqlean/blob/main/docs/regexp.md#supported-syntax"
    classes = "underline decoration-bodydark decoration-1 hover:decoration-white"

    """
    A PCRE-compatible regex. Media with titles matching this will NOT be downloaded. Use alternation (foo|bar) to exclude multiple terms. <a href="#{url}" class="#{classes}" target="_blank">See here</a> for syntax
    """
  end

  def output_path_template_override_help do
    help_button_classes = "underline decoration-bodydark decoration-1 hover:decoration-white cursor-pointer"
    help_button = ~s{<span class="#{help_button_classes}" x-on:click="$dispatch('load-template')">Click here</span>}

    """
    Must end with .{{ ext }}. Same rules as Media Profile output path templates. #{help_button} to load your media profile's output template
    """
  end

  defp compute_date_offset(days) do
    timezone = Application.get_env(:pinchflat, :timezone)

    timezone
    |> Timex.now()
    |> Timex.shift(days: -days)
    |> Timex.format!("{YYYY}-{0M}-{0D}")
  end
end
