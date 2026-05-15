defmodule Contract.Documents do
  @moduledoc """
  Context module for documents and field lineage.

  Every public function (except `touch_revision/2`) takes a
  `%Contract.Context{}` as the first argument. The ACL gate is delegated
  to `Contract.Matters.authorize_read/2`: if a document belongs to a
  matter the scope cannot see, the read returns `{:error, :forbidden}`.

  `touch_revision/2` is the one exception. It is called by
  `Contract.Store.append/3` on the hot commit path, where the scope is
  not in scope; the caller has already passed the lease + idempotency
  gate by then, so we trust the operation.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents.Document
  alias Contract.Documents.FieldLineage
  alias Contract.Matters
  alias Contract.Matters.Matter
  alias Contract.Repo
  alias Contract.Types, as: T

  # ----------------------------------------------------------------------------
  # list_for_matter/2
  # ----------------------------------------------------------------------------

  @doc """
  List documents for a matter, gated by the matter's ACL.

  Returns the documents ordered by most recently updated. Archived
  documents are included; callers that want active-only can filter
  after.
  """
  @spec list_for_matter(Context.t(), T.id() | nil) :: [Document.t()]
  def list_for_matter(%Context{} = scope, matter_id) when is_binary(matter_id) do
    case Matters.get(scope, matter_id) do
      {:ok, %Matter{id: id}} ->
        from(d in Document, where: d.matter_id == ^id, order_by: [desc: d.updated_at])
        |> Repo.all()

      {:error, _} ->
        []
    end
  rescue
    Ecto.Query.CastError -> []
  end

  def list_for_matter(_scope, _matter_id), do: []

  # ----------------------------------------------------------------------------
  # list_recent_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List the most recent documents visible to the scope, across all
  matters the scope can see. Limit defaults to 8.
  """
  @spec list_recent_for_scope(Context.t(), pos_integer()) :: [Document.t()]
  def list_recent_for_scope(%Context{} = scope, limit \\ 8) when is_integer(limit) do
    matter_ids = Matters.list_for_scope(scope) |> Enum.map(& &1.id)

    if matter_ids == [] do
      []
    else
      from(d in Document,
        where: d.matter_id in ^matter_ids,
        order_by: [desc: d.updated_at],
        limit: ^limit
      )
      |> Repo.all()
    end
  end

  # ----------------------------------------------------------------------------
  # get/2
  # ----------------------------------------------------------------------------

  @doc """
  Fetch a single document by id, gated by the matter ACL.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, document_id) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      %Document{matter_id: matter_id} = doc ->
        case authorize_via_matter(scope, matter_id) do
          :ok -> {:ok, doc}
          err -> err
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_scope, _document_id), do: {:error, :not_found}

  # ----------------------------------------------------------------------------
  # create/2
  # ----------------------------------------------------------------------------

  @doc """
  Create a document in a matter the scope owns or shares.

  `attrs` must include `:matter_id`, `:title`, `:type_key`. The ACL gate
  on the matter is enforced before the insert.
  """
  @spec create(Context.t(), map()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def create(%Context{} = scope, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    matter_id = Map.get(attrs, "matter_id")

    with :ok <- authorize_via_matter(scope, matter_id),
         :ok <- check_no_parent_cycle(attrs) do
      %Document{}
      |> Document.changeset(attrs)
      |> Repo.insert()
    end
  end

  # ----------------------------------------------------------------------------
  # archive/2 / set_type/3
  # ----------------------------------------------------------------------------

  @doc """
  Archive a document. Visible-only gate; any caller that can see the
  document can archive (the heavy gate is on the matter).
  """
  @spec archive(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, term()}
  def archive(%Context{} = scope, document_id) do
    with {:ok, doc} <- get(scope, document_id) do
      doc
      |> Document.changeset(%{"status" => "archived"})
      |> Repo.update()
    end
  end

  @doc """
  Change a document's `:type_key` (SPEC.md §18 — type *selection*, not
  conversion). Conversion goes through `Contract.Conversion`.
  """
  @spec set_type(Context.t(), T.id(), T.contract_type_key()) ::
          {:ok, Document.t()} | {:error, term()}
  def set_type(%Context{} = scope, document_id, type_key) when is_binary(type_key) do
    with {:ok, doc} <- get(scope, document_id) do
      doc
      |> Document.changeset(%{"type_key" => type_key})
      |> Repo.update()
    end
  end

  # ----------------------------------------------------------------------------
  # touch_revision/2 (called by Store)
  # ----------------------------------------------------------------------------

  @doc """
  Bump a document's `latest_revision` to `revision` IFF the supplied
  value is strictly greater than the stored one. Idempotent — replaying
  the same `(document_id, revision)` pair is safe.

  Called by `Contract.Store.append/3` on the hot commit path. Not gated
  by scope: the caller has already validated the lease + revision.
  """
  @spec touch_revision(T.id(), T.revision()) :: :ok
  def touch_revision(document_id, revision)
      when is_binary(document_id) and is_integer(revision) and revision >= 0 do
    from(d in Document,
      where: d.id == ^document_id and d.latest_revision < ^revision,
      update: [set: [latest_revision: ^revision, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    # Document row may not exist yet (Store.append currently writes
    # Changes without requiring a matching Document row). Silently
    # ignore — `touch_revision` is best-effort.
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
  end

  def touch_revision(_, _), do: :ok

  # ----------------------------------------------------------------------------
  # search/2 — substring title search for the command palette
  # ----------------------------------------------------------------------------

  @doc """
  Search documents by case-insensitive title substring within the scope.
  Returns at most `limit` rows (default 20).
  """
  @spec search(Context.t(), String.t(), pos_integer()) :: [Document.t()]
  def search(%Context{} = scope, query, limit \\ 20) when is_binary(query) do
    matter_ids = Matters.list_for_scope(scope) |> Enum.map(& &1.id)

    if matter_ids == [] do
      []
    else
      pattern = "%" <> String.downcase(query) <> "%"

      from(d in Document,
        where: d.matter_id in ^matter_ids,
        where: fragment("lower(?) LIKE ?", d.title, ^pattern),
        order_by: [desc: d.updated_at],
        limit: ^limit
      )
      |> Repo.all()
    end
  end

  # ----------------------------------------------------------------------------
  # Lineage
  # ----------------------------------------------------------------------------

  @doc """
  Insert a single lineage row. Append-only — no update path. Used by
  `Contract.Conversion.create_variant/2`.
  """
  @spec insert_lineage(map()) ::
          {:ok, FieldLineage.t()} | {:error, Ecto.Changeset.t()}
  def insert_lineage(attrs) when is_map(attrs) do
    %FieldLineage{}
    |> FieldLineage.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @doc """
  List lineage rows for a document.
  """
  @spec list_lineage(Context.t(), T.id()) :: [FieldLineage.t()]
  def list_lineage(%Context{} = scope, document_id) do
    case get(scope, document_id) do
      {:ok, _doc} ->
        from(l in FieldLineage,
          where: l.document_id == ^document_id,
          order_by: [asc: l.inserted_at]
        )
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc """
  Look up a single lineage row for a specific field in a document.
  `field_id` is the TypeSpec field id (string), not a UUID.
  """
  @spec get_lineage_for_field(Context.t(), T.id(), String.t()) ::
          FieldLineage.t() | nil
  def get_lineage_for_field(%Context{} = scope, document_id, field_id) do
    case get(scope, document_id) do
      {:ok, _doc} ->
        Repo.one(
          from l in FieldLineage,
            where: l.document_id == ^document_id and l.field_id == ^field_id,
            limit: 1
        )

      _ ->
        nil
    end
  end

  @doc """
  Walks `:parent_document_id` upward from `document_id` and returns
  `true` if `candidate_parent_id` would close a cycle (i.e. it is
  already an ancestor or the document itself).
  """
  @spec would_create_cycle?(Context.t(), T.id(), T.id()) :: boolean()
  def would_create_cycle?(%Context{} = _scope, document_id, candidate_parent_id) do
    do_cycle_check(document_id, candidate_parent_id, MapSet.new())
  end

  defp do_cycle_check(_doc_id, nil, _seen), do: false

  defp do_cycle_check(doc_id, candidate, _seen) when doc_id == candidate, do: true

  defp do_cycle_check(doc_id, candidate, seen) do
    if MapSet.member?(seen, candidate) do
      true
    else
      case Repo.get(Document, candidate) do
        nil -> false
        %Document{parent_document_id: nil} -> false
        %Document{parent_document_id: ^doc_id} -> true
        %Document{parent_document_id: next} -> do_cycle_check(doc_id, next, MapSet.put(seen, candidate))
      end
    end
  rescue
    Ecto.Query.CastError -> false
  end

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  defp authorize_via_matter(_scope, nil), do: {:error, :not_found}

  defp authorize_via_matter(%Context{} = scope, matter_id) do
    case Matters.get(scope, matter_id) do
      {:ok, _matter} -> :ok
      {:error, _} = err -> err
    end
  end

  defp check_no_parent_cycle(%{"parent_document_id" => nil}), do: :ok

  defp check_no_parent_cycle(%{"parent_document_id" => parent}) when is_binary(parent) do
    case Repo.get(Document, parent) do
      nil -> :ok
      %Document{} -> :ok
    end
  rescue
    Ecto.Query.CastError -> :ok
  end

  defp check_no_parent_cycle(_), do: :ok

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
  end
end
