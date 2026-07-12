# LibreOffice Core Model IR Map

This map is for the Libre/Office arm only. It corrects the earlier shorthand:
the current `libreofficex` JSON walker is not the full LibreOffice editable
model. LibreOffice is model-based, not format-based. File formats import into
one of a few UNO object models, and each model has its own structural surface.

Generated from local source reads on 2026-07-07:

- LibreOffice core: `/Users/phihu/Desktop/core`
- Libre bridge: `/Users/phihu/Desktop/libreofficex`
- ecrits consumer: `/Users/phihu/ecrits`

## Current Bridge Surface

The current bridge emits only this small surface:

| Area | Current emitted node types |
| --- | --- |
| Writer | `paragraph`, `run`, `table`, `cell`, `column_def`, `picture`, `footnote`, `endnote` |
| Impress/Draw pages | `slide`, `shape`, `text_frame` |
| Calc | `sheet`, `cell` |

The Elixir classifier is even smaller because it classifies refs, not every
emitted `type`: `document`, `paragraph`, `run`, `table`, `cell`, `section`,
`slide`, `shape`, `sheet`, `unknown`.

Key source anchors:

- Current ref grammar: `/Users/phihu/Desktop/libreofficex/lib/libreofficex/lok_backend/ir.ex:14`
- Current classifier: `/Users/phihu/Desktop/libreofficex/lib/libreofficex/lok_backend/ir.ex:52`
- Current dispatch: `/Users/phihu/Desktop/libreofficex/native/libreofficex_lok/src/uno_bridge.cpp:2181`
- Current Calc walk: `/Users/phihu/Desktop/libreofficex/native/libreofficex_lok/src/uno_bridge.cpp:587`
- Current Writer column walk: `/Users/phihu/Desktop/libreofficex/native/libreofficex_lok/src/uno_bridge.cpp:795`

## Model Buckets

| Bucket | UNO model | Format examples | IR implication |
| --- | --- | --- | --- |
| Writer/Text | `com.sun.star.text.TextDocument`, `WebDocument`, `GlobalDocument` | docx, odt, rtf, doc, txt, html | Text graph plus suppliers: frames, fields, bookmarks, styles, page styles, notes. |
| Calc/Spreadsheet | `com.sun.star.sheet.SpreadsheetDocument` | xlsx, ods, csv, dif | Workbook/sheet/range model. Sparse scalar cells are not enough. |
| Impress/Presentation | `com.sun.star.presentation.PresentationDocument` | pptx, odp, key imports | Drawing document plus presentation roles, masters, notes, placeholders, transitions. |
| Draw/Drawing | `com.sun.star.drawing.DrawingDocument` | odg, svg, vsd, pdf import | Pages, master pages, Sdr objects, shapes, groups, media, controls. |
| Math/Formula | `com.sun.star.formula.FormulaProperties` | odf formula, MathML, MathType | Formula script plus formula layout properties. |
| Chart | `com.sun.star.chart2.ChartDocument` | embedded charts, odc | Chart tree: diagram, axes, series, titles, legend, data ranges. |
| Filter matrix | XCU filters/types | every supported extension | Not document IR; drives open/save/export selection. |

## Writer/Text IR

Writer has core node types in `/Users/phihu/Desktop/core/sw/inc/ndtyp.hxx:28`:
`Text`, `Table`, `Grf`, `Ole`, `Section`, plus start-node subtypes for table
boxes, fly frames, footnotes, headers, and footers. Most semantic inline
content lives in text attributes from
`/Users/phihu/Desktop/core/sw/inc/hintids.hxx:256`.

