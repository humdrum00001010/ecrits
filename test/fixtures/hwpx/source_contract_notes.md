# Source Contract: `real_contract.hwpx`

## Provenance

* **File**: `전력기술관리법 운영요령` (Electric Power Technology Management Act
  Operating Guidelines) — 산업통상자원부 (Ministry of Trade, Industry & Energy)
  고시 제2020-93호 (Notice No. 2020-93), promulgated 2020년 6월 8일.
* **Source URL**:
  https://github.com/jc-kim/hwp2md/blob/main/examples/elec_tech_manger_mke_20200608.hwpx
* **Provenance chain**: Published by the South Korean government as a public
  legal notice (officially gazetted MOTIE document). Mirrored in
  `jc-kim/hwp2md`, an HWPX-tooling repo of `jc-kim` (active contributor in
  Korean office-document open source).
* **Format**: real HWPX (OWPML 1.4) — opens cleanly in Hancom Office; passes
  pyhwpxlib's text extraction (88,350 bytes, 25,444 chars across 3 sections).

This is not an FTC 표준약관 (the FTC public site is JS-hydrated and was not
fetchable via static GET; see Wave 5 notes). It IS however a real published
Korean legal-genre document with the exact same article-numbered
("제N조(제목)") structure that Korean standard contracts use — chapter
("제N장") + article ("제N조(...)") + numbered sub-items (1., 2., ...) is the
common shape across regulations, standard contract terms, and gazetted forms.

## Structural summary

Source contains 3 sections, 1,061 paragraphs total, and 10 tables. The
document opens with a publication header, then chapter headings (제1장…), then
clauses (제1조, 제2조, …), interleaved with tables for cost rates and personnel
requirements.

### Heading style IDs (header.xml)

| Para `paraPrIDRef` | Observed use                                |
| ------------------ | ------------------------------------------- |
| `14`               | Body / blank lines (default)                |
| `16`               | Chapter heading (제1장 …, 제2장 …, 제3장 …)  |
| `17`               | Clause heading (제1조(…), 제2조(…), …)       |
| `18`               | Sub-clause / numbered sub-item              |
| `19`               | Continuation paragraphs of long definitions |

Notable: the source does NOT use the OWPML `<hh:heading type="OUTLINE"/>`
mechanism — chapter and clause headings are styled paragraphs that visually
read as headings but carry the same outline level as body text. The Style
table maps `style@id=0` ("바탕글" Normal) and `style@id=1` ("본문"); chapter /
clause paragraphs all reference style 0 with bigger-height char shapes.

### Char shape sizes (header.xml `<hh:charPr/@height>`, 1/100 pt)

* `charPr@id=0`: 1000 (10pt) — body
* `charPr@id=1`: 1400 (14pt) — used by chapter/clause titles in source
* Body text in clause bodies: 10–13pt

### Tables

10 tables total. Representative sample (table at paragraph index 394 —
included in the fixture):

* 5 rows × 3 cols
* Border-fill id refs: table `bf=9`, header-row cells `bf=25/26`, body cells
  `bf=26/27`
* Column widths (HWP units): `[6156, 10684, 27947]` — i.e. 7% / 23% / 70% of
  total width
* Header row contains: 구분 | 규모 | 감리원배치 인원수
* Row-span: column 0 cells span 2 rows (가.공동주택, 나.건축물)

### Section break

`section0.xml` carries the only `<hp:secPr>` at the start of the first
paragraph. `section1.xml` and `section2.xml` reuse the same shape registry
from `header.xml`. The writer emits a single-section document, so the
fixture covers section0 content only.

## What the projection fixture captures

We take the slice from index `[9..42]` in section0 — paragraphs covering:

* the document title (전력기술관리법 운영요령)
* 제1장 총칙 (Chapter 1 — General Provisions)
* 제1조 (Purpose), 제2조 (Definitions, with 16 sub-items), 제3조
  (Electric-power-technician organization)
* 제2장 + the deleted-range marker (제4조∼제14조 ＜삭제＞)
* 제3장 + 제15조 (Adjustment of fees) with 6 numbered sub-items

Plus we append the 5×3 table from paragraph 394 (구분 / 규모 / 감리원배치
인원수) for table-cellSz round-trip verification.

This subset is large enough to exercise heading detection, paragraph mode
switches, deep clause numbering, and table cell width preservation, while
small enough (~30 paragraph nodes + 1 table with 15 cells) to keep the
fixture file maintainable.

## What the writer does NOT (yet) preserve

* The source uses paraPrIDRef `14`/`16`/`17`/`18`/`19` from its own header
  registry. Our writer always uses the smaller fixed registry (0=body,
  1=bullet, 2..7=heading levels 1..6). After round-trip, text content is
  preserved verbatim but the visual font sizes will differ.
* The source has 90 `<hp:cellSz>` entries across all tables; we only
  preserve those for the specific table in the projection.
* Section 1 (the law-text-quote section1.xml) and section 2 (the rate-table
  section2.xml) are not part of the projection — round-trip preserves
  section0 content only.
