# Wave 5 — FTC standard contract template seed manifest.
#
# Each entry is enqueued as a `Contract.Workers.FtcSeedJob` by the
# `mix contract.seed.ftc` task. The worker downloads the source bytes,
# parses them via Upstage, normalizes via Engine, and persists a
# `status: :template` Document in the system "FTC 표준약관" matter.
#
# # URL provenance
#
# The Korean Fair Trade Commission (공정거래위원회) publishes the
# canonical 표준약관 (standard contracts) under "정책·제도 → 약관·소비자
# 정책 → 표준약관" on https://www.ftc.go.kr. The category landing page at
# `/www/cop/bbs/selectBoardList.do?bbsId=BBSMSTR_000000002320&key=153`
# lists six families:
#
#     * 표준하도급계약서 (subcontracting)
#     * 표준가맹계약서 (franchise)
#     * 표준유통거래계약서 (distribution)
#     * 표준대리점거래계약서 (agency)
#     * 표준비밀유지계약서 (NDA)
#     * 일반 표준계약서
#
# Each individual contract's article page lists a downloadable HWP/PDF
# attachment under a `fileDown.do` route. The exact attachment-ids
# rotate every revision (FTC re-issues the contracts ~ annually), so
# this manifest carries the **landing URL** for each family and the
# worker is expected to be re-run when an attachment 404s.
#
# The list below is hand-curated to match the FTC-backed TypeSpecs we
# TypeSpecs we already ship in `priv/contract_types/`. New families
# (e.g. employment) get added here once their TOML lands.
#
# A real production seed pass requires:
#
#   1. A browser session to harvest the per-attachment `atchFileId` +
#      `fileSn` query params (the FTC site relies on JS-rendered
#      tables we cannot scrape from curl alone).
#   2. Running `mix contract.seed.ftc` with `UPSTAGE_API_KEY` set; the
#      worker streams the HWP through Upstage Document Parse.
#
# Live URL TODO: the `:source_url` values below point to the FTC
# category landing pages, NOT direct file downloads. Replace with the
# concrete `fileDown.do?atchFileId=...&fileSn=...` URLs as they are
# verified by hand. See `docs/wave-5/ftc-urls.md` (TBD).

[
  %{
    type_key: "service_agreement_v1",
    source_url:
      "https://www.ftc.go.kr/www/cop/bbs/selectBoardList.do?bbsId=BBSMSTR_000000002320&key=153",
    title: "용역위탁 표준계약서"
  },
  %{
    type_key: "nda_v1",
    source_url:
      "https://www.ftc.go.kr/www/cop/bbs/selectBoardList.do?bbsId=BBSMSTR_000000002320&key=153",
    title: "비밀유지 표준계약서"
  }
]
