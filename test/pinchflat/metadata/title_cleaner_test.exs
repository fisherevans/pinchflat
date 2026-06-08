defmodule Pinchflat.Metadata.TitleCleanerTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metadata.TitleCleaner

  defp cfg(attrs \\ []), do: struct(TitleCleaner, attrs)

  describe "clean_title/2" do
    test "returns blank input unchanged" do
      assert TitleCleaner.clean_title("", cfg()) == ""
      assert TitleCleaner.clean_title(nil, cfg()) == nil
    end

    test "picks the real episode title out of a noisy pipe-separated title" do
      raw = "SuperKitties Full Episode | Cat's Pajamas / Country Kitty | @disneyjr"
      assert TitleCleaner.clean_title(raw, cfg(show_name: "SuperKitties")) == "Cat's Pajamas / Country Kitty"
    end

    test "strips '{alias} Full Episode' but keeps a bare alias inside a real title" do
      assert TitleCleaner.clean_title("PJ Masks Full Episode | Pajama Party", cfg(show_name: "PJ Masks")) ==
               "Pajama Party"

      # the show name legitimately appears in the episode title - keep it
      # (trailing punctuation is stripped, matching the sidecar)
      assert TitleCleaner.clean_title("PJ Masks in SPACE!", cfg(show_name: "PJ Masks")) == "PJ Masks in SPACE"
    end

    test "strips brand tags and channel handles" do
      assert TitleCleaner.clean_title("Disney Jr. | The Big Race", cfg()) == "The Big Race"
      assert TitleCleaner.clean_title("The Big Race | @disneyjunior", cfg()) == "The Big Race"
      assert TitleCleaner.clean_title("PBS Kids | Counting Sheep", cfg()) == "Counting Sheep"
    end

    test "strips emojis and hashtags" do
      assert TitleCleaner.clean_title("Bubble Pop! 🫧🎉 #shorts #kids", cfg()) == "Bubble Pop"
    end

    test "strips season/episode markers" do
      conf = cfg(show_name: "Adventure Time")
      assert TitleCleaner.clean_title("Adventure Time S1 E4 | The Lost Map", conf) == "The Lost Map"
    end

    test "applies per-source extra_strip patterns" do
      conf = cfg(show_name: "Hero Squad", extra_strip: [~S/Superhero\s+Cartoons\s+for\s+Kids/])
      assert TitleCleaner.clean_title("The Rescue | Superhero Cartoons for Kids", conf) == "The Rescue"
    end

    test "ignores an invalid extra_strip pattern rather than crashing" do
      conf = cfg(extra_strip: ["(unclosed"])
      assert TitleCleaner.clean_title("Just A Title", conf) == "Just A Title"
    end

    test "falls back to an emoji/hashtag-cleaned original when everything is stripped" do
      # alias + Full Episode is the only content; nothing meaningful remains
      assert TitleCleaner.clean_title("Bluey Full Episode", cfg(show_name: "Bluey")) != ""
    end

    test "normalizes fullwidth pipes" do
      assert TitleCleaner.clean_title("Disney Jr.｜The Big Race", cfg()) == "The Big Race"
    end
  end

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
end
