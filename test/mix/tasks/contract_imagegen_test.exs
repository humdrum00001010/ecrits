defmodule Mix.Tasks.Contract.ImagegenTest do
  @moduledoc """
  Smoke for `mix contract.imagegen`. Asserts:

    * The manifest at `priv/imagegen/manifest.exs` decodes into the
      expected shape (5 entries, each with the required keys).
    * The Mix task is callable and runs against a stubbed Req plug
      (no real OpenAI traffic).
    * `--force` and idempotent skip both behave.
    * Missing `OPENAI_API_KEY` raises loudly.

  We point the task at a temp output directory by overriding the manifest
  through a tmp file passed via env, so the committed PNGs aren't
  touched.
  """

  use ExUnit.Case, async: false

  @manifest_path Path.expand("../../../priv/imagegen/manifest.exs", __DIR__)

  describe "manifest" do
    test "lives at the expected path" do
      assert File.exists?(@manifest_path), "expected manifest at #{@manifest_path}"
    end

    test "decodes into a list of well-formed entries" do
      {entries, _} = Code.eval_file(@manifest_path)
      assert is_list(entries)
      assert length(entries) >= 1

      Enum.each(entries, fn entry ->
        assert is_binary(entry.slug)
        assert is_binary(entry.prompt)
        assert entry.size in ["1024x1024", "1024x1536", "1536x1024"]
        assert entry.quality in ["low", "medium", "high"]
        assert is_binary(entry.output_path)
        assert String.starts_with?(entry.output_path, "priv/static/images/")
      end)
    end

    test "covers the committed landing assets" do
      {entries, _} = Code.eval_file(@manifest_path)
      slugs = Enum.map(entries, & &1.slug) |> MapSet.new()

      # Wave 3C0-E pared the manifest down to the two assets the
      # rewritten landing actually uses: the small accompanying hero
      # and the dashboard empty-state. The earlier 3-feature icon set
      # was retired with the feature-card grid.
      expected =
        MapSet.new([
          "hero",
          "dashboard-empty"
        ])

      assert MapSet.subset?(expected, slugs)
    end
  end

  describe "task runner" do
    setup do
      # Create a tiny temp manifest with one entry pointing into a tmpdir,
      # so the live committed PNGs are not overwritten by this test.
      tmp_root =
        Path.join(System.tmp_dir!(), "imagegen-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)

      tmp_manifest = Path.join(tmp_root, "manifest.exs")
      tmp_output = Path.join(tmp_root, "out.png")

      File.write!(tmp_manifest, """
      [
        %{
          slug: "smoke",
          prompt: "A black line drawing of a folder.",
          size: "1024x1024",
          quality: "medium",
          output_path: #{inspect(tmp_output)}
        }
      ]
      """)

      # Stub OpenAI: return a 1x1 transparent PNG, base64-encoded.
      pixel_png =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
          0, 0, 0, 3, 0, 1, 92, 205, 255, 105, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      b64 = Base.encode64(pixel_png)

      Req.Test.stub(:imagegen, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"b64_json" => b64}]})
      end)

      Application.put_env(:contract, :imagegen_req_options, plug: {Req.Test, :imagegen})

      System.put_env("OPENAI_API_KEY", "test-imagegen-key")

      on_exit(fn ->
        Application.delete_env(:contract, :imagegen_req_options)
        File.rm_rf!(tmp_root)
      end)

      {:ok, tmp_root: tmp_root, tmp_manifest: tmp_manifest, tmp_output: tmp_output}
    end

    test "is callable and writes a PNG via the stubbed plug", ctx do
      assert Code.ensure_loaded?(Mix.Tasks.Contract.Imagegen)
      assert function_exported?(Mix.Tasks.Contract.Imagegen, :run, 1)

      refute File.exists?(ctx.tmp_output)

      assert :ok =
               Mix.Tasks.Contract.Imagegen.run([
                 "--manifest",
                 ctx.tmp_manifest,
                 "--force"
               ])

      assert File.exists?(ctx.tmp_output)
      assert <<137, 80, 78, 71, _::binary>> = File.read!(ctx.tmp_output)
    end

    test "is idempotent — skips when output already exists", ctx do
      File.write!(ctx.tmp_output, "not-a-real-png-but-nonzero")

      # No stub call should be made; if the task tried to hit the plug it
      # would also succeed (we stubbed it) but the file content would be
      # overwritten. We assert the file is left as-is.
      assert :ok = Mix.Tasks.Contract.Imagegen.run(["--manifest", ctx.tmp_manifest])
      assert File.read!(ctx.tmp_output) == "not-a-real-png-but-nonzero"
    end

    test "--force regenerates even when output exists", ctx do
      File.write!(ctx.tmp_output, "stale")

      assert :ok =
               Mix.Tasks.Contract.Imagegen.run([
                 "--manifest",
                 ctx.tmp_manifest,
                 "--force"
               ])

      assert <<137, 80, 78, 71, _::binary>> = File.read!(ctx.tmp_output)
    end
  end

  describe "missing api key" do
    setup do
      prior = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      on_exit(fn -> if prior, do: System.put_env("OPENAI_API_KEY", prior) end)
      :ok
    end

    test "raises Mix.Error loudly when OPENAI_API_KEY is unset" do
      # Force regeneration so the missing-key branch is reached even when
      # outputs already exist on disk.
      assert_raise Mix.Error, ~r/OPENAI_API_KEY/, fn ->
        Mix.Tasks.Contract.Imagegen.run(["--force"])
      end
    end
  end
end