| Category | Proposed JSONL types | Source anchors | Read path | Write-back family | Current coverage |
| --- | --- | --- | --- | --- | --- |
| Body text | `paragraph` | `SwNodeType::Text`, `Paragraph.idl` | `XTextDocument.getText()` enumeration | `insert_paragraph`, `delete_paragraph`, `split`, `merge`, `set_text` | Covered |
| Text portions/spans | `run`, `span` | `TextPortion.idl`, `RES_TXTATR_AUTOFMT`, `RES_TXTATR_CHARFMT` | Paragraph `XEnumerationAccess` | `set_span_text`, `set_span_props`, `split_span` | `run` emitted, projection drops it |
| Lists/numbering | `list_item`, `numbering_def` | `XNumberingRulesSupplier.idl`, paragraph numbering props | Paragraph props plus numbering rules | `set_numbering`, `insert_list_item`, `renumber` | Partial as props |
| Tables | `table`, `cell`, `table_row`, `table_column`, `table_grid` | `TextTable.idl`, `XTextTable.idl` | `XTextTablesSupplier.getTextTables()` | table create/delete, row/col insert/delete, merge/split | `table`, `cell`; row/col ops partial |
| Sections | `section`, `column_def` | `TextSection.idl`, `XTextColumns.idl` | `XTextSectionsSupplier.getTextSections()` | `insert_section`, `delete_section`, `set_section_props`, `set_columns` | `column_def` only |
| Text frames | `text_frame` | `TextFrame.idl`, `XTextFrame.idl` | `XTextFramesSupplier.getTextFrames()`, recurse frame text | `insert_text_frame`, `set_frame_props`, `set_frame_text`, `delete_frame` | Missing |
| Pictures | `picture` | `SwNodeType::Grf`, `TextGraphicObject.idl` | `XTextGraphicObjectsSupplier.getGraphicObjects()` | `insert_picture`, `set_picture_props`, `delete_picture` | Covered shallowly |
| Embedded/OLE/equations | `embedded_object`, `ole_object`, `formula` | `SwNodeType::Ole`, `TextEmbeddedObject.idl` | `XTextEmbeddedObjectsSupplier.getEmbeddedObjects()` | `insert_embedded_object`, `insert_formula`, `set_ole_props`, delegated child ops | Insert equation only; no walk |
| Anchored shapes | `shape` | `text/Shape.idl`, `XTextShapesSupplier.idl` | text shape suppliers and draw-page shapes | `insert_shape`, `set_shape_props`, `delete_shape` | Missing |
| Fields | `field`, `input_field`, `fieldmark` | `RES_TXTATR_FIELD`, `RES_TXTATR_INPUTFIELD`, `TextField.idl` | `XTextFieldsSupplier`, portions | `insert_field`, `set_field_props`, `refresh_field`, `delete_field` | Missing |
| Notes | `note_anchor`, `footnote`, `endnote` | `RES_TXTATR_FTN`, `Footnote.idl` | `XFootnotesSupplier`, `XEndnotesSupplier`, portions | note insert/delete/move, body `set_text` | Body nodes only; anchor missing |
| Comments | `comment` | `RES_TXTATR_ANNOTATION`, `textfield/Annotation.idl` | annotation text fields and marks | `insert_comment`, `set_comment`, `resolve_comment`, `delete_comment` | Missing |
| Links | `hyperlink` | `RES_TXTATR_INETFMT`, `SwTextINetFormat` | range/portion props | `insert_link`, `set_link_target`, `unlink` | Flattened if run props survive |
| Ruby | `ruby` | `RES_TXTATR_CJK_RUBY`, `TextPortion` | text portions | `insert_ruby`, `set_ruby_props`, `delete_ruby` | Missing |
| Bookmarks | `bookmark` | `Bookmark.idl`, `XBookmarksSupplier.idl`, `IMark.hxx` | bookmarks supplier plus portions | `insert_bookmark`, `rename_bookmark`, `delete_bookmark` | Missing |
| Reference marks | `reference_mark` | `RES_TXTATR_REFMARK`, `ReferenceMark.idl` | reference marks supplier plus portions | `insert_reference_mark`, `rename_reference_mark`, `delete_reference_mark` | Missing |
| Indexes | `index_mark`, `document_index` | `RES_TXTATR_TOXMARK`, `DocumentIndexMark.idl`, `BaseIndex.idl` | document indexes supplier plus index mark portions | `insert_index_mark`, `insert_index`, `refresh_index`, `delete_index` | Missing |
| Redlines | `redline` | `TextPortion.idl`, `document/XRedlinesSupplier.idl`, `text/XRedline.idl` | redlines supplier plus redline portions | `make_redline`, `accept_redline`, `reject_redline` | Missing |
| Metadata | `metadata`, `metadata_field` | `RES_TXTATR_META`, `RES_TXTATR_METAFIELD`, `InContentMetadata.idl` | text portions and nested text content | `insert_metadata`, `set_rdf`, `delete_metadata` | Missing |
| Content controls | `content_control` | `RES_TXTATR_CONTENTCONTROL`, `ContentControl.idl`, `XContentControlsSupplier.idl` | content controls supplier plus portions | `insert_content_control`, `set_content_control_props`, `delete_content_control` | Missing |
| Line breaks | `line_break` | `RES_TXTATR_LINEBREAK`, `TextRangeContentProperties.idl` | text portions | `insert_line_break`, `set_line_break_clear`, `delete_line_break` | Flattened in paragraph text |
| Page styles | `page_style`, `header`, `footer`, `page_column_def` | `TextPageStyle.idl`, style families | `XStyleFamiliesSupplier.PageStyles`, recurse header/footer text | `set_page_style`, `set_header_text`, `set_footer_text`, `set_page_columns` | Missing |
| Styles | `style_def` | `XStyleFamiliesSupplier.idl`, style families | style families: character, paragraph, frame, page, numbering | `create_style`, `set_style_props`, `delete_style` | Inline props only |
| Unknown/user attrs | `unknown_xml`, `user_attrs` | `RES_TXTATR_UNKNOWN_CONTAINER`, user-defined attributes | user-defined attributes suppliers and portion props | preserve first, later `set_user_attrs` | Missing |

