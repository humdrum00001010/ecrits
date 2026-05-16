defmodule Contract.Export.HWPX do
  @moduledoc """
  Hand-rolled HWPX (Hangul Word Processor XML / OWPML) writer.

  Takes a `Contract.Runtime.State` (or a bare projection map) and emits a
  valid HWPX file as a single binary. HWPX is the modern, XML-based open
  format that replaces the legacy binary `.hwp` and is the canonical
  Korean office document format used in court submissions and government
  filings.

  ## Output structure

  The result is a ZIP container with the following entries:

  * `mimetype` — STORED (uncompressed), first entry, content
    `application/hwp+zip`.
  * `version.xml` — `<hv:HCFVersion ...>` with `xmlVersion="1.4"`.
  * `META-INF/container.xml` — points to `Contents/content.hpf`.
  * `META-INF/manifest.xml` — minimal `<odf:manifest>`.
  * `Contents/content.hpf` — OPF package metadata + manifest + spine.
  * `Contents/header.xml` — fonts, charShapes, paraShapes, styles,
    borderFills, numbering.
  * `Contents/section0.xml` — the section body with `<hp:p>`, `<hp:run>`,
    `<hp:t>`, `<hp:tbl>` etc.
  * `settings.xml` — application settings (minimal).

  Layout, namespace declarations, and element shapes follow the reference
  fixtures in `neolord0/hwpxlib`
  (`testFile/tool/blank.hwpx`, `testFile/reader_writer/SimpleTable.hwpx`),
  which target OWPML 1.4 with the `2011` namespaces plus the `2016`
  extensions (`hp10`, `hwpunitchar`, `ooxmlchart`).

  ## Supported projection node kinds

  `:paragraph`, `:heading` (with `:attrs.level`), `:list`, `:list_item`,
  `:table` (with `:attrs.rows` + `:attrs.cols`), `:cell`, `:section`,
  `:field_ref` (with `:attrs.field_id`).

  ## Determinism

  Output is byte-deterministic: no timestamps, no random IDs, no
  per-invocation state. Two calls with the same projection produce
  identical bytes.

  ## Known limitations

  * Images, embedded OLE, footnotes, comments, and complex run-level
    styling (bold/italic/color spans inside a paragraph) are not
    emitted — TODOs marked in source.
  * Tables emit with default cellSz / borderFill — exact pixel sizing
    is not computed.
  * Fields render as inline plain text (the resolved value);
    `<hp:fieldBegin>`/`<hp:fieldEnd>` semantics are TODO.

  ## Hard constraints honored

  Pure Elixir. Only stdlib `:zip` and stdlib `:xmerl_scan` (in tests).
  No LibreOffice, no Pandoc, no Hancom subprocess.
  """

  alias Contract.Runtime.State

  @mimetype "application/hwp+zip"

  # The 2011 + 2016 namespace bundle used by the reference fixtures.
  # Emitted on the root of every XML so any descendant may use any prefix.
  @ns_attrs ~s( xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app") <>
              ~s( xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph") <>
              ~s( xmlns:hp10="http://www.hancom.co.kr/hwpml/2016/paragraph") <>
              ~s( xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section") <>
              ~s( xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core") <>
              ~s( xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head") <>
              ~s( xmlns:hhs="http://www.hancom.co.kr/hwpml/2011/history") <>
              ~s( xmlns:hm="http://www.hancom.co.kr/hwpml/2011/master-page") <>
              ~s( xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf") <>
              ~s( xmlns:dc="http://purl.org/dc/elements/1.1/") <>
              ~s( xmlns:opf="http://www.idpf.org/2007/opf/") <>
              ~s( xmlns:ooxmlchart="http://www.hancom.co.kr/hwpml/2016/ooxmlchart") <>
              ~s( xmlns:hwpunitchar="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar") <>
              ~s( xmlns:epub="http://www.idpf.org/2007/ops") <>
              ~s( xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0")

  # ---- paraShape IDs reserved for emission ----
  # Body paragraphs use 0; bullet list items use 1; headings use 2..7 (level 1..6).
  @body_para 0
  @bullet_para 1
  @heading_para_base 2

  # ---- charShape IDs ----
  # Body text uses 0; headings use 1..6 (level 1..6, bigger fonts).
  @body_char 0
  @heading_char_base 1

  @doc """
  Renders `state_or_projection` to a binary HWPX file.

  Accepts either a `%Contract.Runtime.State{}` struct or a bare projection
  map (the value of `state.projection`).

  Options are currently unused (reserved for future page-size / locale
  knobs).

  Returns `{:ok, binary}` on success. The binary is a complete ZIP
  container, suitable for writing to a `.hwpx` file or uploading via
  `Contract.IO.R2.put/3`.
  """
  @spec render(State.t() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(state_or_projection, _opts \\ [])

  def render(%State{projection: projection}, opts), do: render(projection, opts)

  def render(projection, _opts) when is_map(projection) do
    try do
      entries = build_entries(projection)
      {:ok, build_zip(entries)}
    rescue
      e -> {:error, {:hwpx_render_failed, Exception.message(e)}}
    end
  end

  # ---------------------------------------------------------------- entries

  defp build_entries(projection) do
    # The mimetype entry MUST be first and STORED (uncompressed). All other
    # entries are deflated. Order is preserved when iterating an Elixir list,
    # which is what :zip uses.
    [
      {~c"mimetype", @mimetype, :stored},
      {~c"version.xml", version_xml(), :deflated},
      {~c"META-INF/container.xml", container_xml(), :deflated},
      {~c"META-INF/manifest.xml", manifest_xml(), :deflated},
      {~c"Contents/content.hpf", content_hpf(projection), :deflated},
      {~c"Contents/header.xml", header_xml(), :deflated},
      {~c"Contents/section0.xml", section_xml(projection), :deflated},
      {~c"settings.xml", settings_xml(), :deflated}
    ]
  end

  # ---------------------------------------------------------------- ZIP build
  #
  # `:zip.create/3` accepts `[{name_charlist, binary}]` plus options. We need
  # the mimetype entry to be STORED while everything else is DEFLATED. The
  # cleanest portable way is to write the mimetype with `:zip.create/3`
  # using `{:uncompress, :all}` on a single-entry archive — but that flips
  # the wrong way. Instead we hand-roll a small per-entry compression
  # decision and assemble the central directory ourselves. Doing that is
  # ~100 lines and risks subtle bugs.
  #
  # An easier path: `:zip.create/3` with the `{:compress, {:add, [...]}}` /
  # `{:compress, {:remove, [...]}}` options. Per the Erlang docs the
  # `:compress` option accepts either `:all`, `:none`, or
  # `{:add, [Extension]}` / `{:remove, [Extension]}` lists of *extensions*.
  # The mimetype file has no extension, so we use
  # `[{:uncompress, [~c"mimetype"]}]`-style filtering via the suffix-based
  # `:compress` option won't work here.
  #
  # The lowest-risk option that the Erlang stdlib actually supports: use
  # `:zip.create/3` with `[:memory]` and the `{:compress, :all}` default,
  # then post-process the resulting bytes — repack the mimetype entry as
  # STORED via the `:zip_uncompress/2` of our own. That's still ugly.
  #
  # Cleanest: just emit ZIP bytes by hand. ZIP format is well-defined,
  # ~50 lines of code, and gives full control over compression flags. We
  # do that below.

  defp build_zip(entries) do
    {local_iodata, central_dir, total_local_size} =
      entries
      |> Enum.reduce({[], [], 0}, fn {name, body, mode}, {locals, centrals, offset} ->
        body_bin = IO.iodata_to_binary(body)
        {compressed, method} = compress_entry(body_bin, mode)
        crc = :erlang.crc32(body_bin)
        usize = byte_size(body_bin)
        csize = byte_size(compressed)

        local = local_file_header(name, method, crc, csize, usize) <> compressed
        central = central_file_header(name, method, crc, csize, usize, offset)

        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    local_bin = local_iodata |> Enum.reverse() |> IO.iodata_to_binary()
    central_bin = central_dir |> Enum.reverse() |> IO.iodata_to_binary()
    eocd = end_of_central_directory(length(entries), byte_size(central_bin), total_local_size)

    local_bin <> central_bin <> eocd
  end

  # Returns {compressed_bytes, method_code} where method is 0 (stored) or 8 (deflate).
  defp compress_entry(body, :stored), do: {body, 0}

  defp compress_entry(body, :deflated) do
    # Raw deflate (no zlib wrapper, no gzip wrapper).
    z = :zlib.open()

    try do
      # -15 → raw deflate, level 6 default. Use fixed level for determinism.
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      compressed = :zlib.deflate(z, body, :finish) |> IO.iodata_to_binary()
      :zlib.deflateEnd(z)
      {compressed, 8}
    after
      :zlib.close(z)
    end
  end

  # ZIP local file header (no extra field, no data descriptor).
  defp local_file_header(name, method, crc, csize, usize) do
    name_bin = IO.iodata_to_binary(name)

    <<
      0x04034B50::little-32,
      # version needed
      20::little-16,
      # general purpose bit flag (bit 11 = UTF-8 names)
      0x0800::little-16,
      method::little-16,
      # last mod time / date — fixed to 0 for determinism
      0::little-16,
      0::little-16,
      crc::little-32,
      csize::little-32,
      usize::little-32,
      byte_size(name_bin)::little-16,
      # extra field length
      0::little-16,
      name_bin::binary
    >>
  end

  defp central_file_header(name, method, crc, csize, usize, local_offset) do
    name_bin = IO.iodata_to_binary(name)

    <<
      0x02014B50::little-32,
      # version made by
      20::little-16,
      # version needed
      20::little-16,
      # general purpose bit flag (bit 11 = UTF-8 names)
      0x0800::little-16,
      method::little-16,
      0::little-16,
      0::little-16,
      crc::little-32,
      csize::little-32,
      usize::little-32,
      byte_size(name_bin)::little-16,
      0::little-16,
      0::little-16,
      0::little-16,
      0::little-16,
      0::little-32,
      local_offset::little-32,
      name_bin::binary
    >>
  end

  defp end_of_central_directory(n_entries, cd_size, cd_offset) do
    <<
      0x06054B50::little-32,
      0::little-16,
      0::little-16,
      n_entries::little-16,
      n_entries::little-16,
      cd_size::little-32,
      cd_offset::little-32,
      # comment length
      0::little-16
    >>
  end

  # ---------------------------------------------------------------- XML parts

  @xml_decl ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>)

  defp version_xml do
    @xml_decl <>
      ~s(<hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version") <>
      ~s( tagetApplication="WORDPROCESSOR" major="5" minor="0" micro="5") <>
      ~s( buildNumber="0" xmlVersion="1.4" application="Contract.Export.HWPX") <>
      ~s( appVersion="0.1.0"/>)
  end

  defp container_xml do
    @xml_decl <>
      ~s(<ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container") <>
      ~s( xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf">) <>
      ~s(<ocf:rootfiles>) <>
      ~s(<ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/>) <>
      ~s(</ocf:rootfiles>) <>
      ~s(</ocf:container>)
  end

  defp manifest_xml do
    @xml_decl <>
      ~s(<odf:manifest xmlns:odf="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"/>)
  end

  defp content_hpf(projection) do
    title = projection |> Map.get(:title) |> to_text() |> xml_escape()

    # Deterministic — no timestamps. The fixed dates below are calendar
    # zero; HWP viewers tolerate this and we keep render() pure.
    @xml_decl <>
      ~s(<opf:package) <>
      @ns_attrs <>
      ~s( version="" unique-identifier="" id="">) <>
      ~s(<opf:metadata>) <>
      ~s(<opf:title>) <>
      title <>
      ~s(</opf:title>) <>
      ~s(<opf:language>ko</opf:language>) <>
      ~s(<opf:meta name="creator" content="text"/>) <>
      ~s(<opf:meta name="CreatedDate" content="text">2000-01-01T00:00:00Z</opf:meta>) <>
      ~s(<opf:meta name="ModifiedDate" content="text">2000-01-01T00:00:00Z</opf:meta>) <>
      ~s(</opf:metadata>) <>
      ~s(<opf:manifest>) <>
      ~s(<opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>) <>
      ~s(<opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/>) <>
      ~s(<opf:item id="settings" href="settings.xml" media-type="application/xml"/>) <>
      ~s(</opf:manifest>) <>
      ~s(<opf:spine>) <>
      ~s(<opf:itemref idref="header"/>) <>
      ~s(<opf:itemref idref="section0"/>) <>
      ~s(</opf:spine>) <>
      ~s(</opf:package>)
  end

  defp settings_xml do
    @xml_decl <>
      ~s(<ha:HWPApplicationSetting xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app") <>
      ~s( xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0">) <>
      ~s(<ha:CaretPosition listIDRef="0" paraIDRef="0" pos="0"/>) <>
      ~s(</ha:HWPApplicationSetting>)
  end

  # -- header.xml: fontfaces + borderFills + charShapes + paraShapes + styles --

  defp header_xml do
    @xml_decl <>
      ~s(<hh:head) <>
      @ns_attrs <>
      ~s( version="1.4" secCnt="1">) <>
      ~s(<hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/>) <>
      ~s(<hh:refList>) <>
      fontfaces_xml() <>
      border_fills_xml() <>
      char_properties_xml() <>
      tab_properties_xml() <>
      numberings_xml() <>
      bullets_xml() <>
      para_properties_xml() <>
      styles_xml() <>
      ~s(</hh:refList>) <>
      ~s(<hh:compatibleDocument targetProgram="HWP201X"><hh:layoutCompatibility/></hh:compatibleDocument>) <>
      ~s(<hh:docOption><hh:linkinfo path="" pageInherit="0" footnoteInherit="0"/></hh:docOption>) <>
      ~s(</hh:head>)
  end

  # One <hh:fontface> per language slot, each with the same single font.
  defp fontfaces_xml do
    langs = ~w(HANGUL LATIN HANJA JAPANESE OTHER SYMBOL USER)

    inner =
      langs
      |> Enum.map(fn lang ->
        ~s(<hh:fontface lang="#{lang}" fontCnt="1">) <>
          ~s(<hh:font id="0" face="함초롬바탕" type="TTF" isEmbedded="0"/>) <>
          ~s(</hh:fontface>)
      end)
      |> Enum.join()

    ~s(<hh:fontfaces itemCnt="7">) <> inner <> ~s(</hh:fontfaces>)
  end

  defp border_fills_xml do
    cell = fn id ->
      ~s(<hh:borderFill id="#{id}" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">) <>
        ~s(<hh:slash type="NONE" Crooked="0" isCounter="0"/>) <>
        ~s(<hh:backSlash type="NONE" Crooked="0" isCounter="0"/>) <>
        ~s(<hh:leftBorder type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:rightBorder type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:topBorder type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:bottomBorder type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(</hh:borderFill>)
    end

    blank =
      ~s(<hh:borderFill id="1" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">) <>
        ~s(<hh:slash type="NONE" Crooked="0" isCounter="0"/>) <>
        ~s(<hh:backSlash type="NONE" Crooked="0" isCounter="0"/>) <>
        ~s(<hh:leftBorder type="NONE" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:rightBorder type="NONE" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:topBorder type="NONE" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:bottomBorder type="NONE" width="0.1 mm" color="#000000"/>) <>
        ~s(<hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/>) <>
        ~s(</hh:borderFill>)

    # id=1 → page border (no edges), id=2 → default cell border, id=3 → table cell border.
    ~s(<hh:borderFills itemCnt="3">) <> blank <> cell.(2) <> cell.(3) <> ~s(</hh:borderFills>)
  end

  # charShape 0..6 covering body + headings level 1..6.
  defp char_properties_xml do
    base = fn id, height ->
      ~s(<hh:charPr id="#{id}" height="#{height}" textColor="#000000" shadeColor="none") <>
        ~s( useFontSpace="0" useKerning="0" symMark="NONE" borderFillIDRef="2">) <>
        ~s(<hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>) <>
        ~s(<hh:ratio hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/>) <>
        ~s(<hh:spacing hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>) <>
        ~s(<hh:relSz hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/>) <>
        ~s(<hh:offset hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>) <>
        ~s(<hh:underline type="NONE" shape="SOLID" color="#000000"/>) <>
        ~s(<hh:strikeout shape="NONE" color="#000000"/>) <>
        ~s(<hh:outline type="NONE"/>) <>
        ~s(<hh:shadow type="NONE" color="#B2B2B2" offsetX="10" offsetY="10"/>) <>
        ~s(</hh:charPr>)
    end

    # heights in 1/100 pt. body=10pt=1000; h6=11=1100 .. h1=22=2200.
    heights = [{0, 1000}, {1, 2200}, {2, 1800}, {3, 1500}, {4, 1300}, {5, 1200}, {6, 1100}]

    inner = heights |> Enum.map(fn {id, h} -> base.(id, h) end) |> Enum.join()

    ~s(<hh:charProperties itemCnt="#{length(heights)}">) <> inner <> ~s(</hh:charProperties>)
  end

  defp tab_properties_xml do
    ~s(<hh:tabProperties itemCnt="1">) <>
      ~s(<hh:tabPr id="0" autoTabLeft="0" autoTabRight="0"/>) <>
      ~s(</hh:tabProperties>)
  end

  defp numberings_xml do
    ~s(<hh:numberings itemCnt="1">) <>
      ~s(<hh:numbering id="1" start="0">) <>
      ~s(<hh:paraHead start="1" level="1" align="LEFT" useInstWidth="1" autoIndent="1") <>
      ~s( widthAdjust="0" textOffsetType="PERCENT" textOffset="50" numFormat="DIGIT") <>
      ~s( charPrIDRef="4294967295" checkable="0">^1.</hh:paraHead>) <>
      ~s(</hh:numbering>) <>
      ~s(</hh:numberings>)
  end

  defp bullets_xml do
    # One simple bullet entry referenced by the bullet paraShape (id=1).
    ~s(<hh:bullets itemCnt="1">) <>
      ~s(<hh:bullet id="1" char="•" checkable="0"/>) <>
      ~s(</hh:bullets>)
  end

  defp para_properties_xml do
    base = fn id, align, heading_type, heading_level, intent, left_margin ->
      ~s(<hh:paraPr id="#{id}" tabPrIDRef="0" condense="0" fontLineHeight="0") <>
        ~s( snapToGrid="1" suppressLineNumbers="0" checked="0">) <>
        ~s(<hh:align horizontal="#{align}" vertical="BASELINE"/>) <>
        ~s(<hh:heading type="#{heading_type}" idRef="0" level="#{heading_level}"/>) <>
        ~s(<hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="BREAK_WORD") <>
        ~s( widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/>) <>
        ~s(<hh:margin>) <>
        ~s(<hc:intent value="#{intent}" unit="HWPUNIT"/>) <>
        ~s(<hc:left value="#{left_margin}" unit="HWPUNIT"/>) <>
        ~s(<hc:right value="0" unit="HWPUNIT"/>) <>
        ~s(<hc:prev value="0" unit="HWPUNIT"/>) <>
        ~s(<hc:next value="0" unit="HWPUNIT"/>) <>
        ~s(</hh:margin>) <>
        ~s(<hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/>) <>
        ~s(<hh:autoSpacing eAsianEng="0" eAsianNum="0"/>) <>
        ~s(<hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0") <>
        ~s( offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/>) <>
        ~s(</hh:paraPr>)
    end

    # 0 → body, 1 → bullet (left-indented), 2..7 → headings level 1..6 (OUTLINE).
    rows = [
      {@body_para, "JUSTIFY", "NONE", 0, 0, 0},
      {@bullet_para, "LEFT", "NONE", 0, 0, 1000},
      {@heading_para_base + 0, "LEFT", "OUTLINE", 1, 0, 0},
      {@heading_para_base + 1, "LEFT", "OUTLINE", 2, 0, 0},
      {@heading_para_base + 2, "LEFT", "OUTLINE", 3, 0, 0},
      {@heading_para_base + 3, "LEFT", "OUTLINE", 4, 0, 0},
      {@heading_para_base + 4, "LEFT", "OUTLINE", 5, 0, 0},
      {@heading_para_base + 5, "LEFT", "OUTLINE", 6, 0, 0}
    ]

    inner =
      rows
      |> Enum.map(fn {id, align, htype, hlevel, intent, left} ->
        base.(id, align, htype, hlevel, intent, left)
      end)
      |> Enum.join()

    ~s(<hh:paraProperties itemCnt="#{length(rows)}">) <> inner <> ~s(</hh:paraProperties>)
  end

  defp styles_xml do
    # Style 0 = body. Styles 1..6 = heading levels (we don't reference these
    # from <hp:p> directly; <hp:p> uses paraPrIDRef + charPrIDRef. Styles
    # exist so viewers see a registered style list.)
    body =
      ~s(<hh:style id="0" type="PARA" name="바탕글" engName="Normal") <>
        ~s( paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/>)

    headings =
      1..6
      |> Enum.map(fn level ->
        ~s(<hh:style id="#{level}" type="PARA" name="제목 #{level}" engName="Heading #{level}") <>
          ~s( paraPrIDRef="#{@heading_para_base + level - 1}") <>
          ~s( charPrIDRef="#{@heading_char_base + level - 1}") <>
          ~s( nextStyleIDRef="0" langID="1042" lockForm="0"/>)
      end)
      |> Enum.join()

    bullet =
      ~s(<hh:style id="7" type="PARA" name="목록" engName="List") <>
        ~s( paraPrIDRef="#{@bullet_para}" charPrIDRef="0") <>
        ~s( nextStyleIDRef="7" langID="1042" lockForm="0"/>)

    ~s(<hh:styles itemCnt="8">) <> body <> headings <> bullet <> ~s(</hh:styles>)
  end

  # -------------------------------------------------------- section0.xml

  defp section_xml(projection) do
    nodes = Map.get(projection, :nodes, %{})
    order = Map.get(projection, :node_order, [])

    body =
      cond do
        order == [] ->
          # Empty projection — emit one default paragraph holding the secPr.
          paragraph_with_secpr("", @body_para, @body_char)

        true ->
          # First top-level paragraph carries the secPr; remaining nodes follow.
          [first | rest] = order

          first_xml = render_node_with_secpr(first, nodes, projection)
          rest_xml = rest |> Enum.map(&render_node(&1, nodes, projection)) |> Enum.join()
          first_xml <> rest_xml
      end

    @xml_decl <>
      ~s(<hs:sec) <>
      @ns_attrs <>
      ~s(>) <>
      body <>
      ~s(</hs:sec>)
  end

  # Render the *first* top-level node, ensuring whatever it emits begins
  # with a <hp:p> that carries a <hp:secPr>. For non-paragraph kinds (e.g.
  # table) we prepend an empty paragraph with the secPr.
  defp render_node_with_secpr(id, nodes, projection) do
    node = Map.fetch!(nodes, id)
    kind = Map.get(node, :kind, :paragraph)

    case kind do
      k when k in [:paragraph, :heading, :section] ->
        # Replace its <hp:p> with a secPr-bearing one.
        text = collect_text(node, projection)
        {para_id, char_id} = shape_ids_for(node)
        paragraph_with_secpr(text, para_id, char_id)

      _ ->
        # Tables / lists / cells: emit secPr-carrying empty paragraph, then the node.
        paragraph_with_secpr("", @body_para, @body_char) <>
          render_node(id, nodes, projection)
    end
  end

  defp render_node(id, nodes, projection) do
    case Map.fetch(nodes, id) do
      :error ->
        ""

      {:ok, node} ->
        render_kind(Map.get(node, :kind, :paragraph), node, nodes, projection)
    end
  end

  defp render_kind(:paragraph, node, _nodes, projection) do
    text = collect_text(node, projection)
    paragraph(text, @body_para, @body_char)
  end

  defp render_kind(:heading, node, _nodes, projection) do
    text = collect_text(node, projection)
    {para_id, char_id} = shape_ids_for(node)
    paragraph(text, para_id, char_id)
  end

  defp render_kind(:list, node, nodes, projection) do
    # Emit children as bullet-styled paragraphs. If a list_item has no
    # children, its content is the bullet text.
    Map.get(node, :children, [])
    |> Enum.map(&render_list_item(&1, nodes, projection))
    |> Enum.join()
  end

  defp render_kind(:list_item, node, _nodes, projection) do
    # If called directly (not via :list), render as bullet paragraph.
    text = collect_text(node, projection)
    paragraph(text, @bullet_para, @body_char)
  end

  defp render_kind(:table, node, nodes, projection) do
    rows = Map.get(node, :attrs, %{}) |> Map.get(:rows) || infer_table_dims(node, nodes).rows
    cols = Map.get(node, :attrs, %{}) |> Map.get(:cols) || infer_table_dims(node, nodes).cols
    table_xml(node, nodes, projection, rows, cols)
  end

  defp render_kind(:cell, _node, _nodes, _projection) do
    # Cells are emitted from inside table_xml; a bare :cell at top level
    # produces nothing (it's a structural error to have one outside a table).
    ""
  end

  defp render_kind(:section, _node, _nodes, _projection) do
    # Sections collapse to a paragraph break for now. A proper section
    # boundary requires a fresh <hp:secPr>; that's a TODO.
    paragraph("", @body_para, @body_char)
  end

  defp render_kind(:field_ref, node, _nodes, projection) do
    # field_ref nodes resolve their value via projection.fields[field_id]
    # (using attrs.field_id) and emit as plain text in a paragraph.
    text = resolve_field_text(node, projection)
    paragraph(text, @body_para, @body_char)
  end

  defp render_kind(_other_kind, node, _nodes, projection) do
    # Unknown kinds → fall back to a paragraph with the content (if any).
    # This honors SPEC.md §15: node kinds are opaque atoms.
    text = collect_text(node, projection)
    paragraph(text, @body_para, @body_char)
  end

  defp render_list_item(child_id, nodes, projection) do
    case Map.fetch(nodes, child_id) do
      {:ok, child} ->
        text = collect_text(child, projection)
        paragraph(text, @bullet_para, @body_char)

      :error ->
        ""
    end
  end

  defp infer_table_dims(node, nodes) do
    # Fallback: count immediate :cell children and arrange in a square-ish grid.
    cell_count =
      Map.get(node, :children, [])
      |> Enum.count(fn cid ->
        case Map.fetch(nodes, cid) do
          {:ok, c} -> Map.get(c, :kind) == :cell
          :error -> false
        end
      end)

    if cell_count == 0 do
      %{rows: 1, cols: 1}
    else
      cols = max(1, trunc(:math.sqrt(cell_count)))
      rows = div(cell_count + cols - 1, cols)
      %{rows: rows, cols: cols}
    end
  end

  defp table_xml(node, nodes, projection, rows, cols) do
    cell_ids = Map.get(node, :children, [])
    cell_chunks = Enum.chunk_every(cell_ids, cols, cols, [])

    # Pad to exactly `rows` rows.
    padded_rows =
      cell_chunks
      |> Enum.take(rows)
      |> Kernel.++(List.duplicate([], max(0, rows - length(cell_chunks))))

    attrs = Map.get(node, :attrs, %{}) || %{}
    column_widths = Map.get(attrs, :column_widths) || Map.get(attrs, "column_widths") || []
    table_border = Map.get(attrs, :border_fill_id) || Map.get(attrs, "border_fill_id") || "3"

    rows_xml =
      padded_rows
      |> Enum.with_index()
      |> Enum.map(fn {row_cells, row_idx} ->
        # Pad row to `cols` cells with nil placeholders.
        padded = row_cells ++ List.duplicate(nil, max(0, cols - length(row_cells)))

        cells_xml =
          padded
          |> Enum.take(cols)
          |> Enum.with_index()
          |> Enum.map(fn {cell_id, col_idx} ->
            cell_node =
              case cell_id do
                nil -> nil
                id -> Map.get(nodes, id)
              end

            cell_text =
              case cell_node do
                nil -> ""
                node -> collect_text(node, projection)
              end

            width = column_width_at(column_widths, col_idx)
            tc_xml(cell_text, cell_node, row_idx, col_idx, width, table_border)
          end)
          |> Enum.join()

        ~s(<hp:tr>) <> cells_xml <> ~s(</hp:tr>)
      end)
      |> Enum.join()

    tbl =
      ~s(<hp:tbl id="0" zOrder="0" numberingType="TABLE" textWrap="TOP_AND_BOTTOM") <>
        ~s( textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" pageBreak="CELL") <>
        ~s( repeatHeader="1" rowCnt="#{rows}" colCnt="#{cols}" cellSpacing="0") <>
        ~s( borderFillIDRef="#{table_border}" noAdjust="0">) <>
        ~s(<hp:sz width="40000" widthRelTo="ABSOLUTE" height="5000" heightRelTo="ABSOLUTE" protect="0"/>) <>
        ~s(<hp:pos treatAsChar="0" affectLSpacing="0" flowWithText="1" allowOverlap="0") <>
        ~s( holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP") <>
        ~s( horzAlign="LEFT" vertOffset="0" horzOffset="0"/>) <>
        ~s(<hp:outMargin left="283" right="283" top="283" bottom="283"/>) <>
        ~s(<hp:inMargin left="510" right="510" top="141" bottom="141"/>) <>
        rows_xml <>
        ~s(</hp:tbl>)

    # HWPX requires tables to live inside a paragraph.
    ~s(<hp:p id="0" paraPrIDRef="#{@body_para}" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">) <>
      ~s(<hp:run charPrIDRef="#{@body_char}">) <>
      tbl <>
      ~s(<hp:t/>) <>
      ~s(</hp:run>) <>
      ~s(</hp:p>)
  end

  # Pick the width for the col at `col_idx` from the supplied list, or fall
  # back to the legacy default of 6000 HWP units (~60 mm) when absent.
  defp column_width_at([], _idx), do: 6000

  defp column_width_at(widths, idx) when is_list(widths) do
    case Enum.at(widths, idx) do
      n when is_integer(n) and n > 0 -> n
      _ -> 6000
    end
  end

  defp tc_xml(text, cell_node, row_idx, col_idx, width, table_border) do
    cell_attrs = (cell_node && (Map.get(cell_node, :attrs) || %{})) || %{}

    border_fill =
      Map.get(cell_attrs, :border_fill_id) || Map.get(cell_attrs, "border_fill_id") ||
        table_border

    row_span = Map.get(cell_attrs, :row_span) || Map.get(cell_attrs, "row_span") || 1
    col_span = Map.get(cell_attrs, :col_span) || Map.get(cell_attrs, "col_span") || 1

    vert_align =
      case Map.get(cell_attrs, :vertical_alignment) || Map.get(cell_attrs, "vertical_alignment") do
        :top -> "TOP"
        :center -> "CENTER"
        :bottom -> "BOTTOM"
        "top" -> "TOP"
        "center" -> "CENTER"
        "bottom" -> "BOTTOM"
        _ -> "CENTER"
      end

    pad_left =
      Map.get(cell_attrs, :padding_left) || Map.get(cell_attrs, "padding_left") || 510

    pad_right =
      Map.get(cell_attrs, :padding_right) || Map.get(cell_attrs, "padding_right") || 510

    pad_top = Map.get(cell_attrs, :padding_top) || Map.get(cell_attrs, "padding_top") || 141

    pad_bottom =
      Map.get(cell_attrs, :padding_bottom) || Map.get(cell_attrs, "padding_bottom") || 141

    inner_para = paragraph(text, @body_para, @body_char)

    ~s(<hp:tc name="" header="0" hasMargin="0" protect="0" editable="0" dirty="0" borderFillIDRef="#{border_fill}">) <>
      ~s(<hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="#{vert_align}") <>
      ~s( linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0") <>
      ~s( hasTextRef="0" hasNumRef="0">) <>
      inner_para <>
      ~s(</hp:subList>) <>
      ~s(<hp:cellAddr colAddr="#{col_idx}" rowAddr="#{row_idx}"/>) <>
      ~s(<hp:cellSpan colSpan="#{col_span}" rowSpan="#{row_span}"/>) <>
      ~s(<hp:cellSz width="#{width}" height="2500"/>) <>
      ~s(<hp:cellMargin left="#{pad_left}" right="#{pad_right}" top="#{pad_top}" bottom="#{pad_bottom}"/>) <>
      ~s(</hp:tc>)
  end

  # ---------------------- paragraph primitives ---------------------------

  # A minimal but complete <hp:p> with <hp:run><hp:t>text</hp:t></hp:run>.
  defp paragraph(text, para_id, char_id) do
    safe = xml_escape(text)

    ~s(<hp:p id="0" paraPrIDRef="#{para_id}" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">) <>
      ~s(<hp:run charPrIDRef="#{char_id}">) <>
      ~s(<hp:t>) <>
      safe <>
      ~s(</hp:t>) <>
      ~s(</hp:run>) <>
      ~s(</hp:p>)
  end

  # Same as paragraph/3 but inserts a <hp:secPr> before the <hp:t>.
  defp paragraph_with_secpr(text, para_id, char_id) do
    safe = xml_escape(text)

    ~s(<hp:p id="0" paraPrIDRef="#{para_id}" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">) <>
      ~s(<hp:run charPrIDRef="#{char_id}">) <>
      sec_pr_xml() <>
      ~s(<hp:ctrl><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="1" sameSz="1" sameGap="0"/></hp:ctrl>) <>
      ~s(<hp:t>) <>
      safe <>
      ~s(</hp:t>) <>
      ~s(</hp:run>) <>
      ~s(</hp:p>)
  end

  defp sec_pr_xml do
    ~s(<hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="1134" tabStop="8000") <>
      ~s( tabStopVal="4000" tabStopUnit="HWPUNIT" outlineShapeIDRef="0") <>
      ~s( memoShapeIDRef="0" textVerticalWidthHead="0" masterPageCnt="0">) <>
      ~s(<hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/>) <>
      ~s(<hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/>) <>
      ~s(<hp:visibility hideFirstHeader="0" hideFirstFooter="0" hideFirstMasterPage="0") <>
      ~s( border="SHOW_ALL" fill="SHOW_ALL" hideFirstPageNum="0" hideFirstEmptyLine="0" showLineNumber="0"/>) <>
      ~s(<hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/>) <>
      ~s(<hp:pagePr landscape="WIDELY" width="59528" height="84188" gutterType="LEFT_ONLY">) <>
      ~s(<hp:margin header="4252" footer="4252" gutter="0" left="8504" right="8504" top="5668" bottom="4252"/>) <>
      ~s(</hp:pagePr>) <>
      ~s(<hp:footNotePr>) <>
      ~s[<hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/>] <>
      ~s(<hp:noteLine length="-1" type="SOLID" width="0.12 mm" color="#000000"/>) <>
      ~s(<hp:noteSpacing betweenNotes="283" belowLine="567" aboveLine="850"/>) <>
      ~s(<hp:numbering type="CONTINUOUS" newNum="1"/>) <>
      ~s(<hp:placement place="EACH_COLUMN" beneathText="0"/>) <>
      ~s(</hp:footNotePr>) <>
      ~s(<hp:endNotePr>) <>
      ~s[<hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/>] <>
      ~s(<hp:noteLine length="14692344" type="SOLID" width="0.12 mm" color="#000000"/>) <>
      ~s(<hp:noteSpacing betweenNotes="0" belowLine="567" aboveLine="850"/>) <>
      ~s(<hp:numbering type="CONTINUOUS" newNum="1"/>) <>
      ~s(<hp:placement place="END_OF_DOCUMENT" beneathText="0"/>) <>
      ~s(</hp:endNotePr>) <>
      ~s(</hp:secPr>)
  end

  # --------------------------- helpers -----------------------------------

  # Pick the (paraShapeID, charShapeID) pair for a node based on kind + level.
  defp shape_ids_for(%{kind: :heading} = node) do
    level = node |> Map.get(:attrs, %{}) |> Map.get(:level, 1)
    level = level |> clamp(1, 6)
    {@heading_para_base + level - 1, @heading_char_base + level - 1}
  end

  defp shape_ids_for(_), do: {@body_para, @body_char}

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _), do: lo

  # Collect display text for a node:
  #   * direct :content if present
  #   * else resolved field text for :field_ref
  #   * else "" (children render themselves separately)
  defp collect_text(%{kind: :field_ref} = node, projection) do
    resolve_field_text(node, projection)
  end

  defp collect_text(node, _projection) do
    node |> Map.get(:content) |> to_text()
  end

  defp resolve_field_text(node, projection) do
    field_id = node |> Map.get(:attrs, %{}) |> Map.get(:field_id)

    case field_id do
      nil ->
        ""

      id ->
        projection
        |> Map.get(:fields, %{})
        |> Map.get(id, %{})
        |> Map.get(:value)
        |> to_text()
    end
  end

  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(other), do: to_string(other)

  # XML text escape. Only the five standard predefined entities — HWPX
  # readers expect strict XML 1.0.
  defp xml_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
