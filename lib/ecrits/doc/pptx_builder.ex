defmodule Ecrits.Doc.PptxBuilder do
  @moduledoc false

  @emu_per_inch 914_400
  @slide_cx 12_192_000
  @slide_cy 6_858_000

  @blue "2563EB"
  @navy "111827"
  @cyan "0EA5E9"
  @green "10B981"
  @orange "F59E0B"
  @slate "334155"
  @muted "64748B"
  @border "CBD5E1"
  @paper "F8FAFC"
  @white "FFFFFF"

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, deck) when is_binary(path) and is_map(deck) do
    slides = normalize_slides(deck)
    files = files(deck, slides)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, {_name, zip}} <-
           :zip.create(String.to_charlist(Path.basename(path)), files, [:memory]) do
      File.write(path, zip)
    end
  end

  defp files(deck, slides) do
    slide_count = length(slides)

    base_files = [
      {"[Content_Types].xml", content_types(slide_count)},
      {"_rels/.rels", root_rels()},
      {"docProps/app.xml", app_props(slide_count)},
      {"docProps/core.xml", core_props(deck)},
      {"ppt/presentation.xml", presentation(slide_count)},
      {"ppt/_rels/presentation.xml.rels", presentation_rels(slide_count)},
      {"ppt/slideMasters/slideMaster1.xml", slide_master()},
      {"ppt/slideMasters/_rels/slideMaster1.xml.rels", slide_master_rels()},
      {"ppt/slideLayouts/slideLayout1.xml", slide_layout()},
      {"ppt/slideLayouts/_rels/slideLayout1.xml.rels", slide_layout_rels()},
      {"ppt/theme/theme1.xml", theme()}
    ]

    slide_files =
      slides
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {slide, index} ->
        [
          {"ppt/slides/slide#{index}.xml", slide_xml(slide, index, slide_count)},
          {"ppt/slides/_rels/slide#{index}.xml.rels", slide_rels()}
        ]
      end)

    (base_files ++ slide_files)
    |> Enum.map(fn {name, body} -> {String.to_charlist(name), body} end)
  end

  defp normalize_slides(deck) do
    slides =
      deck
      |> map_get("slides", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    if slides == [] do
      default_slides(deck)
    else
      Enum.take(slides, 12)
    end
  end

  defp default_slides(deck) do
    title = text_value(map_get(deck, "title", "FinMate AI"))
    subtitle = text_value(map_get(deck, "subtitle", "AI financial copilot MVP"))

    [
      %{
        "title" => title,
        "subtitle" => subtitle,
        "section" => "Overview",
        "metrics" => [
          %{"label" => "Prep time", "value" => "30%", "delta" => "down"},
          %{"label" => "Recommendation lift", "value" => "18%", "delta" => "up"},
          %{"label" => "Risk detection", "value" => "2.4x", "delta" => "lift"}
        ]
      },
      %{
        "title" => "Problem",
        "subtitle" => "Finance workflows need faster context, explainability, and follow-up.",
        "cards" => [
          %{"title" => "Scattered context", "body" => "Customer data lives across systems."},
          %{
            "title" => "Weak explanations",
            "body" => "Advisors need visible recommendation reasons."
          },
          %{
            "title" => "Missed follow-up",
            "body" => "Risk changes are not connected to next actions."
          }
        ]
      },
      %{
        "title" => "Solution",
        "subtitle" => "One flow turns raw financial context into an actionable plan.",
        "roadmap" => ["Collect", "Summarize", "Recommend", "Explain", "Follow up"]
      },
      %{
        "title" => "Impact",
        "subtitle" => "A six-week MVP can prove measurable advisor productivity.",
        "metrics" => [
          %{"label" => "MVP", "value" => "6 weeks", "delta" => "plan"},
          %{"label" => "Coverage", "value" => "3 journeys", "delta" => "scope"},
          %{"label" => "Pilot", "value" => "50 users", "delta" => "target"}
        ],
        "roadmap" => ["Week 1", "Week 2", "Week 4", "Week 6"]
      }
    ]
  end

  defp slide_xml(slide, index, slide_count) do
    shapes =
      [
        background(),
        footer(index, slide_count)
      ] ++ slide_content(slide, index)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:cSld>
        <p:spTree>
          <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
          <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
          #{Enum.join(Enum.with_index(shapes, 2) |> Enum.map(fn {shape, id} -> shape.(id) end), "\n")}
        </p:spTree>
      </p:cSld>
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
    </p:sld>
    """
  end

  defp slide_content(slide, index) do
    case rem(index - 1, 4) do
      0 -> cover_slide(slide)
      1 -> card_slide(slide)
      2 -> flow_slide(slide)
      _ -> impact_slide(slide)
    end
  end

  defp cover_slide(slide) do
    title = text_value(map_get(slide, "title", "Untitled deck"))
    subtitle = text_value(map_get(slide, "subtitle", ""))
    section = text_value(map_get(slide, "section", "Pitch deck"))
    metrics = metrics(slide)
    title_block = text_block(title, 30, 3)
    subtitle_block = text_block(subtitle, 46, 4)
    title_lines = max(1, line_count(title_block))
    subtitle_lines = line_count(subtitle_block)
    title_font = cover_title_font(title_block, title_lines)
    title_height = 0.55 * title_lines + 0.22
    subtitle_y = 1.35 + title_height + 0.22
    subtitle_height = max(0.45, 0.27 * subtitle_lines + 0.16)
    keyline_y = subtitle_y + subtitle_height + 0.28

    base = [
      rect(0.7, 0.55, 1.7, 0.42, @blue, nil, 0.12, section, 12, @white, true),
      textbox(0.75, 1.35, 5.8, title_height, title_block, title_font, @navy, true),
      textbox(0.78, subtitle_y, 5.45, subtitle_height, subtitle_block, 13, @slate, false),
      textbox(0.78, keyline_y, 4.7, 0.35, "Problem - Insight - Action", 18, @blue, true),
      rect(7.25, 0.85, 4.35, 5.7, @navy, nil, 0.35, nil, 12, @white, false),
      textbox(7.78, 1.32, 3.25, 0.36, "AI copilot", 17, @white, true)
    ]

    metric_shapes =
      metrics
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.flat_map(fn {metric, i} ->
        y = 2.38 + i * 1.12
        color = Enum.at([@cyan, @green, @orange], i)

        [
          rect(7.75, y, 2.9, 0.92, @white, @border, 0.14, nil, 12, @navy, false),
          textbox(8.02, y + 0.14, 2.2, 0.24, metric.label, 10, @muted, true),
          textbox(8.02, y + 0.41, 1.9, 0.4, metric.value, 26, color, true)
        ]
      end)

    base ++ metric_shapes
  end

  defp card_slide(slide) do
    title = text_value(map_get(slide, "title", "Key points"))
    subtitle = text_value(map_get(slide, "subtitle", ""))
    cards = cards(slide)
    title_block = text_block(title, 42, 2)
    subtitle_block = text_block(subtitle, 62, 2)
    title_lines = max(1, line_count(title_block))
    subtitle_lines = line_count(subtitle_block)
    title_font = slide_title_font(title_block, title_lines)
    title_height = 0.43 * title_lines + 0.18
    subtitle_y = 0.6 + title_height + 0.12
    subtitle_height = max(0.32, 0.24 * subtitle_lines + 0.12)

    base = [
      rect(
        0.65,
        0.55,
        0.12,
        max(0.72, title_height + subtitle_height + 0.28),
        @blue,
        nil,
        0.02,
        nil,
        12,
        @white,
        false
      ),
      textbox(0.92, 0.6, 7.2, title_height, title_block, title_font, @navy, true),
      textbox(0.94, subtitle_y, 7.7, subtitle_height, subtitle_block, 14, @muted, false)
    ]

    card_shapes =
      cards
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.flat_map(fn {card, i} ->
        x = 0.78 + i * 3.75
        y = 2.6
        accent = Enum.at([@blue, @green, @orange], i)

        [
          rect(x, y, 3.25, 2.75, @white, @border, 0.13, nil, 12, @navy, false),
          rect(x, y, 3.25, 0.12, accent, nil, 0.03, nil, 12, @white, false),
          textbox(x + 0.28, y + 0.33, 2.55, 0.42, card.title, 18, @navy, true),
          textbox(x + 0.28, y + 1.0, 2.5, 1.25, card.body, 13, @slate, false)
        ]
      end)

    base ++ card_shapes
  end

  defp flow_slide(slide) do
    title = text_value(map_get(slide, "title", "Flow"))
    subtitle = text_value(map_get(slide, "subtitle", ""))
    steps = roadmap(slide)
    title_block = text_block(title, 42, 2)
    subtitle_block = text_block(subtitle, 64, 2)
    title_lines = max(1, line_count(title_block))
    subtitle_lines = line_count(subtitle_block)
    title_font = slide_title_font(title_block, title_lines)
    title_height = 0.43 * title_lines + 0.18
    subtitle_y = 0.58 + title_height + 0.12
    subtitle_height = max(0.32, 0.24 * subtitle_lines + 0.12)

    base = [
      textbox(0.72, 0.58, 7.4, title_height, title_block, title_font, @navy, true),
      textbox(0.74, subtitle_y, 8.1, subtitle_height, subtitle_block, 14, @muted, false),
      rect(0.78, 3.55, 10.8, 0.04, @border, nil, 0.0, nil, 12, @white, false)
    ]

    step_shapes =
      steps
      |> Enum.take(5)
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        x = 0.82 + i * 2.17
        color = Enum.at([@blue, @cyan, @green, @orange, @navy], i)

        [
          rect(x, 2.7, 1.55, 1.45, @white, @border, 0.16, nil, 12, @navy, false),
          rect(x + 0.48, 2.47, 0.58, 0.58, color, nil, 0.29, "#{i + 1}", 15, @white, true),
          textbox(x + 0.2, 3.35, 1.15, 0.35, text_value(step), 14, @navy, true)
        ]
      end)

    base ++ step_shapes
  end

  defp impact_slide(slide) do
    title = text_value(map_get(slide, "title", "Impact"))
    subtitle = text_value(map_get(slide, "subtitle", ""))
    metrics = metrics(slide)
    steps = roadmap(slide)
    title_block = text_block(title, 42, 2)
    subtitle_block = text_block(subtitle, 64, 2)
    title_lines = max(1, line_count(title_block))
    subtitle_lines = line_count(subtitle_block)
    title_font = slide_title_font(title_block, title_lines)
    title_height = 0.43 * title_lines + 0.18
    subtitle_y = 0.58 + title_height + 0.12
    subtitle_height = max(0.32, 0.24 * subtitle_lines + 0.12)

    base = [
      textbox(0.72, 0.58, 7.4, title_height, title_block, title_font, @navy, true),
      textbox(0.74, subtitle_y, 8.0, subtitle_height, subtitle_block, 14, @muted, false)
    ]

    metric_shapes =
      metrics
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.flat_map(fn {metric, i} ->
        x = 0.8 + i * 3.55
        y = 2.45
        color = Enum.at([@blue, @green, @orange], i)
        value = text_block(metric.value, 13, 2)

        [
          rect(x, y, 3.05, 1.5, @white, @border, 0.14, nil, 12, @navy, false),
          textbox(x + 0.28, y + 0.28, 2.45, 0.34, metric.label, 11, @muted, true),
          textbox(x + 0.28, y + 0.72, 2.55, 0.58, value, 23, color, true)
        ]
      end)

    roadmap_base = [
      rect(0.82, 4.82, 10.45, 0.06, @border, nil, 0.0, nil, 12, @white, false)
    ]

    step_shapes =
      steps
      |> Enum.take(4)
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        x = 0.88 + i * 2.85
        step_text = text_block(step, 22, 6)

        [
          rect(x, 4.58, 0.48, 0.48, @blue, nil, 0.24, nil, 12, @white, false),
          textbox(x - 0.1, 5.25, 2.28, 1.45, step_text, 8, @navy, true)
        ]
      end)

    base ++ metric_shapes ++ roadmap_base ++ step_shapes
  end

  defp background do
    rect(0, 0, 13.333, 7.5, @paper, nil, 0, nil, 12, @navy, false)
  end

  defp footer(index, slide_count) do
    fn id ->
      shape_xml(id, "Footer", inch(0.75), inch(7.02), inch(11.7), inch(0.25),
        fill: nil,
        line: nil,
        radius: nil,
        text: "#{index} / #{slide_count}",
        font_size: 9,
        font_color: @muted,
        bold: false,
        align: "r"
      )
    end
  end

  defp rect(x, y, w, h, fill, line, radius, text, font_size, font_color, bold) do
    fn id ->
      shape_xml(id, "Shape #{id}", inch(x), inch(y), inch(w), inch(h),
        fill: fill,
        line: line,
        radius: radius,
        text: text,
        font_size: font_size,
        font_color: font_color,
        bold: bold
      )
    end
  end

  defp textbox(x, y, w, h, text, font_size, font_color, bold) do
    fn id ->
      shape_xml(id, "Text #{id}", inch(x), inch(y), inch(w), inch(h),
        fill: nil,
        line: nil,
        radius: nil,
        text: text,
        font_size: font_size,
        font_color: font_color,
        bold: bold
      )
    end
  end

  defp shape_xml(id, name, x, y, w, h, opts) do
    fill = Keyword.get(opts, :fill)
    line = Keyword.get(opts, :line)
    radius = Keyword.get(opts, :radius)
    text = Keyword.get(opts, :text)
    font_size = Keyword.get(opts, :font_size, 12)
    font_color = Keyword.get(opts, :font_color, @navy)
    bold = Keyword.get(opts, :bold, false)
    align = Keyword.get(opts, :align, "l")
    geom = if radius && radius > 0, do: "roundRect", else: "rect"

    """
    <p:sp>
      <p:nvSpPr><p:cNvPr id="#{id}" name="#{xml(name)}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>
        <a:xfrm><a:off x="#{x}" y="#{y}"/><a:ext cx="#{w}" cy="#{h}"/></a:xfrm>
        <a:prstGeom prst="#{geom}"><a:avLst/></a:prstGeom>
        #{fill_xml(fill)}
        #{line_xml(line)}
      </p:spPr>
      #{text_body(text, font_size, font_color, bold, align)}
    </p:sp>
    """
  end

  defp text_body(nil, _font_size, _font_color, _bold, _align), do: ""
  defp text_body("", _font_size, _font_color, _bold, _align), do: ""

  defp text_body(text, font_size, font_color, bold, align) do
    lines = text |> text_value() |> String.split("\n") |> Enum.reject(&(&1 == ""))

    """
    <p:txBody>
      <a:bodyPr wrap="square" anchor="t"><a:spAutoFit/></a:bodyPr>
      <a:lstStyle/>
      #{Enum.map_join(lines, "", &paragraph_xml(&1, font_size, font_color, bold, align))}
    </p:txBody>
    """
  end

  defp paragraph_xml(text, font_size, font_color, bold, align) do
    """
    <a:p>
      <a:pPr algn="#{align}"/>
      <a:r>
        <a:rPr lang="ko-KR" sz="#{font_size * 100}"#{if bold, do: " b=\"1\"", else: ""}>
          <a:solidFill><a:srgbClr val="#{font_color}"/></a:solidFill>
          <a:latin typeface="Aptos Display"/>
          <a:ea typeface="Noto Sans CJK KR"/>
        </a:rPr>
        <a:t>#{xml(text)}</a:t>
      </a:r>
      <a:endParaRPr lang="ko-KR" sz="#{font_size * 100}"/>
    </a:p>
    """
  end

  defp fill_xml(nil), do: "<a:noFill/>"
  defp fill_xml(color), do: ~s(<a:solidFill><a:srgbClr val="#{color}"/></a:solidFill>)

  defp line_xml(nil), do: "<a:ln><a:noFill/></a:ln>"

  defp line_xml(color) do
    ~s(<a:ln w="9525"><a:solidFill><a:srgbClr val="#{color}"/></a:solidFill></a:ln>)
  end

  defp cards(slide) do
    raw = map_get(slide, "cards", [])

    cards =
      raw
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn card ->
        %{
          title: text_value(map_get(card, "title", "Point")),
          body: text_value(map_get(card, "body", map_get(card, "text", "")))
        }
      end)

    if cards == [] do
      slide
      |> map_get("bullets", ["Clear goal", "Focused execution", "Measurable result"])
      |> List.wrap()
      |> Enum.take(3)
      |> Enum.map(fn bullet -> %{title: text_value(bullet), body: ""} end)
    else
      cards
    end
  end

  defp metrics(slide) do
    raw = map_get(slide, "metrics", [])

    metrics =
      raw
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn metric ->
        %{
          label: text_value(map_get(metric, "label", "Metric")),
          value: text_value(map_get(metric, "value", "0")),
          delta: text_value(map_get(metric, "delta", ""))
        }
      end)

    if metrics == [] do
      [
        %{label: "Speed", value: "30%", delta: "down"},
        %{label: "Accuracy", value: "18%", delta: "up"},
        %{label: "Coverage", value: "2.4x", delta: "lift"}
      ]
    else
      metrics
    end
  end

  defp roadmap(slide) do
    slide
    |> map_get("roadmap", map_get(slide, "steps", ["Discover", "Design", "Build", "Verify"]))
    |> List.wrap()
    |> Enum.map(&text_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp text_block(text, max_chars, max_lines) do
    lines =
      text
      |> text_value()
      |> String.split(~r/\s*(?:\||\n)\s*/, trim: true)
      |> Enum.flat_map(&wrap_line(&1, max_chars))
      |> Enum.reject(&(&1 == ""))

    lines
    |> compact_lines(max_lines, max_chars)
    |> Enum.join("\n")
  end

  defp wrap_line(text, max_chars) do
    text = String.trim(text)

    cond do
      text == "" ->
        []

      String.length(text) <= max_chars ->
        [text]

      String.contains?(text, " ") ->
        text
        |> String.split(" ", trim: true)
        |> Enum.reduce([], fn word, lines ->
          append_word(lines, word, max_chars)
        end)

      true ->
        text
        |> String.graphemes()
        |> Enum.chunk_every(max_chars)
        |> Enum.map(&Enum.join/1)
    end
  end

  defp append_word([], word, _max_chars), do: [word]

  defp append_word(lines, word, max_chars) do
    {last, rest} = List.pop_at(lines, -1)
    candidate = last <> " " <> word

    if String.length(candidate) <= max_chars do
      rest ++ [candidate]
    else
      lines ++ [word]
    end
  end

  defp compact_lines(lines, max_lines, max_chars) do
    if length(lines) <= max_lines do
      lines
    else
      {kept, extra} = Enum.split(lines, max_lines)

      last =
        (List.last(kept) <> " " <> Enum.join(extra, " "))
        |> String.trim()
        |> trim_to(max_chars - 3)

      List.replace_at(kept, -1, last <> "...")
    end
  end

  defp trim_to(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      text |> String.graphemes() |> Enum.take(max_chars) |> Enum.join()
    end
  end

  defp line_count(""), do: 0
  defp line_count(text), do: text |> String.split("\n", trim: true) |> length()

  defp cover_title_font(title_block, title_lines) do
    longest =
      title_block
      |> String.split("\n", trim: true)
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 0 end)

    cond do
      title_lines <= 1 and longest <= 18 -> 42
      title_lines <= 2 and longest <= 26 -> 34
      title_lines <= 2 -> 30
      true -> 26
    end
  end

  defp slide_title_font(title_block, title_lines) do
    longest =
      title_block
      |> String.split("\n", trim: true)
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 0 end)

    cond do
      title_lines <= 1 and longest <= 32 -> 28
      title_lines <= 2 and longest <= 36 -> 24
      title_lines <= 2 -> 22
      true -> 20
    end
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp text_value(value) when is_binary(value), do: value
  defp text_value(nil), do: ""
  defp text_value(value) when is_atom(value), do: Atom.to_string(value)
  defp text_value(value), do: to_string(value)

  defp inch(value), do: round(value * @emu_per_inch)

  defp xml(value) do
    value
    |> text_value()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp content_types(slide_count) do
    slide_overrides =
      1..slide_count
      |> Enum.map_join("\n", fn i ->
        ~s(<Override PartName="/ppt/slides/slide#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
      <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
      <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
      <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
      #{slide_overrides}
    </Types>
    """
  end

  defp root_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """
  end

  defp app_props(slide_count) do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
      <Application>Ecrits</Application>
      <PresentationFormat>Widescreen</PresentationFormat>
      <Slides>#{slide_count}</Slides>
    </Properties>
    """
  end

  defp core_props(deck) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    title = deck |> map_get("title", "Ecrits presentation") |> xml()

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <dc:title>#{title}</dc:title>
      <dc:creator>Ecrits</dc:creator>
      <cp:lastModifiedBy>Ecrits</cp:lastModifiedBy>
      <dcterms:created xsi:type="dcterms:W3CDTF">#{now}</dcterms:created>
      <dcterms:modified xsi:type="dcterms:W3CDTF">#{now}</dcterms:modified>
    </cp:coreProperties>
    """
  end

  defp presentation(slide_count) do
    slide_ids =
      1..slide_count
      |> Enum.map_join("\n", fn i ->
        ~s(<p:sldId id="#{255 + i}" r:id="rId#{i + 1}"/>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
      <p:sldIdLst>#{slide_ids}</p:sldIdLst>
      <p:sldSz cx="#{@slide_cx}" cy="#{@slide_cy}" type="wide"/>
      <p:notesSz cx="6858000" cy="9144000"/>
    </p:presentation>
    """
  end

  defp presentation_rels(slide_count) do
    slide_rels =
      1..slide_count
      |> Enum.map_join("\n", fn i ->
        ~s(<Relationship Id="rId#{i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide#{i}.xml"/>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
      #{slide_rels}
    </Relationships>
    """
  end

  defp slide_master do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
      <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
      <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
    </p:sldMaster>
    """
  end

  defp slide_master_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
    </Relationships>
    """
  end

  defp slide_layout do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
      <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
    </p:sldLayout>
    """
  end

  defp slide_layout_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
    </Relationships>
    """
  end

  defp slide_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
    </Relationships>
    """
  end

  defp theme do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Ecrits">
      <a:themeElements>
        <a:clrScheme name="Ecrits">
          <a:dk1><a:srgbClr val="#{@navy}"/></a:dk1><a:lt1><a:srgbClr val="#{@white}"/></a:lt1>
          <a:dk2><a:srgbClr val="#{@slate}"/></a:dk2><a:lt2><a:srgbClr val="#{@paper}"/></a:lt2>
          <a:accent1><a:srgbClr val="#{@blue}"/></a:accent1><a:accent2><a:srgbClr val="#{@green}"/></a:accent2><a:accent3><a:srgbClr val="#{@orange}"/></a:accent3>
          <a:accent4><a:srgbClr val="#{@cyan}"/></a:accent4><a:accent5><a:srgbClr val="7C3AED"/></a:accent5><a:accent6><a:srgbClr val="E11D48"/></a:accent6>
          <a:hlink><a:srgbClr val="#{@blue}"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Ecrits"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface="Noto Sans CJK KR"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface="Noto Sans CJK KR"/></a:minorFont></a:fontScheme>
        <a:fmtScheme name="Ecrits"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
      </a:themeElements>
    </a:theme>
    """
  end
end