## Drawing/Impress IR

The drawing layer object enum has 108 named values in
`/Users/phihu/Desktop/core/include/svx/svdobjkind.hxx:24`. The normalized IR
should not blindly expose 108 public node types, but every enum group must map
to a stable semantic node or a declared "out of primary scope" bucket.

| Category | Proposed JSONL types | Read path | Write-back family | Current coverage |
| --- | --- | --- | --- | --- |
| Pages | `draw_page`, `slide`, `master_slide`, `notes_page`, `handout_page`, `page_background` | `XDrawPagesSupplier`, `XMasterPagesSupplier`, `XPresentationPage` | `insert_slide`, `delete_page`, `set_page_props`, `set_master_page` | Normal `slide` only |
| Basic shapes | `shape`, `text_frame`, `group`, `connector`, `caption`, `measure`, `custom_shape`, `page_preview` | `XDrawPage`/`XShapes`, `XShape`, `XText`, `XPropertySet` | `insert_shape`, `set_geometry`, `set_text`, `uno_set`, `delete_node` | `shape`, `text_frame`; no subkind |
| Shape tables | `table`, `cell`, `table_row`, `table_column`, `table_grid` | `drawing.TableShape`, `XCellRange` | table row/col/merge/split ops | Some table cells, no table node |
| Graphics/media/OLE | `picture`, `ole`, `chart`, `media`, `plugin`, `applet`, `annotation` | `GraphicObjectShape`, `OLE2Shape`, `MediaShape`, `AnnotationShape`; OLE model refs | insert/set/delete object ops, delegated child ops | Generic shape or missing |
| 3D objects | `scene3d`, `object3d`, `cube3d`, `sphere3d`, `extrusion3d`, `lathe3d`, `compound3d`, `polygon3d` | `Shape3D*` services, E3D inventor | 3D shape create/set/delete | Generic shape if encountered |
| Controls/forms | `form`, `control_shape`, `form_control` | page `XFormsSupplier`, shape `XControlShape.getControl()` | create form model plus control shape, set model props | Missing |
| Presentation placeholders | `placeholder`, optionally `title`, `outline`, `subtitle`, `header`, `footer`, `date_time`, `slide_number` | presentation shape services and props `IsPresentationObject`, `CustomPromptText` | `insert_placeholder`, `set_placeholder_props`, `set_text` | Collapsed to shape/text_frame |
| Animation/transition | `slide_transition`, `animation_sequence`, `animation_effect` | page transition props, `XAnimationNodeSupplier.getAnimationNode()` | `set_transition`, `set_animation_tree` | Missing or generic props |
| Layers | `layer`, `layer_assignment` | `XLayerSupplier`, `XLayerManager` | `create_layer`, `set_layer_props`, `assign_shape_layer` | Missing |
| Basic dialog controls | `basic_dialog_control` | basctl/dialog model | separate dialog ops if needed | Out of primary slide IR |
| Report design | `report_control` | reportdesign model | separate report ops if needed | Out of primary slide IR |
| Writer frame bridge | `writer_frame_bridge` | Writer drawing bridge values | no Impress op | Internal sentinel |

