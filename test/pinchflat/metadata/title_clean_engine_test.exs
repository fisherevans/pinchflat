defmodule Pinchflat.Metadata.TitleCleanEngineTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metadata.TitleCleanEngine, as: Engine

  defp chain(steps), do: %{"steps" => steps}

  defp rule(attrs) do
    Map.merge(%{"enabled" => true, "find" => "", "replace" => "", "condition" => %{}}, attrs)
  end

  defp run(steps, title, duration \\ nil) do
    Engine.run(chain(steps), %{title: title, duration_seconds: duration})
  end

  describe "run/2 - basics" do
    test "an empty chain passes the title through unchanged with an empty trace" do
      assert %{output: "Hello", trace: []} = run([], "Hello")
    end

    test "a nil/blank title is handled" do
      assert %{output: ""} = Engine.run(chain([]), %{title: nil})
    end

    test "a find/replace rule removes matching text" do
      step = rule(%{"name" => "drop tag", "find" => "\\s*\\| Full Episode", "replace" => ""})
      assert %{output: "Pajama Party"} = run([step], "Pajama Party | Full Episode")
    end

    test "replace supports a literal substitution" do
      step = rule(%{"find" => "colou?r", "replace" => "shade"})
      assert %{output: "shade of blue"} = run([step], "color of blue")
    end
  end

  describe "run/2 - chaining" do
    test "each step runs on the output of the previous one" do
      steps = [
        rule(%{"name" => "a->b", "find" => "alpha", "replace" => "beta"}),
        rule(%{"name" => "b->c", "find" => "beta", "replace" => "gamma"})
      ]

      %{output: output, trace: [t1, t2]} = run(steps, "alpha")

      assert output == "gamma"
      assert t1.before == "alpha" and t1.after == "beta"
      # step 2 sees step 1's output, not the original
      assert t2.before == "beta" and t2.after == "gamma"
    end
  end

  describe "run/2 - case sensitivity" do
    test "matching is case-insensitive by default" do
      step = rule(%{"find" => "disney", "replace" => ""})
      assert %{output: " Jr."} = run([step], "Disney Jr.")
    end

    test "case_sensitive only matches the exact case" do
      step = rule(%{"find" => "disney", "replace" => "X", "case_sensitive" => true})
      assert %{output: "Disney"} = run([step], "Disney")
    end
  end

  describe "run/2 - presets" do
    test "strip_emojis removes emoji" do
      step = rule(%{"preset_key" => "strip_emojis"})
      assert %{output: "Bubble Pop! "} = run([step], "Bubble Pop! 🫧🎉")
    end

    test "normalize_whitespace collapses and trims" do
      step = rule(%{"preset_key" => "normalize_whitespace"})
      assert %{output: "a b c"} = run([step], "  a   b\tc  ")
    end

    test "strip_hashtags removes hashtags and @handles" do
      step = rule(%{"preset_key" => "strip_hashtags"})
      assert %{output: "Bubble Pop"} = run([step], "Bubble Pop #shorts @disneyjr")
    end
  end

  describe "run/2 - conditions" do
    test "title_contains gates application (case-insensitive)" do
      step =
        rule(%{"find" => "Jr\\.", "replace" => "", "condition" => %{"kind" => "title_contains", "value" => "disney"}})

      assert %{output: "Disney "} = run([step], "Disney Jr.")
      assert %{output: "PBS Jr.", trace: [t]} = run([step], "PBS Jr.")
      assert t.status == :condition_skipped
    end

    test "title_matches gates on a regex" do
      step =
        rule(%{"find" => "X", "replace" => "", "condition" => %{"kind" => "title_matches", "value" => "^S\\d+E\\d+"}})

      assert %{trace: [%{status: :unchanged}]} = run([step], "S1E2 the title")
      assert %{trace: [%{status: :condition_skipped}]} = run([step], "no marker")
    end

    test "duration_lt / duration_gt compare against the item's duration" do
      lt = rule(%{"find" => "$", "replace" => " (Short)", "condition" => %{"kind" => "duration_lt", "value" => "60"}})

      assert %{output: "clip (Short)"} = run([lt], "clip", 30)
      assert %{output: "clip", trace: [%{status: :condition_skipped}]} = run([lt], "clip", 120)
    end

    test "duration_between is inclusive" do
      step =
        rule(%{
          "find" => "x",
          "replace" => "y",
          "condition" => %{"kind" => "duration_between", "min" => "10", "max" => "20"}
        })

      assert %{output: "y"} = run([step], "x", 15)
      assert %{output: "x"} = run([step], "x", 25)
    end

    test "a duration condition is skipped when the item has no duration" do
      step = rule(%{"find" => "x", "replace" => "y", "condition" => %{"kind" => "duration_lt", "value" => "60"}})
      assert %{output: "x", trace: [%{status: :condition_skipped}]} = run([step], "x", nil)
    end
  end

  describe "run/2 - disabled + trace" do
    test "a disabled step is recorded but does not change the title" do
      steps = [
        rule(%{"name" => "off", "enabled" => false, "find" => "a", "replace" => "z"}),
        rule(%{"name" => "on", "find" => "b", "replace" => "z"})
      ]

      %{output: output, trace: [t1, t2]} = run(steps, "ab")

      assert output == "az"
      assert t1.status == :disabled and t1.after == "ab"
      assert t2.status == :changed
    end

    test "a changed step carries an inline char-level diff" do
      step = rule(%{"find" => "Jr\\.", "replace" => ""})
      %{trace: [t]} = run([step], "Disney Jr.")

      assert t.status == :changed
      assert Enum.any?(t.diff, &(&1.op == "del"))
      assert Enum.all?(t.diff, fn seg -> seg.op in ["eq", "del", "ins"] end)
    end

    test "an unchanged enabled step is marked :unchanged with no diff" do
      step = rule(%{"find" => "zzz", "replace" => ""})
      %{trace: [t]} = run([step], "no match here")

      assert t.status == :unchanged
      assert t.diff == []
    end

    test "an invalid regex is a no-op rather than a crash" do
      step = rule(%{"find" => "(unclosed", "replace" => ""})
      assert %{output: "Just A Title"} = run([step], "Just A Title")
    end
  end

  describe "active?/1" do
    test "true only when at least one step is enabled" do
      refute Engine.active?(chain([]))
      refute Engine.active?(chain([rule(%{"enabled" => false})]))
      assert Engine.active?(chain([rule(%{"enabled" => true})]))
    end
  end

  describe "valid_step?/1 and valid_condition?/1" do
    test "a preset step is always valid regardless of find" do
      assert Engine.valid_step?(rule(%{"preset_key" => "strip_emojis", "find" => "(bad"}))
    end

    test "a find/replace step requires a compilable regex" do
      assert Engine.valid_step?(rule(%{"find" => "ok\\d+"}))
      refute Engine.valid_step?(rule(%{"find" => "(unclosed"}))
    end

    test "condition shape is validated" do
      assert Engine.valid_condition?(%{"kind" => "none"})
      assert Engine.valid_condition?(%{"kind" => "title_contains", "value" => "x"})
      refute Engine.valid_condition?(%{"kind" => "title_contains", "value" => ""})
      refute Engine.valid_condition?(%{"kind" => "title_matches", "value" => "(bad"})
      assert Engine.valid_condition?(%{"kind" => "duration_lt", "value" => "60"})
      refute Engine.valid_condition?(%{"kind" => "duration_lt", "value" => "abc"})
      assert Engine.valid_condition?(%{"kind" => "duration_between", "min" => "1", "max" => "2"})
    end
  end
end
