defmodule Pinchflat.Metadata.TitleCleanerTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metadata.TitleCleaner

  describe "clean_plot/2" do
    test "returns empty for nil" do
      assert TitleCleaner.clean_plot(nil) == ""
    end

    test "cuts at the first marketing keyword and strips urls/hashtags" do
      raw = "A fun adventure with the gang. SUBSCRIBE for more! https://youtube.com/x #kids"
      assert TitleCleaner.clean_plot(raw) == "A fun adventure with the gang."
    end

    test "cuts at the first paragraph break" do
      assert TitleCleaner.clean_plot("First paragraph.\n\nSecond paragraph.") == "First paragraph."
    end

    test "truncates to max_len with an ellipsis" do
      result = TitleCleaner.clean_plot(String.duplicate("word ", 50), 20)
      assert String.ends_with?(result, "…")
      assert String.length(result) <= 21
    end
  end

  describe "sanitize_filename/1" do
    test "replaces filesystem-unsafe characters" do
      assert TitleCleaner.sanitize_filename("Cat's Pajamas / Country Kitty") == "Cat's Pajamas - Country Kitty"
      assert TitleCleaner.sanitize_filename("a:b*c?d") == "a-b-c-d"
    end
  end

  describe "strip_emojis/1" do
    test "removes emoji and pictographs but keeps text" do
      assert TitleCleaner.strip_emojis("Bubble Pop! 🫧🎉") == "Bubble Pop! "
    end

    test "keeps multibyte non-emoji characters intact" do
      result = TitleCleaner.strip_emojis("Pokémon clip")
      assert result == "Pokémon clip"
      assert String.valid?(result)
    end
  end

  describe "normalize/1" do
    test "converts fullwidth pipe/colon and curly quotes to ascii" do
      assert TitleCleaner.normalize("Disney Jr.｜The Big Race") == "Disney Jr.|The Big Race"
      assert TitleCleaner.normalize("“quoted”") == "\"quoted\""
    end
  end
end
