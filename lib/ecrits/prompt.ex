defmodule Ecrits.Prompt do
  @moduledoc """
  Agent-visible instruction copy.

  This module is the single home for prose sent to an agent: the ACP turn
  preamble, selected-element augmentation, and MCP initialization guidance.
  It deliberately does not contain MCP schemas or transport/content encoding.
  """

  alias Ecrits.Fuse.DocMount

  @doc "The provider-agnostic ACP preamble for one chat turn."
  @spec acp_preamble(keyword()) :: String.t()
  def acp_preamble(opts) do
    status = DocMount.status()
    vfs_mounted? = Keyword.get(opts, :doc_vfs_mounted, status.enabled?)

    cond do
      status.enabled? and vfs_mounted? ->
        mounted_vfs_preamble(status, opts)

      status.enabled? ->
        unmounted_vfs_preamble(status, opts)

      fs_vfs_expected?(status) ->
        blocked_vfs_preamble(status, opts)

      true ->
        legacy_doc_preamble(opts)
    end
  end

  @doc "Append selected document context to an agent turn."
  @spec with_selected_elements(String.t(), [map()], :fskit | :fuse) :: String.t()
  def with_selected_elements(message, [], _backend), do: message

  def with_selected_elements(message, picks, _backend) do
    block =
      "Selected document elements (#{length(picks)}):\n```json\n" <>
        Jason.encode!(picks, pretty: true) <>
        "\n```\n" <>
        "Use this as target context; do not infer a different target from it.\n"

    sep = if message == "" or String.ends_with?(message, "\n"), do: "", else: "\n\n"
    message <> sep <> block
  end

  @doc "The compact VFS discovery copy shown with doc.open_doc."
  @spec vfs_open_doc_tool_description() :: String.t()
  def vfs_open_doc_tool_description do
    "Open the current workspace document once and return its mounted ACP projection, document id, and safe workspace file index. Read and edit listed text files with ACP file tools; reserve doc.edit for one explicitly requested native picture."
  end

  @doc "The compact VFS-only fallback copy shown with doc.edit."
  @spec vfs_edit_fallback_tool_description() :: String.t()
  def vfs_edit_fallback_tool_description do
    "Fallback only for a native change the mounted ACP surface cannot represent. " <>
      "For a requested picture at an existing marker, keep the supplied file unchanged; use the returned marker reference and doc.open_doc evidence; placement and sizing are server-owned; text or table edits never belong here."
  end

  @doc "The compact VFS-mode description for resolving a current native ref."
  def vfs_native_ref_tool_description do
    "One post-commit marker lookup only: copy the exact requested target paragraph from the ACP projection, ending in its existing marker, and use before_marker_ref verbatim."
  end

  defp unmounted_vfs_preamble(status, opts) do
    """
    [System] Doc VFS backend is available, but this workspace is not mounted right now:
    #{status.message}

    Report the unavailable ACP document surface. Read-only shell search and
    inspection may continue for ordinary workspace evidence, but never bypass ACP with hwp5txt,
    a raw parser, scripted document rewrites, or doc.edit for text or tables.
    """ <> ultrathink_suffix(opts)
  end

  defp fs_vfs_expected?(%{backend: :fskit, reason: reason})
       when reason in [
              :fskit_extension_disabled,
              :fskit_extension_not_registered,
              :fskit_extension_unsigned
            ],
       do: true

  defp fs_vfs_expected?(_status), do: false

  defp blocked_vfs_preamble(status, opts) do
    settings_line =
      if is_binary(status.settings_url) and status.settings_url != "" do
        "Settings URL: #{status.settings_url}\n"
      else
        ""
      end

    """
    [System] FSKit/VFS is configured but not mountable right now:
    #{status.message}
    #{settings_line}
    Report the unavailable ACP document surface. Read-only shell search and
    inspection may continue for ordinary workspace evidence, but never bypass ACP with hwp5txt,
    a raw parser, scripted document rewrites, or doc.edit for text or tables.
    """ <> ultrathink_suffix(opts)
  end

  # Mounted VFS mode: each provider's native code-editor tools operate on the
  # returned mount; doc.* remains only for opening and an evidenced native
  # image/signature operation that the projection cannot express.
  defp mounted_vfs_preamble(_status, opts) do
    """
    [System] Do not edit read-only requests. Call `doc.open_doc` once and use the returned mount path; do not discover MCP resources. Use native file/search/edit/shell tools. Python/Ruby writes are allowed. Never use hwp5txt, raw-HWP extraction, or binary-document rewrites.

    The mounted JSON projection has `[`/`]` wrappers and ordered semantic groups. Parse and write the complete wrapper as one JSON value; never reconstruct line commas. Preserve order and unknown keys. A paragraph's `text` is the editable aggregate; `char` nodes are derived runs and must not be edited or audited. Use one fresh full read. Direct file edits and workspace-local helper scripts are both valid; choose the smallest reliable edit path. Keep the transformation order pristine read → SOURCE → FIELDS → MAP → transform. Extract SOURCE mechanically from source-data sections only; exclude procedural instructions. Keep SOURCE values as complete source literals; do not split or normalize them, or append units or suffixes already present. Freeze FIELDS from pristine before transform and identify each field by stable group/node position or table cell coordinates. Classify using visible labels and local cell structure, not a fixed label-keyword regex; never authorize a blind fill loop. MAP is the sole transform plan: map every field and requested insertion to a source fact and rendered value, then transform only MAP destinations. Every source fact from source-data sections that has a compatible labeled field or explicit requested insertion must appear in MAP; list any fact with no destination instead of silently dropping it. Every destination-less prose item is a planned MAP insertion. Materialize SOURCE, FIELDS, and MAP as data when scripting or as an explicit checklist when editing directly. Generate every mutation from MAP. Derive `unmapped_source_facts` and `unresolved_fields` as actual inventory set differences. Do not merely claim these lists are empty. Never initialize either result directly to `[]`, delete an entry to force success, or spot-check a few anchors—verify the complete inventories, never a sample. For labeled fields, preserve the pristine label, punctuation, spacing, parentheses, and units; replace only the placeholder or value span instead of retyping the label. Verify every source-derived rendering, including prose facts such as jurisdiction, exactly before writing.

    Before committing, require `unmapped_source_facts == []` and require `unresolved_fields == []`, mechanically diff pristine → candidate, and audit every changed node. Serialize, parse, and validate the parsed candidate bytes before the first rename, including every exact MAP rendering; never use the committed file to discover a candidate defect. Remove every changed pristine-blank paragraph outside a proven table-cell value block; an unlabeled layout blank is never a field. Apply the complete supported change through the mounted file, require valid JSONL that contains the intended changes, and reread the canonical projection afterward. Post-commit checks are read-only. If a table-inserting commit reveals any defect, the rehearsal failed rather than reopening the projection. If the write returns EINVAL, treat the candidate as rejected, not as proof of a stale read. Reread the canonical projection, correct structural offenders first, and retry one corrected candidate; never blindly restage identical rejected bytes. If that retry fails, stop and explain. Never truncate, no-op, or repair the mounted target. EINVAL means no durable commit, so stop before `doc.find` or `doc.edit`.

    In a table group, each `cell` begins its block and only paragraphs before the next `cell` belong to it. Any paragraph before the first `cell` is structural and must remain byte-for-byte unchanged. Blank means `text.strip()` is empty. A blank or whitespace-only non-cell paragraph is layout; promote an in-cell blank to a field only when its own cell block or labeled row proves that exact node is the value destination. Never scan past the next cell, fill blanks broadly, or zip values across every table `paragraph`. Target by `cell` coordinates and visible label. Preserve a label paragraph when its separate value paragraph is the destination. Repeated party tables keep the first complete field sequence as owner and the second as subcontractor.

    Match pristine nodes by insertion-adjusted stable identity; never positional-zip shifted group lists. Reject only when a matched node's own `text` changed and its new value contains a newline. Fill existing tables through served cell-block paragraph aggregates; never add or replace a `cells` matrix on an existing table payload. If a proven value cell has no paragraph, set that existing `cell` node's `text` directly; never insert a ref-less paragraph inside an existing table. For a requested inserted table, attach exactly one new `table` payload with `cells` and optional `header` to the semantic preceding-anchor group so it renders before the requested following anchor. Compute structural anchors from pristine before inserting. Each new body paragraph is its own group with one ref-less non-empty `paragraph`; never attach a table to that new paragraph group. Because the engine normalizes a new compact table after commit, a successful table-inserting rename is the final projection write for the turn; include every text edit in that candidate and make no later projection correction.

    Use `doc.edit` only after the durable projection commit and only for an IR-inexpressible image/signature. If any MAP destination is unresolved, stop before the image edit. Canonicalize the target paragraph, then use one `doc.find`; its marker must fit one rendered line, so prefer `(인)` and pass the correct 1-based occurrence. Call image-only `doc.edit` once and require success. Then verify read-only and never rewrite the projection. Do not investigate or repair stale `previewText`; projection `previewText` and picture payloads are stale after the native edit and replay can discard the image. After successful `doc.edit`, run no further shell, projection, or MCP call; its native success and the app-owned preview event complete the requested verification, so respond immediately.
    """ <> ultrathink_suffix(opts)
  end

  defp legacy_doc_preamble(opts) do
    """
    [System] Use the document tools and their returned capabilities for document
    work. Do not modify raw binary document files directly.
    """ <> ultrathink_suffix(opts)
  end

  defp ultrathink_suffix(opts) do
    if Keyword.get(opts, :reasoning_effort) == "ultracode" do
      "\n\n[System] ultrathink\n"
    else
      ""
    end
  end
end
