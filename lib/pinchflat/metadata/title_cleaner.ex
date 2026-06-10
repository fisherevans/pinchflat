defmodule Pinchflat.Metadata.TitleCleaner do
  @moduledoc """
  Description/plot cleaning and shared text primitives for YouTube-sourced media.

  Title cleaning itself moved to the user-configurable rule chain in
  `Pinchflat.Metadata.TitleCleanEngine`. What remains here is the plot/description cleaner (used at
  NFO-write time) plus the low-level primitives the engine's presets reuse - emoji stripping
  and fullwidth/quote normalization - and `sanitize_filename/2` for filesystem-safe titles.

  No I/O - pure string transforms.
  """

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
end
