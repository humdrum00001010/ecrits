defmodule Contract.Packets do
  @moduledoc """
  Owner-scoped packet API.

  Packets are a lightweight layer above documents. Documents keep their own
  ownership and lifecycle; packet membership lives in `packet_documents`.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Packets.Packet
  alias Contract.Packets.PacketDocument
  alias Contract.Repo
  alias Contract.Types, as: T

  @doc """
  List packets owned by the scope user.
  """
  @spec list_packets_for_scope(Context.t()) :: [Packet.t()]
  def list_packets_for_scope(%Context{user: nil}), do: []

  def list_packets_for_scope(%Context{user: %{id: user_id}}) do
    from(p in Packet,
      where: p.owner_id == ^user_id,
      order_by: [desc: p.updated_at]
    )
    |> Repo.all()
  end

  def list_packets_for_scope(_scope), do: []

  @doc """
  Fetch the deterministic packet target for one owned document.
  """
  @spec packet_for_document(Context.t(), T.id()) ::
          {:ok, Packet.t()} | {:error, :not_found | :forbidden}
  def packet_for_document(%Context{user: nil}, _document_id), do: {:error, :forbidden}

  def packet_for_document(%Context{user: %{id: user_id}} = scope, document_id)
      when is_binary(document_id) do
    with {:ok, %Document{}} <- Documents.get(scope, document_id) do
      case Repo.one(packet_for_document_query(user_id, document_id)) do
        %Packet{} = packet -> {:ok, packet}
        nil -> {:error, :not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def packet_for_document(_scope, _document_id), do: {:error, :not_found}

  @doc """
  Fetch one packet and preload linked documents.
  """
  @spec get_packet(Context.t(), T.id()) ::
          {:ok, Packet.t()} | {:error, :not_found | :forbidden}
  def get_packet(%Context{} = scope, packet_id) when is_binary(packet_id) do
    with {:ok, packet} <- get_owned_packet(scope, packet_id) do
      {:ok, preload_packet(packet)}
    end
  end

  def get_packet(_scope, _packet_id), do: {:error, :not_found}

  @doc """
  Create a packet owned by `ctx.user`.
  """
  @spec create_packet(Context.t(), map()) ::
          {:ok, Packet.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_packet(%Context{user: nil}, _attrs), do: {:error, :forbidden}

  def create_packet(%Context{user: %{id: user_id}}, attrs) when is_map(attrs) do
    %Packet{owner_id: user_id}
    |> Packet.changeset(attrs)
    |> Repo.insert()
  end

  def create_packet(_scope, _attrs), do: {:error, :forbidden}

  @doc """
  Update an owned packet.
  """
  @spec update_packet(Context.t(), Packet.t(), map()) ::
          {:ok, Packet.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_packet(%Context{} = scope, %Packet{} = packet, attrs) when is_map(attrs) do
    with :ok <- authorize_owner(scope, packet) do
      packet
      |> Packet.changeset(attrs)
      |> Repo.update()
    end
  end

  def update_packet(_scope, _packet, _attrs), do: {:error, :forbidden}

  @doc """
  Delete an owned packet. Packet membership rows are removed by the database
  foreign key. Documents that lose their final packet reference are deleted.
  """
  @spec delete_packet(Context.t(), T.id() | Packet.t()) ::
          {:ok, Packet.t()} | {:error, term()}
  def delete_packet(%Context{user: nil}, _packet), do: {:error, :forbidden}

  def delete_packet(%Context{} = scope, %Packet{} = packet) do
    with :ok <- authorize_owner(scope, packet) do
      do_delete_packet(scope, packet)
    end
  end

  def delete_packet(%Context{} = scope, packet_id) when is_binary(packet_id) do
    with {:ok, %Packet{} = packet} <- get_owned_packet(scope, packet_id) do
      do_delete_packet(scope, packet)
    end
  end

  def delete_packet(_scope, _packet), do: {:error, :not_found}

  @doc """
  Count packet references for one owned document.
  """
  @spec document_ref_count(Context.t(), T.id()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | :forbidden}
  def document_ref_count(%Context{user: nil}, _document_id), do: {:error, :forbidden}

  def document_ref_count(%Context{user: %{id: user_id}} = scope, document_id)
      when is_binary(document_id) do
    with {:ok, %Document{}} <- Documents.get(scope, document_id) do
      count =
        from(pd in PacketDocument,
          join: p in Packet,
          on: p.id == pd.packet_id,
          where: pd.document_id == ^document_id and p.owner_id == ^user_id
        )
        |> Repo.aggregate(:count)

      {:ok, count}
    end
  end

  def document_ref_count(_scope, _document_id), do: {:error, :not_found}

  @doc """
  Attach one owned document to one owned packet.

  Re-attaching the same document returns the existing join row.
  """
  @spec attach_document(Context.t(), T.id(), T.id(), map()) ::
          {:ok, PacketDocument.t()} | {:error, term()}
  def attach_document(scope, packet_id, document_id, attrs \\ %{})

  def attach_document(%Context{user: nil}, _packet_id, _document_id, _attrs),
    do: {:error, :forbidden}

  def attach_document(%Context{} = scope, packet_id, document_id, attrs)
      when is_binary(packet_id) and is_binary(document_id) and is_map(attrs) do
    with {:ok, %Packet{} = packet} <- get_owned_packet(scope, packet_id),
         {:ok, %Document{} = document} <- Documents.get(scope, document_id) do
      case get_packet_document(packet.id, document.id) do
        %PacketDocument{} = packet_document ->
          {:ok, packet_document}

        nil ->
          %PacketDocument{packet_id: packet.id, document_id: document.id}
          |> PacketDocument.changeset(attrs)
          |> Repo.insert()
      end
    end
  end

  def attach_document(_scope, _packet_id, _document_id, _attrs), do: {:error, :not_found}

  @doc """
  Detach a document from an owned packet. Missing membership is already detached.
  """
  @spec detach_document(Context.t(), T.id(), T.id()) :: :ok | {:error, term()}
  def detach_document(%Context{} = scope, packet_id, document_id)
      when is_binary(packet_id) and is_binary(document_id) do
    with {:ok, %Packet{} = packet} <- get_owned_packet(scope, packet_id) do
      repeatable_read_transaction(fn ->
        {deleted_count, _} =
          from(pd in PacketDocument,
            where: pd.packet_id == ^packet.id and pd.document_id == ^document_id
          )
          |> Repo.delete_all()

        if deleted_count > 0 do
          case delete_document_if_unreferenced(scope, document_id) do
            {:ok, r2_keys} -> r2_keys
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          []
        end
      end)
      |> case do
        {:ok, r2_keys} ->
          :ok = Documents.delete_r2_objects_async(r2_keys)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def detach_document(_scope, _packet_id, _document_id), do: {:error, :not_found}

  @doc """
  List owned documents not already attached to the packet.
  """
  @spec list_available_documents(Context.t(), T.id()) :: [Document.t()]
  def list_available_documents(%Context{user: nil}, _packet_id), do: []

  def list_available_documents(%Context{user: %{id: user_id}} = scope, packet_id)
      when is_binary(packet_id) do
    with {:ok, %Packet{} = packet} <- get_owned_packet(scope, packet_id) do
      attached_document_ids =
        from(pd in PacketDocument,
          where: pd.packet_id == ^packet.id,
          select: pd.document_id
        )

      from(d in Document,
        where: d.owner_id == ^user_id,
        where: d.id not in subquery(attached_document_ids),
        order_by: [desc: d.updated_at]
      )
      |> Repo.all()
    else
      _ -> []
    end
  rescue
    Ecto.Query.CastError -> []
  end

  def list_available_documents(_scope, _packet_id), do: []

  defp get_owned_packet(%Context{} = scope, packet_id) do
    case fetch_packet(packet_id) do
      nil ->
        {:error, :not_found}

      %Packet{} = packet ->
        case authorize_owner(scope, packet) do
          :ok -> {:ok, packet}
          err -> err
        end
    end
  end

  defp fetch_packet(packet_id) when is_binary(packet_id) do
    Repo.get(Packet, packet_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp fetch_packet(_packet_id), do: nil

  defp packet_for_document_query(user_id, document_id) do
    from(p in Packet,
      join: pd in PacketDocument,
      on: pd.packet_id == p.id,
      where: p.owner_id == ^user_id and pd.document_id == ^document_id,
      order_by: [desc: p.updated_at, asc: p.id],
      limit: 1
    )
  end

  defp do_delete_packet(%Context{} = scope, %Packet{} = packet) do
    repeatable_read_transaction(fn ->
      document_ids = attached_document_ids(packet.id)

      case Repo.delete(packet) do
        {:ok, deleted_packet} ->
          case delete_orphaned_documents(scope, document_ids) do
            {:ok, r2_keys} -> {deleted_packet, r2_keys}
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {%Packet{} = deleted_packet, r2_keys}} ->
        :ok = Documents.delete_r2_objects_async(r2_keys)
        {:ok, deleted_packet}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repeatable_read_transaction(fun) when is_function(fun, 0) do
    already_in_transaction? = Repo.in_transaction?()

    Repo.transaction(fn ->
      unless already_in_transaction? do
        set_repeatable_read!()
      end

      fun.()
    end)
  end

  defp set_repeatable_read! do
    unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
    end

    :ok
  end

  defp attached_document_ids(packet_id) do
    from(pd in PacketDocument,
      where: pd.packet_id == ^packet_id,
      select: pd.document_id
    )
    |> Repo.all()
  end

  defp delete_orphaned_documents(%Context{} = scope, document_ids) do
    document_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn document_id, {:ok, acc} ->
      case delete_document_if_unreferenced(scope, document_id) do
        {:ok, r2_keys} -> {:cont, {:ok, acc ++ r2_keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_document_if_unreferenced(%Context{} = scope, document_id) do
    case document_ref_count(scope, document_id) do
      {:ok, 0} ->
        case Documents.delete_db(scope, document_id) do
          {:ok, {%Document{}, r2_keys}} -> {:ok, r2_keys}
          {:error, :not_found} -> {:ok, []}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _count} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp preload_packet(%Packet{} = packet) do
    Repo.preload(packet, [:documents, packet_documents: :document])
  end

  defp get_packet_document(packet_id, document_id) do
    Repo.one(
      from(pd in PacketDocument,
        where: pd.packet_id == ^packet_id and pd.document_id == ^document_id
      )
    )
  end

  defp authorize_owner(%Context{user: %{id: user_id}}, %Packet{owner_id: owner_id})
       when owner_id == user_id,
       do: :ok

  defp authorize_owner(_scope, _packet), do: {:error, :forbidden}
end
