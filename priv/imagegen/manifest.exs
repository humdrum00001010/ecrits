# Imagery manifest for `mix contract.imagegen`.
#
# Wave 3C0-E pared this down to TWO images: a tiny accompaniment for
# the landing body and a dashboard empty-state.
#
# Note: gpt-image-1's moderation can block prompts with named-person
# references (Vignelli, Rams) or with specific charged subject words
# ("contract", "legal document"). The prompts below keep the subject
# generic (a sheet of paper, a folder) and describe style without
# naming designers.

[
  %{
    slug: "hero",
    prompt: """
    A minimalist editorial line illustration. The subject is one tall
    rectangular sheet of paper, centered on a pure white background. The
    sheet has three short horizontal rules stacked in its upper portion,
    suggesting abstracted body text. Below the third rule, one short
    horizontal line in emerald green (#10b981) runs about a third of the
    sheet's width — the only colour accent. Above the sheet, in empty
    space, a small outlined punctuation glyph sits as a thin line stroke.

    Style: austere editorial technical diagram. Swiss typography manual
    aesthetic. Uniform 1 pt line weight throughout. Pure white
    background, black contour, one emerald accent line. Geometric,
    balanced, generous margins. Vector precision. Flat — no shading,
    no gradient, no perspective. 1:1 square composition.
    """,
    size: "1024x1024",
    quality: "high",
    output_path: "priv/static/images/landing/hero.png"
  },
  %{
    slug: "dashboard-empty",
    prompt: """
    A minimalist editorial line illustration. The subject is one
    rectangular paper folder outline, centered on a pure white
    background. The folder is drawn as two simple rectangles: a small
    tab on top and a wider body beneath, both empty. One short
    horizontal line in emerald green (#10b981) sits along the top edge
    of the folder tab — the only colour accent.

    Style: austere editorial technical diagram. Swiss typography manual
    aesthetic. Uniform 1 pt line weight throughout. Pure white
    background, black contour, one emerald accent line. Geometric,
    balanced, generous margins. Vector precision. Flat — no shading,
    no gradient, no perspective. 1:1 square composition.
    """,
    size: "1024x1024",
    quality: "high",
    output_path: "priv/static/images/landing/dashboard-empty.png"
  }
]
