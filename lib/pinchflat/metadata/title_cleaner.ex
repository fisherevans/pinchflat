defmodule Pinchflat.Metadata.TitleCleaner do
  @moduledoc """
  Pure title/plot cleaner for YouTube-sourced media. Strips clickbait noise
  (emoji, hashtags, channel handles, brand tags, "Full Episode" markers,
  season/episode markers, marketing taglines) so a clean episode title shows
  in Plex/Jellyfin.

  No I/O - takes a raw string plus a per-source config and returns the cleaned
  string, so it can be applied at index/download time and re-applied on demand
  when the rules change. Ported from the `pinchflat-titleclean` sidecar.

  The model: a title is a pipe-separated string of segments mixing a real
  episode title with marketing noise. Normalize, strip emoji/hashtags, split on
  `|`, clean each segment (drop show-name aliases + brand/marketing noise), drop
  empties, and keep the longest remaining segment. If everything is stripped,
  fall back to an emoji/hashtag-cleaned version of the original.
  """

  alias Pinchflat.Sources.Source

  @enforce_keys []
  defstruct show_name: "", aliases: [], extra_strip: [], plot_max_len: 500

  @type t :: %__MODULE__{
          show_name: String.t(),
          aliases: [String.t()],
          extra_strip: [String.t()],
          plot_max_len: pos_integer()
        }

  # Emoji / pictograph / symbol ranges. Broad enough for Disney Jr. / PBS /
  # Bobo titles; includes variation selectors + ZWJ so multi-codepoint emoji
  # sequences are fully removed.
  @emoji_ranges [
    {0x1F000, 0x1FFFF},
    {0x2300, 0x23FF},
    {0x2460, 0x24FF},
    {0x2500, 0x25FF},
    {0x2600, 0x27BF},
    {0x2B00, 0x2BFF},
    {0xFE00, 0xFE0F},
    {0x200D, 0x200D},
    {0x20E3, 0x20E3}
  ]

  # Brand-level strips, always applied (not anchored to a show alias).
  # Longer-first to avoid partial overlap.
  @global_strips [
    ~S/Disney\s*Jr\.?(?:'s)?/,
    ~S/Disney\s*Junior/,
    ~S/PBS\s*Kids!?/,
    ~S/(?<!\w)@\w+/,
    ~S/\bNEW\s+SHOW!?/,
    ~S/\bNEW\s+SERIES!?/,
    ~S/\bNEW\s+EPISODE!?/,
    ~S/\bBRAND\s+NEW!/,
    ~S/\bS\d+\s*E\d+(?:\s*Part\s+\d+)?\b/,
    ~S/\bSeason\s+\d+(?:\s*Episode\s+\d+)?/,
    ~S/\bPart\s+[IVX]+\b/,
    ~S/\bPart\s+\d+\b/,
    ~S/\bPremiere\b|\bPremier\b/,
    ~S/^AD\s*[|:]\s*/,
    ~S/^\s*AD\s+/
  ]

  # Marketing phrases stripped only when they follow a show-name alias, so a
  # bare alias inside a legit episode title ("PJ Masks in SPACE!") survives.
  @noise_after_alias [
    ~S/First\s+Full\s+Episodes?!?/,
    ~S/Holiday\s+Full\s+Episodes?!?/,
    ~S/Brand\s+New\s+Full\s+Episodes?!?/,
    ~S/Full\s+Episodes?!?/,
    ~S/FULL\s+EPISODES?!?/
  ]

  # Fallback when the alias-anchored strips miss.
  @bare_noise [
    ~S/\bFirst\s+Full\s+Episodes?!?/,
    ~S/\bHoliday\s+Full\s+Episodes?!?/,
    ~S/\bFull\s+Episodes?!?/,
    ~S/\bFULL\s+EPISODES?!?/
  ]

  @marketing_keywords [
    "LIKE and SUBSCRIBE",
    "LIKE AND SUBSCRIBE",
    "Subscribe to",
    "SUBSCRIBE",
    "Follow us on",
    "Follow me on",
    "Check out our merch",
    "Check out my merch",
    "Shot on",
    "Sign up",
    "Click here",
    "Use code",
    "Visit us at",
    "Watch more",
    "Watch the full",
    "For all your",
    "Want more",
    "#"
  ]

  @doc "Builds a cleaner config from a source's title-clean settings."
  def config_for(%Source{} = source) do
    %__MODULE__{
      show_name: source.custom_name || "",
      aliases: source.title_clean_aliases || [],
      extra_strip: source.title_clean_extra_strip || []
    }
  end

  @doc """
  Returns the cleaned title - the longest meaningful segment after stripping
  noise. Returns the input unchanged when it's blank.
  """
  def clean_title(nil, _cfg), do: nil

  def clean_title(raw, %__MODULE__{} = cfg) do
    if String.trim(raw) == "" do
      raw
    else
      do_clean_title(raw, cfg)
    end
  end

  defp do_clean_title(raw, cfg) do
    s =
      raw
      |> normalize()
      |> strip_emojis()
      |> regex_replace(~r/(?<!\w)#\w+/u, "")
      # strip wrapping quote pairs across the whole title before the pipe split
      |> regex_replace(~r/"([^"]+)"/u, "\\1")
      |> regex_replace(~r/(?<!\w)'([^'\n]+)'(?!\w)/u, "\\1")

    cleaned =
      s
      |> String.split("|")
      |> Enum.map(&clean_segment(String.trim(&1), cfg))
      |> Enum.filter(&(&1 != "" and String.length(&1) >= 2))

    case cleaned do
      [] ->
        # Everything stripped - keep an emoji/hashtag-cleaned original rather
        # than synthesizing garbled fragments.
        fallback = s |> regex_replace(~r/\s+/u, " ") |> String.trim() |> String.trim(" -|")
        if fallback == "", do: String.trim(raw), else: fallback

      segments ->
        segments
        |> Enum.sort_by(fn seg -> {-String.length(seg), seg} end)
        |> hd()
    end
  end

  defp clean_segment(seg, cfg) do
    aliases =
      [cfg.show_name | cfg.aliases]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort_by(&(-String.length(&1)))

    seg
    |> strip_alias_noise(aliases)
    |> strip_patterns(@global_strips)
    |> strip_patterns(@bare_noise)
    |> strip_extra(cfg.extra_strip)
    |> String.trim()
    |> regex_replace(~r/^["'`“”‘’]+/u, "")
    |> regex_replace(~r/["'`“”‘’]+$/u, "")
    |> regex_replace(~r/\s+/u, " ")
    |> String.trim()
    |> regex_replace(~r/^[\s\-–—!?.,:;|]+/u, "")
    |> regex_replace(~r/[\s\-–—!?.,:;|]+$/u, "")
    |> String.trim()
    |> drop_if_bare_alias(aliases)
  end

  defp strip_alias_noise(seg, aliases) do
    Enum.reduce(aliases, seg, fn alias_str, acc ->
      escaped = Regex.escape(alias_str)

      acc =
        Enum.reduce(@noise_after_alias, acc, fn noise, inner ->
          regex_replace(inner, compile_i("\\b#{escaped}\\+?(?:'s)?\\s+#{noise}"), "")
        end)

      # Strip a trailing 'sep alias' (e.g. " /// Danny Go!", " - Emily's Science Lab")
      regex_replace(acc, compile_i("\\s*[-|/]+\\s*#{escaped}\\+?(?:'s)?\\s*$"), "")
    end)
  end

  defp strip_patterns(seg, patterns) do
    Enum.reduce(patterns, seg, fn pattern, acc -> regex_replace(acc, compile_i(pattern), "") end)
  end

  defp strip_extra(seg, extra_strip) do
    Enum.reduce(extra_strip, seg, fn pattern, acc ->
      case safe_compile_i(pattern) do
        {:ok, regex} -> regex_replace(acc, regex, "")
        {:error, _} -> acc
      end
    end)
  end

  defp drop_if_bare_alias(seg, aliases) do
    bare = seg |> String.downcase() |> String.trim_trailing("!") |> String.trim()
    alias_set = MapSet.new(aliases, &String.downcase/1)
    if MapSet.member?(alias_set, bare), do: "", else: seg
  end

  @doc """
  Cleaned plot/description: strips URLs, hashtags, emoji, cuts at the first
  marketing keyword or paragraph break, then truncates to `max_len`.
  """
  def clean_plot(raw, max_len \\ 500)
  def clean_plot(nil, _max_len), do: ""

  def clean_plot(raw, max_len) do
    s =
      raw
      |> normalize()
      |> strip_emojis()
      |> regex_replace(~r/https?:\/\/\S+/iu, "")
      |> regex_replace(~r/(?<!\w)#\w+/u, "")

    s
    |> cut_at_earliest_keyword()
    |> cut_at_paragraph_break()
    |> regex_replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(max_len)
  end

  defp cut_at_earliest_keyword(s) do
    earliest =
      Enum.reduce(@marketing_keywords, byte_size(s), fn kw, acc ->
        case :binary.match(s, kw) do
          {idx, _len} -> min(idx, acc)
          :nomatch -> acc
        end
      end)

    binary_part(s, 0, earliest)
  end

  defp cut_at_paragraph_break(s) do
    case :binary.match(s, "\n\n") do
      {idx, _len} when idx > 0 -> binary_part(s, 0, idx)
      _ -> s
    end
  end

  defp truncate(s, max_len) do
    if String.length(s) <= max_len do
      s
    else
      cut = String.slice(s, 0, max_len)
      head = cut |> String.split(" ") |> Enum.drop(-1) |> Enum.join(" ")
      head <> "…"
    end
  end

  @doc "Makes a title safe for the filesystem."
  def sanitize_filename(title, max_len \\ 180) do
    s =
      title
      |> regex_replace(~r/[<>:"\/\\|?*\x00-\x1f]/u, "-")
      |> regex_replace(~r/\s*-\s*-\s*/u, " - ")
      |> regex_replace(~r/\s+/u, " ")
      |> String.trim(" .-_")

    if String.length(s) > max_len do
      s |> String.slice(0, max_len) |> String.trim_trailing(" .-_")
    else
      s
    end
  end

  @doc "NFKC + fullwidth -> ASCII pipe/colon + curly quotes -> straight."
  def normalize(s) do
    s
    |> String.replace("｜", "|")
    |> String.replace("：", ":")
    |> String.replace("‘", "'")
    |> String.replace("’", "'")
    |> String.replace("“", "\"")
    |> String.replace("”", "\"")
    |> :unicode.characters_to_nfkc_binary()
  end

  @doc "Strips emoji/pictograph/symbol codepoints."
  def strip_emojis(s) do
    s
    |> String.to_charlist()
    |> Enum.reject(&in_emoji_range?/1)
    |> List.to_string()
  end

  defp in_emoji_range?(cp), do: Enum.any?(@emoji_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)

  defp regex_replace(subject, regex, replacement), do: Regex.replace(regex, subject, replacement)

  defp compile_i(source), do: Regex.compile!(source, "iu")

  defp safe_compile_i(source), do: Regex.compile(source, "iu")
end