### Full `SdrObjKind` Group Map

Source: `/Users/phihu/Desktop/core/include/svx/svdobjkind.hxx:24`.

| Group | Values | Public IR mapping |
| --- | --- | --- |
| Base drawing | `NONE`, `Group`, `Line`, `Rectangle`, `CircleOrEllipse`, `CircleSection`, `CircleArc`, `CircleCut`, `Polygon`, `PolyLine`, `PathLine`, `PathFill`, `FreehandLine`, `FreehandFill`, `Text`, `TitleText`, `OutlineText`, `Graphic`, `OLE2`, `Edge`, `Caption`, `PathPoly`, `PathPolyLine`, `Page`, `Measure`, `OLEPluginFrame`, `UNO`, `CustomShape`, `Media`, `Table`, `Annotation` | `shape` plus `shape_kind`, or typed nodes for `group`, `text_frame`, `picture`, `ole`, `connector`, `caption`, `measure`, `media`, `table`, `annotation` |
| OLE legacy | `OLE2Applet`, `OLE2Plugin` | `applet`, `plugin`, usually under `ole` |
| 3D | `E3D_Scene`, `E3D_Object`, `E3D_Cube`, `E3D_Sphere`, `E3D_Extrusion`, `E3D_Lathe`, `E3D_CompoundObject`, `E3D_Polygon`, `E3D_INVENTOR_FIRST`, `E3D_INVENTOR_LAST` | 3D typed nodes; alias values not emitted as nodes |
| Form controls | `FormControl`, `FormEdit`, `FormButton`, `FormFixedText`, `FormListbox`, `FormCheckbox`, `FormCombobox`, `FormRadioButton`, `FormGroupBox`, `FormGrid`, `FormImageButton`, `FormFileControl`, `FormDateField`, `FormTimeField`, `FormNumericField`, `FormCurrencyField`, `FormPatternField`, `FormHidden`, `FormImageControl`, `FormFormattedField`, `FormScrollbar`, `FormSpinButton`, `FormNavigationBar` | `control_shape` plus `control_kind`, with separate `form_control` model |
| Basic dialog | `BasicDialogControl`, `BasicDialogDialog`, `BasicDialogPushButton`, `BasicDialogRadioButton`, `BasicDialogCheckbox`, `BasicDialogListbox`, `BasicDialogCombobox`, `BasicDialogGroupBox`, `BasicDialogEdit`, `BasicDialogFixedText`, `BasicDialogImageControl`, `BasicDialogProgressbar`, `BasicDialogHorizontalScrollbar`, `BasicDialogVerticalScrollbar`, `BasicDialogHorizontalFixedLine`, `BasicDialogVerticalFixedLine`, `BasicDialogDateField`, `BasicDialogTimeField`, `BasicDialogNumericField`, `BasicDialogCurencyField`, `BasicDialogFormattedField`, `BasicDialogPatternField`, `BasicDialogFileControl`, `BasicDialogTreeControl`, `BasicDialogSpinButton`, `BasicDialogGridControl`, `BasicDialogHyperlinkControl`, `BasicDialogFormRadio`, `BasicDialogFormCheck`, `BasicDialogFormList`, `BasicDialogFormCombo`, `BasicDialogFormSpin`, `BasicDialogFormVerticalScroll`, `BasicDialogFormHorizontalScroll` | `basic_dialog_control`; not primary document IR unless dialog documents are in scope |
| Report design | `ReportDesignFixedText`, `ReportDesignImageControl`, `ReportDesignFormattedField`, `ReportDesignHorizontalFixedLine`, `ReportDesignVerticalFixedLine`, `ReportDesignSubReport` | `report_control`; not primary Office document IR unless report documents are in scope |
| Writer bridge | `SwFlyDrawObjIdentifier`, `NewFrame` | internal bridge/sentinel, not a direct public node |

