defmodule Contract.Documents do
  @moduledoc """
  Context module for documents and field lineage.

  Every public function (except `touch_revision/2` and friends) takes a
  `%Contract.Context{}` as the first argument. The ACL gate is owner-based:
  the caller may only read/write documents whose `owner_id` matches
  `ctx.user.id` (SPEC.md v0.5 — Matter container removed).

  `touch_revision/2`, `set_title/2`, `set_type/2`, `set_status/2` are
  scope-less helpers called by `Contract.Store.append/3` on the hot
  commit path. The caller has already passed the lease + idempotency
  gate by then, so we trust the operation.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents.Document
  alias Contract.Repo
  alias Contract.Types, as: T

  # ----------------------------------------------------------------------------
  # list_recent_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List the most recent documents visible to the scope (i.e. owned by
  `ctx.user`).

  Accepts either a positive integer (legacy positional API) or a keyword
  list with `:limit`. The default limit is `20`.
  """
  @default_recent_limit 20

  @spec list_recent_for_scope(Context.t(), pos_integer() | keyword()) :: [Document.t()]
  def list_recent_for_scope(scope, opts_or_limit \\ [])

  def list_recent_for_scope(%Context{} = scope, limit)
      when is_integer(limit) and limit > 0 do
    do_list_recent_for_scope(scope, limit)
  end

  def list_recent_for_scope(%Context{} = scope, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)
    do_list_recent_for_scope(scope, limit)
  end

  defp do_list_recent_for_scope(%Context{user: nil}, _limit), do: []

  defp do_list_recent_for_scope(%Context{user: %{id: user_id}}, limit)
       when is_integer(limit) and limit > 0 do
    from(d in Document,
      where: d.owner_id == ^user_id,
      order_by: [desc: d.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # ----------------------------------------------------------------------------
  # list_all_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List ALL documents visible to the scope (i.e. owned by `ctx.user`),
  ordered by `updated_at DESC`. Unlike `list_recent_for_scope/2`, no
  document is dropped for being old — the dashboard surface wants the
  full library, not a "recent" slice (2026-05-17 owner directive).

  Accepts an optional keyword list with `:limit`. Defaults to a very
  high cap (10_000) so callers that pass no limit still get the full
  set without blowing memory in pathological cases.
  """
  @default_all_limit 10_000

  @spec list_all_for_scope(Context.t(), keyword()) :: [Document.t()]
  def list_all_for_scope(scope, opts \\ [])

  def list_all_for_scope(%Context{user: nil}, _opts), do: []

  def list_all_for_scope(%Context{user: %{id: user_id}}, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_all_limit)

    from(d in Document,
      where: d.owner_id == ^user_id,
      order_by: [desc: d.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # ----------------------------------------------------------------------------
  # get/2
  # ----------------------------------------------------------------------------

  @doc """
  Fetch a single document by id, gated by owner ACL.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, document_id) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      %Document{} = doc ->
        case authorize_owner(scope, doc) do
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
  Create a document owned by `ctx.user`.

  `attrs` should include `:title`. `:owner_id` is derived from
  `ctx.user.id` and CANNOT be overridden by `attrs`. `:type_key` is
  optional per SPEC.md §18.

  v0.5: `:matter_id` in `attrs` is silently dropped — Matter is gone
  in v1.
  """
  @spec create(Context.t(), %{
          optional(:title) => binary,
          optional(:type_key) => binary | nil
        }) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create(%Context{user: nil}, _attrs), do: {:error, :forbidden}

  def create(%Context{user: %{id: user_id}} = _scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.drop(["matter_id", "document_id"])
      |> Map.put("owner_id", user_id)

    document = document_with_optional_id(attrs)

    with :ok <- check_no_parent_cycle(attrs) do
      document
      |> Document.changeset(Map.drop(attrs, ["id"]))
      |> Repo.insert()
    end
  end

  # ----------------------------------------------------------------------------
  # archive/2 / set_type/3
  # ----------------------------------------------------------------------------

  @doc """
  Archive a document. Owner-only.
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
  # set_title/2, set_type/2, set_status/2 (called by Store on propagation)
  # ----------------------------------------------------------------------------

  @doc """
  Set a document's `:title`. Called from `Contract.Store.append/3` on the
  hot commit path to mirror the engine's document-level `:set_attr` op
  onto the `documents` table. Not gated by scope.
  """
  @spec set_title(T.id(), String.t()) :: :ok
  def set_title(document_id, title) when is_binary(document_id) and is_binary(title) do
    from(d in Document,
      where: d.id == ^document_id,
      update: [set: [title: ^title, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_title(_, _), do: :ok

  @doc """
  Set a document's `:type_key`. Scope-less variant used by
  `Contract.Store.append/3`.
  """
  @spec set_type(T.id(), String.t() | nil) :: :ok
  def set_type(document_id, type_key) when is_binary(document_id) do
    cast =
      cond do
        is_binary(type_key) -> type_key
        is_atom(type_key) and not is_nil(type_key) -> Atom.to_string(type_key)
        true -> nil
      end

    from(d in Document,
      where: d.id == ^document_id,
      update: [set: [type_key: ^cast, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_type(_, _), do: :ok

  @doc """
  Set a document's `:status`. Scope-less variant used by
  `Contract.Store.append/3`.
  """
  @spec set_status(T.id(), atom() | String.t()) :: :ok
  def set_status(document_id, status) when is_binary(document_id) do
    cast =
      case status do
        s when is_atom(s) ->
          s

        s when is_binary(s) ->
          try do
            String.to_existing_atom(s)
          rescue
            ArgumentError -> nil
          end

        _ ->
          nil
      end

    if cast in [:draft, :importing, :editing, :reviewing, :export_ready, :archived] do
      from(d in Document,
        where: d.id == ^document_id,
        update: [set: [status: ^cast, updated_at: ^now()]]
      )
      |> Repo.update_all([])
    end

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_status(_, _), do: :ok

  # ----------------------------------------------------------------------------
  # touch_revision/2 (called by Store)
  # ----------------------------------------------------------------------------

  @doc """
  Bump a document's `latest_revision` to `revision` IFF the supplied
  value is strictly greater than the stored one. Idempotent.
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
  def search(scope, query, limit \\ 20)

  def search(%Context{user: nil}, _query, _limit), do: []

  def search(%Context{user: %{id: user_id}}, query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    pattern = "%" <> String.downcase(query) <> "%"

    from(d in Document,
      where: d.owner_id == ^user_id,
      where: fragment("lower(?) LIKE ?", d.title, ^pattern),
      order_by: [desc: d.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  def search(_scope, _query, _limit), do: []

  # ----------------------------------------------------------------------------
  # Lineage
  # ----------------------------------------------------------------------------

  alias Contract.Documents.FieldLineage

  @doc """
  Insert a single lineage row. Append-only — no update path.
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
  `true` if `candidate_parent_id` would close a cycle.
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
        nil ->
          false

        %Document{parent_document_id: nil} ->
          false

        %Document{parent_document_id: ^doc_id} ->
          true

        %Document{parent_document_id: next} ->
          do_cycle_check(doc_id, next, MapSet.put(seen, candidate))
      end
    end
  rescue
    Ecto.Query.CastError -> false
  end

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  # Owner-based ACL. Legacy ownerless rows are not globally visible.
  defp authorize_owner(_scope, %Document{owner_id: nil}), do: {:error, :forbidden}

  defp authorize_owner(%Context{user: %{id: user_id}}, %Document{owner_id: owner_id})
       when owner_id == user_id,
       do: :ok

  defp authorize_owner(_scope, _doc), do: {:error, :forbidden}

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

  defp document_with_optional_id(%{"id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> %Document{id: uuid}
      :error -> %Document{}
    end
  end

  defp document_with_optional_id(_attrs), do: %Document{}

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
