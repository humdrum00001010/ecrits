defmodule Contract.Export.HWPXTest do
  use ExUnit.Case, async: true

  alias Contract.Export.HWPX
  alias Contract.Runtime.State

  # --------------------------------------------------------------------------
  # Test helpers
  # --------------------------------------------------------------------------

  defp empty_state do
    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: State.empty_projection()
    }
  end

  defp state_with_nodes(nodes_list) do
    nodes = Map.new(nodes_list, fn n -> {n.id, n} end)
    order = Enum.map(nodes_list, & &1.id)

    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes,
          node_order: order
      }
    }
  end

  # Unzip an HWPX binary into a map of `name -> {body, info}` where info
  # is the :zip file_info record (kept for the STORED/DEFLATED check).
  defp unzip_to_map(bin) do
    {:ok, handle} = :zip.zip_open(bin, [:memory])
    {:ok, list} = :zip.zip_list_dir(handle)

    map =
      list
      |> Enum.flat_map(fn
        {:zip_file, name, info, _comment, _offset, _comp_size} ->
          {:ok, {^name, body}} = :zip.zip_get(name, handle)
          [{IO.iodata_to_binary(name), {body, info}}]

        _ ->
          []
      end)
      |> Map.new()

    :zip.zip_close(handle)
    map
  end

  # Same but returns just the body bytes by name.
  defp unzip_body(bin, name) do
    {body, _info} = Map.fetch!(unzip_to_map(bin), name)
    body
  end

  # Parse XML with :xmerl_scan and return :ok or {:error, reason}.
  # xmerl_scan/string wants a list of bytes (not Unicode codepoints), so we
  # pass the binary through :binary.bin_to_list/1 — that preserves UTF-8
  # byte sequences as the scanner expects per the XML 1.0 encoding decl.
  defp parse_xml(bin) do
    try do
      {_doc, _rest} = :xmerl_scan.string(:binary.bin_to_list(bin))
      :ok
    catch
      :exit, reason -> {:error, reason}
    end
  end

  # --------------------------------------------------------------------------
  # 1. Empty projection round-trip
  # --------------------------------------------------------------------------

  test "render/2 returns {:ok, binary} for an empty projection" do
    assert {:ok, bin} = HWPX.render(empty_state())
    assert is_binary(bin)
    assert byte_size(bin) > 0
  end

  test "render/2 accepts a bare projection map (not just a State struct)" do
    assert {:ok, bin1} = HWPX.render(State.empty_projection())
    assert {:ok, bin2} = HWPX.render(empty_state())
    # Both should be byte-identical (same projection content).
    assert bin1 == bin2
  end

  # --------------------------------------------------------------------------
  # 2. ZIP magic + mimetype
  # --------------------------------------------------------------------------

  test "output starts with ZIP magic bytes (PK)" do
    {:ok, bin} = HWPX.render(empty_state())
    assert <<"PK", _::binary>> = bin
  end

  test "mimetype entry decodes to application/hwp+zip" do
    {:ok, bin} = HWPX.render(empty_state())
    assert "application/hwp+zip" == unzip_body(bin, "mimetype")
  end

  # --------------------------------------------------------------------------
  # 3. mimetype entry is STORED (uncompressed)
  # --------------------------------------------------------------------------

  test "mimetype entry is STORED (compressed_size == uncompressed_size)" do
    {:ok, bin} = HWPX.render(empty_state())

    # Parse the ZIP local file header for the first entry. Layout:
    # signature(4) version(2) gpbf(2) method(2) time(2) date(2) crc(4)
    # csize(4) usize(4) namelen(2) extralen(2) name(namelen) extra(extralen)
    <<0x04034B50::little-32, _ver::little-16, _gpbf::little-16, method::little-16, _t::little-16,
      _d::little-16, _crc::little-32, csize::little-32, usize::little-32, namelen::little-16,
      extralen::little-16, name::binary-size(namelen), _extra::binary-size(extralen),
      _rest::binary>> = bin

    assert name == "mimetype"
    # Method 0 = STORED.
    assert method == 0
    assert csize == usize
  end

  # --------------------------------------------------------------------------
  # 4. Required entries present
  # --------------------------------------------------------------------------

  test "required entries are present" do
    {:ok, bin} = HWPX.render(empty_state())
    entries = unzip_to_map(bin) |> Map.keys() |> MapSet.new()

    required =
      MapSet.new([
        "mimetype",
        "version.xml",
        "META-INF/container.xml",
        "META-INF/manifest.xml",
        "Contents/content.hpf",
        "Contents/header.xml",
        "Contents/section0.xml",
        "settings.xml"
      ])

    assert MapSet.subset?(required, entries),
           "missing entries: #{inspect(MapSet.to_list(MapSet.difference(required, entries)))}"
  end

  # --------------------------------------------------------------------------
  # 5. All XML entries are well-formed
  # --------------------------------------------------------------------------

  test "every XML entry parses with :xmerl_scan" do
    {:ok, bin} = HWPX.render(empty_state())
    map = unzip_to_map(bin)

    xml_entries =
      map
      |> Enum.filter(fn {k, _} ->
        String.ends_with?(k, ".xml") or String.ends_with?(k, ".hpf")
      end)

    Enum.each(xml_entries, fn {name, {body, _info}} ->
      assert parse_xml(body) == :ok, "XML did not parse: #{name}"
    end)
  end

  # --------------------------------------------------------------------------
  # 6. 5 paragraphs → 5 <hp:p> with text in section0.xml
  # --------------------------------------------------------------------------

  test "5 paragraphs produce 5 <hp:p> elements containing the text" do
    nodes =
      for i <- 1..5 do
        %{id: "p#{i}", kind: :paragraph, content: "Paragraph #{i} body."}
      end

    state = state_with_nodes(nodes)
    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    # Count <hp:p ... > opening tags.
    count = section |> String.split("<hp:p ") |> length() |> Kernel.-(1)
    assert count == 5

    # All text bodies present.
    Enum.each(1..5, fn i ->
      assert section =~ "Paragraph #{i} body."
    end)
  end

  # --------------------------------------------------------------------------
  # 7. Heading at level=1 uses heading paraShape
  # --------------------------------------------------------------------------

  test "heading at level=1 uses the heading paraShapeIDRef" do
    nodes = [
      %{id: "h", kind: :heading, content: "TITLE", attrs: %{level: 1}}
    ]

    state = state_with_nodes(nodes)
    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    # Heading level 1 → paraShape id 2 (heading_para_base + 0), charShape id 1.
    assert section =~ ~s(paraPrIDRef="2")
    assert section =~ ~s(charPrIDRef="1")
    assert section =~ "TITLE"
  end

  test "heading at level=6 uses paraShape 7 and charShape 6" do
    nodes = [%{id: "h", kind: :heading, content: "Level Six", attrs: %{level: 6}}]
    state = state_with_nodes(nodes)
    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    assert section =~ ~s(paraPrIDRef="7")
    assert section =~ ~s(charPrIDRef="6")
    assert section =~ "Level Six"
  end

  # --------------------------------------------------------------------------
  # 8. List with 3 list_items → 3 paragraphs with bullet style
  # --------------------------------------------------------------------------

  test "a :list with 3 :list_items emits 3 bullet-style paragraphs" do
    list_id = "L"
    item_ids = ["i1", "i2", "i3"]

    list_node = %{id: list_id, kind: :list, children: item_ids}

    item_nodes =
      Enum.with_index(item_ids, 1)
      |> Enum.map(fn {id, idx} ->
        %{id: id, kind: :list_item, parent_id: list_id, content: "Item #{idx}"}
      end)

    all = [list_node | item_nodes]

    nodes_map = Map.new(all, fn n -> {n.id, n} end)

    state = %State{
      document_id: "doc-0000-0000-0000-000000000002",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes_map,
          node_order: [list_id]
      }
    }

    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    # Bullet paragraph uses paraPrIDRef="1".
    count = section |> String.split(~s(paraPrIDRef="1")) |> length() |> Kernel.-(1)
    # The list_node itself is consumed (rendered as 3 bullet paragraphs in the
    # rest position). If the list happens to be the *first* top-level node the
    # implementation prepends a secPr-carrying body paragraph too, so we
    # assert "at least 3" rather than "exactly 3".
    assert count >= 3

    Enum.each(1..3, fn i ->
      assert section =~ "Item #{i}"
    end)
  end

  # --------------------------------------------------------------------------
  # 9. 2x3 table emits <hp:tbl> + 2 <hp:tr> + 6 <hp:tc>
  # --------------------------------------------------------------------------

  test "2x3 table emits one <hp:tbl>, 2 <hp:tr>, 6 <hp:tc>" do
    cell_ids = for i <- 1..6, do: "c#{i}"

    cells =
      cell_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, idx} ->
        %{id: id, kind: :cell, content: "C#{idx}"}
      end)

    table = %{
      id: "T",
      kind: :table,
      attrs: %{rows: 2, cols: 3},
      children: cell_ids
    }

    all = [table | cells]
    nodes_map = Map.new(all, fn n -> {n.id, n} end)

    state = %State{
      document_id: "doc-0000-0000-0000-000000000003",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes_map,
          node_order: ["T"]
      }
    }

    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    assert section |> String.split("<hp:tbl ") |> length() |> Kernel.-(1) == 1
    assert section |> String.split("<hp:tr>") |> length() |> Kernel.-(1) == 2
    assert section |> String.split("<hp:tc ") |> length() |> Kernel.-(1) == 6

    Enum.each(1..6, fn i ->
      assert section =~ "C#{i}"
    end)
  end

  # --------------------------------------------------------------------------
  # 10. UTF-8 Korean content round-trip
  # --------------------------------------------------------------------------

  test "UTF-8 Korean content survives through the ZIP path" do
    korean = "안녕하세요 계약 초안"
    nodes = [%{id: "p1", kind: :paragraph, content: korean}]
    state = state_with_nodes(nodes)

    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    assert section =~ korean
    # And the exact UTF-8 byte sequence:
    assert :binary.match(section, korean) != :nomatch
  end

  # --------------------------------------------------------------------------
  # 11. XML escape for & < > " '
  # --------------------------------------------------------------------------

  test "special XML chars in text are escaped" do
    raw = "A & B <c> \"d\" 'e'"
    nodes = [%{id: "p1", kind: :paragraph, content: raw}]
    state = state_with_nodes(nodes)

    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    assert section =~ "A &amp; B &lt;c&gt; &quot;d&quot; &apos;e&apos;"
    # The raw unescaped form must NOT appear:
    refute section =~ raw
  end

  # --------------------------------------------------------------------------
  # 12. End-to-end via Engine.apply
  # --------------------------------------------------------------------------

  test "renders a state built up via Engine.apply pipeline" do
    alias Contract.{Action, Engine, Runtime}

    # Build a small document with three create_node ops.
    state = %Runtime.State{
      document_id: "doc-0000-0000-0000-000000000004",
      revision: 0,
      projection: Runtime.State.empty_projection()
    }

    action = %Action{
      kind: :edit_document,
      document_id: "doc-0000-0000-0000-000000000004",
      actor_type: :user,
      actor_id: "11111111-1111-1111-1111-000000000002",
      base_revision: 0,
      payload: %{
        "ops" => [
          %{
            "op" => "create_node",
            "target_type" => "node",
            "target_id" => "n1",
            "args" => %{
              "kind" => "heading",
              "content" => "Contract Title",
              "attrs" => %{"level" => 1}
            }
          },
          %{
            "op" => "create_node",
            "target_type" => "node",
            "target_id" => "n2",
            "args" => %{"kind" => "paragraph", "content" => "First clause."}
          },
          %{
            "op" => "create_node",
            "target_type" => "node",
            "target_id" => "n3",
            "args" => %{"kind" => "paragraph", "content" => "Second clause."}
          }
        ]
      }
    }

    {:ok, input} = Engine.compile(action, state)
    {:ok, :ok} = Engine.validate(input, state)
    {:ok, pre} = Engine.preimage(input, state)
    {:ok, inv} = Engine.inverse(input, pre)
    {:ok, refs} = Engine.affected_refs(input, state)
    input = %{input | preimage: pre, inverse_ops: inv, affected_refs: refs}
    {:ok, new_state} = Engine.apply(input, state)

    assert {:ok, bin} = HWPX.render(new_state)
    section = unzip_body(bin, "Contents/section0.xml")
    assert section =~ "Contract Title"
    assert section =~ "First clause."
    assert section =~ "Second clause."
  end

  # --------------------------------------------------------------------------
  # 13. Determinism — same projection → byte-identical output
  # --------------------------------------------------------------------------

  test "render is deterministic across invocations" do
    nodes = [
      %{id: "h", kind: :heading, content: "Title", attrs: %{level: 1}},
      %{id: "p1", kind: :paragraph, content: "Hello world."},
      %{id: "p2", kind: :paragraph, content: "Another paragraph."}
    ]

    state = state_with_nodes(nodes)
    {:ok, a} = HWPX.render(state)
    {:ok, b} = HWPX.render(state)
    {:ok, c} = HWPX.render(state)

    assert a == b
    assert b == c
  end

  # --------------------------------------------------------------------------
  # 14. Output size is reasonable
  # --------------------------------------------------------------------------

  test "5-paragraph projection produces a reasonable-sized HWPX" do
    nodes =
      for i <- 1..5 do
        %{id: "p#{i}", kind: :paragraph, content: "Paragraph #{i}."}
      end

    state = state_with_nodes(nodes)
    {:ok, bin} = HWPX.render(state)

    # Hand-rolled output should be well under 10 KB.
    assert byte_size(bin) < 10_000,
           "HWPX too large: #{byte_size(bin)} bytes"

    # And not absurdly small (sanity check).
    assert byte_size(bin) > 800
  end

  # --------------------------------------------------------------------------
  # 15. :xmerl_scan locates <hp:t> text nodes
  # --------------------------------------------------------------------------

  test "xmerl can locate <hp:t> text nodes in section0.xml" do
    nodes = [
      %{id: "p1", kind: :paragraph, content: "Findable text alpha."},
      %{id: "p2", kind: :paragraph, content: "Findable text beta."}
    ]

    state = state_with_nodes(nodes)
    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    {doc, _rest} = :xmerl_scan.string(:binary.bin_to_list(section))

    # Walk the tree manually to collect all character data inside <hp:t>.
    texts = collect_hp_t_text(doc)
    joined = Enum.join(texts, "|")

    assert joined =~ "Findable text alpha."
    assert joined =~ "Findable text beta."
  end

  # Recursive walker — xmerl_scan returns Erlang records (xmlElement, xmlText).
  # We treat the record tag in position 0 as the discriminator.
  defp collect_hp_t_text(node) when is_tuple(node) do
    case elem(node, 0) do
      :xmlElement ->
        # xmlElement: {xmlElement, name, expanded_name, nsinfo, namespace,
        # parents, pos, attributes, content, language, xmlbase, elementdef}
        name = elem(node, 1)
        content = elem(node, 8)

        own =
          if name == :"hp:t" do
            content
            |> Enum.flat_map(fn child ->
              case child do
                txt when is_tuple(txt) and elem(txt, 0) == :xmlText ->
                  [elem(txt, 4) |> to_string()]

                _ ->
                  []
              end
            end)
          else
            []
          end

        own ++ Enum.flat_map(content, &collect_hp_t_text/1)

      _ ->
        []
    end
  end

  defp collect_hp_t_text(_), do: []

  # --------------------------------------------------------------------------
  # 16. field_ref resolves through projection.fields
  # --------------------------------------------------------------------------

  test "a :field_ref node resolves its value via projection.fields" do
    field_id = "F1"

    nodes_map = %{
      "p1" => %{
        id: "p1",
        kind: :field_ref,
        attrs: %{field_id: field_id}
      }
    }

    fields = %{field_id => %{id: field_id, key: :amount, value: "1,500,000원"}}

    state = %State{
      document_id: "doc-0000-0000-0000-000000000005",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes_map,
          node_order: ["p1"],
          fields: fields
      }
    }

    {:ok, bin} = HWPX.render(state)
    section = unzip_body(bin, "Contents/section0.xml")

    assert section =~ "1,500,000원"
  end

  # --------------------------------------------------------------------------
  # 17. Renderer dispatch (smoke)
  # --------------------------------------------------------------------------

  test "Contract.Export.Renderer.render/3 dispatches :hwpx to HWPX writer" do
    state = empty_state()

    assert {:ok, bin, content_type} =
             Contract.Export.Renderer.render(state, :hwpx, [])

    assert content_type == "application/hwp+zip"
    assert <<"PK", _::binary>> = bin
  end

  # --------------------------------------------------------------------------
  # 18. Unsupported format returns {:error, _}
  # --------------------------------------------------------------------------

  test "Renderer.render/3 returns {:error, ...} for unsupported formats" do
    # Wave 4 routes :pdf to Contract.Export.PDF; the unsupported-format
    # branch now only fires for genuinely unknown atoms.
    assert {:error, {:unsupported_format, :totally_made_up}} =
             Contract.Export.Renderer.render(empty_state(), :totally_made_up, [])
  end
end
