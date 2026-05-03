defmodule Archdo.ConfigTest do
  use ExUnit.Case, async: true

  alias Archdo.Config

  describe "thresholds:" do
    test "from_keyword parses thresholds: keyword into the struct" do
      kw = [
        thresholds: [
          {"1.6", max_logger_calls: 5},
          {"1.11", min_files: 5}
        ]
      ]

      config = Config.from_keyword(kw, "/tmp/nonexistent_root")

      assert config.thresholds == %{
               "1.6" => [max_logger_calls: 5],
               "1.11" => [min_files: 5]
             }
    end

    test "from_keyword without thresholds: defaults to empty map" do
      config = Config.from_keyword([], "/tmp/nonexistent_root")
      assert config.thresholds == %{}
    end

    test "from_conventions returns empty thresholds" do
      config = Config.from_conventions("/tmp/nonexistent_root")
      assert config.thresholds == %{}
    end

    test "threshold/4 returns configured value when present" do
      config =
        Config.from_keyword(
          [thresholds: [{"1.6", max_logger_calls: 5}]],
          "/tmp/nonexistent_root"
        )

      assert Config.threshold(config, "1.6", :max_logger_calls, 3) == 5
    end

    test "threshold/4 returns default when rule_id absent" do
      config = Config.from_keyword([], "/tmp/nonexistent_root")
      assert Config.threshold(config, "1.6", :max_logger_calls, 3) == 3
    end

    test "threshold/4 returns default when key absent within rule" do
      config =
        Config.from_keyword(
          [thresholds: [{"1.6", other_key: 99}]],
          "/tmp/nonexistent_root"
        )

      assert Config.threshold(config, "1.6", :max_logger_calls, 3) == 3
    end
  end
end
