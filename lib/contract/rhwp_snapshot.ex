defmodule Contract.RhwpSnapshot do
  @moduledoc """
  Snapshot commit pipeline for the rhwp editor.

  When the editor coalesces ~50 ops or sits idle for 60s, it sends a fresh
  native HWP/HWPX blob to Phoenix. This module owns the server-side
  flow: writing the visual blob, writing the `.ir.json` companion, inserting the
  `Contract.RhwpSnapshot.Record` row, and rolling back R2 if any step fails.

  Runtime state snapshots remain in `Contract.Snapshot`; rhwp visual snapshots
  live in their own table so document-state persistence and editable-document
  persistence cannot overwrite each other at the same revision.

  ## Atomicity contract

  Either both R2 objects (`.hwp`/`.hwpx` + `.ir.json`) AND the
  `rhwp_snapshots` row
  exist, or none of them do. The committed pair is also the unit that
  `doc.get` reads — agents must never see a visual snapshot whose `.ir.json`
  is missing.

  Concretely:
    * The native visual snapshot is written by the server before `commit/4` runs.
    * We PUT the `.ir.json` (with one retry for transient R2 errors).
    * We INSERT the `rhwp_snapshots` row, marking the revision as committed.
    * If either of the previous two steps fails, we delete BOTH R2 keys
      (best-effort) and return `{:error, reason}`. The next snapshot
      attempt overwrites whatever fragments remain.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Contract.Repo
  alias Contract.RhwpSnapshot.Record

  @r2_max_attempts 3

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end

  @doc """
  Commit a rhwp snapshot: write the IR companion blob and insert the
  durable `rhwp_snapshots` row.

  `snapshot_key` is the R2 key under which `upload_and_commit/5` already wrote
  the native `.hwp` or `.hwpx` blob; the companion `.ir.json` is derived from it.

  Returns `{:ok, %Record{}}` or `{:error, reason}`. On error, both R2
  keys are deleted best-effort so the rhwp pipeline can safely retry on
  the next idle/op-count trigger.
  """
  @spec commit(binary() | nil, integer(), binary(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def commit(nil, _rev, _key, _ir), do: {:error, :no_document}

  def commit(document_id, revision, snapshot_key, ir)
      when is_binary(document_id) and is_integer(revision) and is_binary(snapshot_key) and
             is_map(ir) do
    ir_key = ir_key_for(snapshot_key)
    ir_body = Jason.encode!(ir)

    with {:ok, format} <- format_for_key(snapshot_key),
         content_type = content_type_for(format),
         {:ok, _} <-
           put_with_retry(ir_key, ir_body, content_type: "application/json"),
         {:ok, snapshot} <-
           insert_snapshot_row(
             document_id,
             revision,
             snapshot_key,
             ir_key,
             format,
             content_type,
             ir
           ) do
      {:ok, snapshot}
    else
      {:error, reason} ->
        rollback(snapshot_key, ir_key, reason)
        {:error, reason}
    end
  end

  @doc """
  Upload native HWP/HWPX bytes from the Phoenix server, then commit the
  companion IR and rhwp snapshot row.

  This is the single browser snapshot persistence path. The browser never
  talks to R2 directly, so CORS/presign failures cannot create a second
  persistence mode.
  """
  @spec upload_and_commit(binary() | nil, integer(), binary(), map(), binary()) ::
          {:ok, Record.t()} | {:error, term()}
  def upload_and_commit(nil, _rev, _body, _ir, _format), do: {:error, :no_document}

  def upload_and_commit(document_id, revision, body, ir, format)
      when is_binary(document_id) and is_integer(revision) and is_binary(body) and is_map(ir) and
             is_binary(format) do
    with {:ok, format} <- normalize_format(format),
         {:ok, key} <- key_for(document_id, revision, format),
         {:ok, _} <- put_with_retry(key, body, content_type: content_type_for(format)) do
      commit(document_id, revision, key, ir)
    end
  end

  @doc """
  Return the most recent native rhwp visual snapshot for a document.
  """
  @spec latest_for_document(binary() | nil) :: Record.t() | nil
  def latest_for_document(nil), do: nil

  def latest_for_document(document_id) when is_binary(document_id) do
    Repo.one(
      from s in Record,
        where: s.document_id == ^document_id,
        order_by: [desc: s.revision],
        limit: 1
    )
  end

  @spec latest_for_document(binary() | nil, binary() | nil) :: Record.t() | nil
  def latest_for_document(nil, _format), do: nil

  def latest_for_document(document_id, nil) when is_binary(document_id),
    do: latest_for_document(document_id)

  def latest_for_document(document_id, format)
      when is_binary(document_id) and is_binary(format) do
    with {:ok, format} <- normalize_format(format) do
      Repo.one(
        from s in Record,
          where: s.document_id == ^document_id and s.format == ^format,
          order_by: [desc: s.revision],
          limit: 1
      )
    else
      _ -> nil
    end
  end

  @spec get(binary(), integer(), binary()) :: Record.t() | nil
  def get(document_id, revision, format)
      when is_binary(document_id) and is_integer(revision) and is_binary(format) do
    Repo.get_by(Record, document_id: document_id, revision: revision, format: format)
  end

  @spec key_for(binary(), integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def key_for(document_id, revision, format)
      when is_binary(document_id) and is_integer(revision) and is_binary(format) do
    with {:ok, format} <- normalize_format(format) do
      {:ok, "documents/#{document_id}/snapshots/#{revision}.#{format}"}
    end
  end

  @doc """
  Companion key for a `.hwp` or `.hwpx` snapshot key. Exposed so other callers
  (e.g. doc.get presigning) can derive the IR key without re-reasoning
  about the convention.
  """
  @spec ir_key_for(binary()) :: binary()
  def ir_key_for(snapshot_key) when is_binary(snapshot_key) do
    cond do
      String.ends_with?(snapshot_key, ".hwp") ->
        String.replace_suffix(snapshot_key, ".hwp", ".ir.json")

      String.ends_with?(snapshot_key, ".hwpx") ->
        String.replace_suffix(snapshot_key, ".hwpx", ".ir.json")

      String.ends_with?(snapshot_key, ".ir.json") ->
        snapshot_key

      true ->
        snapshot_key <> ".ir.json"
    end
  end

  @spec content_type_for(binary()) :: binary()
  def content_type_for("hwp"), do: "application/x-hwp"
  def content_type_for("hwpx"), do: "application/hwp+zip"
  def content_type_for(_), do: "application/octet-stream"

  @spec normalize_format(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize_format(format) when is_binary(format) do
    case String.downcase(format) do
      "hwp" -> {:ok, "hwp"}
      "hwpx" -> {:ok, "hwpx"}
      other -> {:error, {:unsupported_rhwp_format, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp put_with_retry(key, body, opts), do: put_with_retry(key, body, opts, @r2_max_attempts)

  defp put_with_retry(key, body, opts, attempts_left) when attempts_left > 0 do
    case r2_driver().put(key, body, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempts_left > 1 and transient_r2_error?(reason) do
          # Tiny linear backoff — production R2 throttling is rare and
          # we don't want to block the LV process for long.
          Process.sleep(50 * (@r2_max_attempts - attempts_left + 1))
          put_with_retry(key, body, opts, attempts_left - 1)
        else
          err
        end
    end
  end

  defp put_with_retry(_key, _body, _opts, _), do: {:error, :r2_put_exhausted}

  # Heuristic: HTTP 5xx, connect refused, timeout etc. are retriable.
  # ExAws errors from the real R2 driver come back wrapped as
  # `{:r2_put_failed, {tag, ...}}`; test stubs may return a bare atom
  # reason. We treat all of these as transient — the alternative is to
  # bail immediately on the first network blip, which is worse than
  # spending a couple hundred ms on a doomed retry.
  defp transient_r2_error?({:r2_put_failed, _}), do: true
  defp transient_r2_error?(atom) when is_atom(atom), do: true
  defp transient_r2_error?(_), do: false

  defp format_for_key(key) do
    key
    |> Path.extname()
    |> String.trim_leading(".")
    |> normalize_format()
  end

  defp insert_snapshot_row(document_id, revision, r2_key, ir_key, format, content_type, ir) do
    %Record{}
    |> Record.changeset(%{
      document_id: document_id,
      revision: revision,
      projection: ir,
      r2_key: r2_key,
      ir_r2_key: ir_key,
      format: format,
      content_type: content_type
    })
    |> Repo.insert(
      on_conflict: {:replace, [:projection, :r2_key, :ir_r2_key, :format, :content_type]},
      conflict_target: [:document_id, :revision],
      returning: true
    )
  rescue
    # Bad data shape (e.g. a non-UUID `document_id` slipping through)
    # raises before the SQL ever runs. We catch here so that callers
    # always see {:error, _} and the R2 rollback path executes.
    e in Ecto.ChangeError -> {:error, {:insert_failed, Exception.message(e)}}
  end

  defp rollback(snapshot_key, ir_key, reason) do
    Logger.warning(
      "rhwp.snapshot rollback (snapshot=#{snapshot_key}, ir=#{ir_key}): #{inspect(reason)}"
    )

    _ = r2_driver().delete(ir_key)
    # The native snapshot was uploaded by the client BEFORE this handler ran. We
    # delete it too so a future presign can hand out the same revision
    # key without colliding with a stale half-committed object.
    _ = r2_driver().delete(snapshot_key)
    :ok
  end
end
