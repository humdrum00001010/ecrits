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

  # Mounted VFS mode: the ACP file broker is the ordinary code-editor surface;
  # doc.* remains only for opening and an explicitly evidenced native picture.
  defp mounted_vfs_preamble(_status, opts) do
    """
    [System] Stay in the user's scope and do not edit read-only requests. Open the document once with `doc.open_doc`; do not discover MCP resources. Use its ACP files like code: ACP read/search/edit for text and tables, while shell search stays read-only and workspace-scoped. The mounted file keeps one paragraph group per line — locate targets with line-based search and edit whole lines, preserving each line's trailing comma. Keep every document mutation in ACP; never use hwp5txt, raw-HWP extraction, or scripted shell rewrites. For brief-driven fills, account for every field, list item, and table row: fill each blank with a plausible value consistent with the user's request and the document's own context, keep invented details internally consistent wherever they recur, never stamp placeholder markers, and keep each field's label, parentheses, and unit intact. Reread the mounted file immediately before composing each write — the server may normalize between commits — and stage the complete set of supported text and table changes as ONE write. New content must be inserted as exactly one payload node per insert — a `table` node with `cells` (plus optional `header`) or a picture — added inside an existing paragraph group; new heading or paragraph nodes are structural and rejected with EINVAL. On an EINVAL rejection, reread the mounted file and restage the same change from that fresh read. Only a requested native picture may use one post-commit `doc.find` and one image-only `doc.edit`; its marker must fit one rendered line, so keep it a few characters (an existing glyph like `(인)` made unique by its paragraph beats a long inline token), and when the exact target paragraph text repeats in the document, pass `occurrence` (1-based, document order) to pick the intended one.
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