## Calc/Spreadsheet IR

Calc is range-first. A scalar `sheet`/`cell` walk does not see empty styled
cells, merged ranges, comments, validations, conditional formatting, charts,
pivots, scenarios, or sparklines.

| Category | Proposed JSONL types | Source anchors | Read path | Write-back family | Current coverage |
| --- | --- | --- | --- | --- | --- |
| Workbook/sheets | `calc_workbook`, `sheet` | `SpreadsheetDocument.idl`, `Spreadsheet.idl` | `XSpreadsheetDocument.getSheets()` | workbook props/protection, sheet insert/move/copy/remove/rename | `sheet` only |
| Named/database ranges | `named_range`, `database_range`, `filter_descriptor`, `sort_descriptor` | `XNamedRanges.idl`, `XDatabaseRange.idl`, `SheetCellRange.idl` | named/database range collections | upsert/remove/refresh/sort/filter | Missing |
| Scenarios | `scenario`, `scenario_range` | `XScenarios.idl`, `XScenario.idl`, `XScenarioEnhanced.idl` | scenarios supplier | create/remove/apply/set props | Missing |
| Print/break/outline | `print_area`, `print_title_range`, `page_break`, `outline_group` | `XPrintAreas`, `XSheetPageBreak`, `XSheetOutline` | sheet interfaces | print/break/outline ops | Missing |
| Protection/events/links | `protection`, `sheet_event`, `external_link`, `external_sheet_cache` | `XProtectable`, events, `XExternalDocLinks.idl` | sheet/doc suppliers | protect/unprotect, event replace/reset, link ops | Missing |
| Scalar cells | `cell` with `value_type`: empty, number, text, formula, error | `XCell.idl`, `CellContentType.idl` | `XCell` | `cell.set_value`, `set_formula`, `set_text`, `clear` | Partial: skips empty/errors |
| Rich cell text | `cell_text`, `cell_text_run`, `cell_text_field` | `SheetCell.idl`, `textuno.cxx` | cell `text::Text`, fields supplier | text replace/run/field ops | Missing |
| Array formulas | `array_formula`, `formula_tokens` | `XArrayFormulaRange.idl`, `cellsuno.cxx` | array formula range/token interfaces | set/clear/tokens | Missing |
| Merged ranges | `merged_range`, `merge_anchor` | `XMergeable`, `XMergeableCell.idl` | range interfaces | merge/unmerge | Missing |
| Annotations | `annotation`, `annotation_shape` | `XSheetAnnotations.idl`, `notesuno.cxx` | annotation supplier plus note shape | insert/remove/set text/visibility | Missing |
| Formatting/dimensions | `cell_format`, `cell_style`, `row`, `column` | `CellProperties.idl`, `XColumnRowRange.idl`, `TableColumn.idl`, `TableRow.idl` | range/cell/row/column props | prop/dimension/hidden ops | Inline props only |
| Validation/conditional formatting | `validation`, `conditional_format`, `conditional_rule` | `TableValidation.idl`, `XSheetConditionalEntries.idl`, `XConditionalFormats.idl` | range/sheet collections | validation and conditional format ops | Missing |
| Sheet draw objects | `draw_page`, `shape`, `picture`, `ole_object`, `form_control` | `XDrawPageSupplier`, `pageuno.cxx` | sheet draw page | draw object create/update/delete | Picture insert only |
| Charts | `chart`, `chart_series`, `chart_data_range` | `XTableCharts.idl`, `TableChart.idl`, `ChartDocument.idl` | table charts plus chart2 child model | add/remove/set ranges/set props | Missing |
| DataPilot/pivots | `data_pilot_table`, `data_pilot_field`, `data_pilot_item` | `XDataPilotTables.idl`, `XDataPilotDescriptor.idl`, `DataPilotField.idl`, `DataPilotItem.idl` | data pilot tables/descriptors | pivot create/remove/refresh/set field/item | Missing |
| Pivot charts | `pivot_chart` | `XTablePivotCharts.idl`, `TablePivotChart.cxx` | pivot chart collection | add/remove/set geometry | Missing |
| Sparklines | `sparkline_group`, `sparkline` | `Sparkline.hxx`, `SparklineList.hxx`, `SparklineFragment.cxx` | likely native `ScDocument`/`SparklineList` helper | create/update/delete/group/set attrs | Missing; weak public UNO surface |

