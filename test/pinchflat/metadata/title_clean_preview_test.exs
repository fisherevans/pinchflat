defmodule Pinchflat.Metadata.TitleCleanPreviewTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metadata.TitleCleanPreview

  describe "decode_steps/1" do
    test "decodes a chain map or a bare step array" do
      assert {:ok, [%{"find" => "a"}]} = TitleCleanPreview.decode_steps(~s({"steps":[{"find":"a"}]}))
      assert {:ok, [%{"find" => "a"}]} = TitleCleanPreview.decode_steps(~s([{"find":"a"}]))
      assert {:ok, []} = TitleCleanPreview.decode_steps(~s({"steps":[]}))
    end

    test "returns :error on garbage so the save path leaves the stored chain untouched" do
      assert :error = TitleCleanPreview.decode_steps("not json")
      assert :error = TitleCleanPreview.decode_steps(~s({"steps":"oops"}))
      assert :error = TitleCleanPreview.decode_steps(nil)
      assert :error = TitleCleanPreview.decode_steps("")
    end
  end

  describe "parse_test_titles/1" do
    test "caps the number of ad-hoc test titles" do
      titles = 1..100 |> Enum.map(&%{"title" => "t#{&1}"}) |> Jason.encode!()
      assert length(TitleCleanPreview.parse_test_titles(titles)) == 50
    end

    test "is empty on bad input" do
      assert TitleCleanPreview.parse_test_titles("nope") == []
    end
  end

  describe "safe_run/3" do
    test "runs global then source steps and returns per-sample results" do
      global = [%{"enabled" => true, "find" => "a", "replace" => "b", "condition" => %{}}]
      source = [%{"enabled" => true, "find" => "b", "replace" => "c", "condition" => %{}}]

      assert {:ok, [result]} = TitleCleanPreview.safe_run(global, source, [%{title: "aa", duration_seconds: nil}])
      assert result.final == "cc"
      assert result.changed
      assert [%{is_global: true}, %{is_global: false}] = Enum.map(result.steps, &Map.take(&1, [:is_global]))
    end
  end
end
