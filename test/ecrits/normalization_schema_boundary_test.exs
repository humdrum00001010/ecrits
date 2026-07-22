defmodule Ecrits.NormalizationSchemaBoundaryTest do
  use ExUnit.Case, async: true

  test "ACP Session does not own a second file-activity normalizer" do
    source = File.read!("lib/ecrits/acp_agent/session.ex")
    refute source =~ "defp normalize_file_activity_item("
  end
end