## Math, Chart, OLE, Filter, PDF

| Surface | Proposed JSONL types | Source anchors | Read path | Write-back family | Current coverage |
| --- | --- | --- | --- | --- | --- |
| Math/formula | `formula` | `starmath/util/sm.component:22`, `FormulaProperties.idl`, `starmath/source/document.cxx` | standalone formula doc or embedded OLE child; `Formula` StarMath prop | `insert_formula`, `set_formula_script`, `set_formula_props`, `delete_formula`, import/export MathML | Writer insert only |
| Chart2 | `chart`, `chart_title`, `diagram`, `legend`, `coord_system`, `axis`, `chart_type`, `series`, `data_sequence`, `data_range`, `data_table` | `chart2.component`, `XChartDocument.idl`, `XDiagram.idl`, chart2 data interfaces | standalone chart doc or embedded OLE child | chart type/range/series/axis/title/legend ops | Missing |
| OLE discovery | `ole` with `embedded_type` | `TextEmbeddedObject.idl`, `drawing/OLE2Shape.idl`, `charthelper.cxx` | host suppliers/shapes, `CLSID`, `PersistName`, `Model`, child model query | list/get/delete, replacement graphic, delegated child ops | Missing |
| Filter matrix | `filter_matrix` metadata, not document payload | `filter/source/config/fragments/filters/*.xcu`, `types/*.xcu` | generated join from filter `Type` to type `oor:name` | validate open/save/export; no content write-back | Save accepts raw filter name only |
| PDF export | no document IR; save target | `writer_pdf_Export.xcu`, `draw_pdf_Export.xcu`, `pdf_Portable_Document_Format.xcu` | filter matrix | `save_as_pdf` with FilterData | Generic save filter only |
| PDF import | `draw_page`, `pdf_page`, `pdf_object`, low-semantic `shape`/`picture` | `pdf_Import.xcu`, `svdpdf.hxx`, sd PDF import tests | PDFium/Draw import result | draw object ops; mark low semantic confidence | Missing normalized handling |

Filter registry facts from this checkout:

- Filter fragments: 247
- Type fragments: 188
- Must generate from XCU instead of hardcoding extensions.
- Fields to preserve: filter name, type, flags, filter service, user data,
  file format version, document service, UI name, extensions, media type,
  preferred filter, detect service, URL pattern.

## Normalized Type Registry

This is the current target registry for complete Libre model coverage. It is
grouped by owner model; names can still be refined, but each source category
above needs a declared destination.

| Owner | Types |
| --- | --- |
| Common | `document`, `style_def`, `user_attrs`, `unknown_xml`, `filter_matrix` |
| Writer | `paragraph`, `run`, `span`, `list_item`, `numbering_def`, `table`, `cell`, `table_row`, `table_column`, `table_grid`, `section`, `column_def`, `text_frame`, `picture`, `embedded_object`, `ole_object`, `formula`, `shape`, `field`, `input_field`, `fieldmark`, `note_anchor`, `footnote`, `endnote`, `comment`, `hyperlink`, `ruby`, `bookmark`, `reference_mark`, `index_mark`, `document_index`, `redline`, `metadata`, `metadata_field`, `content_control`, `line_break`, `page_style`, `header`, `footer`, `page_column_def` |
| Drawing/Impress | `draw_page`, `slide`, `master_slide`, `notes_page`, `handout_page`, `page_background`, `shape`, `text_frame`, `group`, `connector`, `caption`, `measure`, `custom_shape`, `page_preview`, `table`, `cell`, `picture`, `ole`, `chart`, `media`, `plugin`, `applet`, `annotation`, `scene3d`, `object3d`, `cube3d`, `sphere3d`, `extrusion3d`, `lathe3d`, `compound3d`, `polygon3d`, `form`, `control_shape`, `form_control`, `placeholder`, `title`, `outline`, `subtitle`, `header`, `footer`, `date_time`, `slide_number`, `slide_transition`, `animation_sequence`, `animation_effect`, `layer`, `layer_assignment`, `basic_dialog_control`, `report_control`, `writer_frame_bridge` |
| Calc | `calc_workbook`, `sheet`, `named_range`, `database_range`, `filter_descriptor`, `sort_descriptor`, `scenario`, `scenario_range`, `print_area`, `print_title_range`, `page_break`, `outline_group`, `protection`, `sheet_event`, `external_link`, `external_sheet_cache`, `cell`, `cell_text`, `cell_text_run`, `cell_text_field`, `array_formula`, `formula_tokens`, `merged_range`, `merge_anchor`, `annotation`, `annotation_shape`, `cell_format`, `cell_style`, `row`, `column`, `validation`, `conditional_format`, `conditional_rule`, `draw_page`, `shape`, `picture`, `ole_object`, `form_control`, `chart`, `chart_series`, `chart_data_range`, `data_pilot_table`, `data_pilot_field`, `data_pilot_item`, `pivot_chart`, `sparkline_group`, `sparkline` |
| Math | `formula` |
| Chart2 | `chart`, `chart_title`, `diagram`, `legend`, `coord_system`, `axis`, `chart_type`, `series`, `data_sequence`, `data_range`, `data_table` |
| PDF import | `pdf_page`, `pdf_object`, plus low-semantic Draw nodes |

## Implementation Order

1. Expand bridge dispatch and walker roots.
   Add standalone Math and Chart dispatch, Draw document walk, and OLE discovery
   before model-specific walkers.

2. Make nested text containers recursive.
   Recurse table cells, text frames, headers/footers, note bodies, content
   controls, and embedded child models. Body `XTextDocument.getText()` is not
   the full Writer document.

3. Preserve text portions as structural children.
   Dropping runs loses hyperlinks, fields, bookmarks, redlines, metadata,
   content controls, ruby, and line breaks.

4. Add range-aware Calc walkers.
   Many Calc nodes are ranges, not cells: merges, validation, conditional
   formats, array formulas, print areas, filters, sorts, chart sources.

5. Normalize Draw/Impress object roles.
   Keep `shape_kind`, but expose first-class groups, placeholders, masters,
   notes, media, OLE/chart, controls, layers, transitions, and animation trees.

6. Generate the filter matrix.
   Use XCU files to determine format support and save/export compatibility.
   Do not create per-format IR schemas.

7. Treat PDF import as low-semantic Draw IR.
   PDF export is a filter. PDF import is geometry/shapes/images unless a later
   OCR/layout layer explicitly recovers semantics.

## Immediate Backlog Alignment

- #277 layout/page: page styles, headers/footers, page columns, breaks,
  masters/backgrounds.
- #278 text formatting/styles: spans, styles, lists, numbering, links, ruby.
- #279 structural ops: recursive text, table geometry, row/col/merge/split,
  paragraph lifecycle.
- #280 notes/links/fields/metadata: anchors, comments, fields, bookmarks,
  refs, redlines, content controls.
- #281 objects/graphics: OLE, formulas, charts, shapes, media, controls.
- #282 PPTX structure: masters, notes, placeholders, transitions, animations.
- #283 Calc: extend beyond scalar sheet/cell to ranges, charts, pivots,
  annotations, sparklines.
- #286 model/filter: Draw, Math, Chart, PDF/filter matrix.
- #309 umbrella: keep this map current as implementation lands.
