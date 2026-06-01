defmodule Contract.Repo do
  @moduledoc """
  Retired DB boundary kept only so legacy modules compile during the local-first cutover.
  """

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  def start_link(_opts), do: :ignore
  def config, do: stub([])
  def in_transaction?, do: stub(false)

  def all(_queryable, _opts \\ []), do: stub([])
  def all_by(_queryable, _clauses, _opts \\ []), do: stub([])
  def one(_queryable, _opts \\ []), do: stub(nil)

  def get(_queryable, _id, _opts \\ []), do: stub(nil)
  def get!(_queryable, _id, _opts \\ []), do: stub(nil)
  def get_by(_queryable, _clauses, _opts \\ []), do: stub(nil)
  def get_by!(_queryable, _clauses, _opts \\ []), do: stub(nil)

  def insert(_struct_or_changeset, _opts \\ []), do: stub({:error, :db_retired})
  def insert!(struct_or_changeset, _opts \\ []), do: stub(struct_or_changeset)
  def update(_changeset, _opts \\ []), do: stub({:error, :db_retired})
  def update!(changeset, _opts \\ []), do: stub(changeset)
  def delete(_struct, _opts \\ []), do: stub({:error, :db_retired})
  def delete!(struct, _opts \\ []), do: stub(struct)

  def delete_all(_queryable, _opts \\ []), do: stub({0, nil})
  def update_all(_queryable, _updates, _opts \\ []), do: stub({0, nil})

  def aggregate(_queryable, _aggregate), do: stub(0)
  def aggregate(_queryable, _aggregate, _field_or_opts), do: stub(0)
  def aggregate(_queryable, _aggregate, _field, _opts), do: stub(0)

  def exists?(_queryable, _opts \\ []), do: stub(false)
  def preload(struct_or_structs, _preloads, _opts \\ []), do: stub(struct_or_structs)

  def query(_sql, _params \\ [], _opts \\ []), do: stub({:error, :db_retired})
  def query!(_sql, _params \\ [], _opts \\ []), do: stub(%{columns: [], rows: [], num_rows: 0})

  def transaction(_fun_or_multi, _opts \\ []), do: stub({:error, :db_retired})
  def transact(_fun_or_multi, _opts \\ []), do: stub({:error, :db_retired})
  def rollback(reason), do: stub({:error, reason})

  defp stub(default), do: Process.get({__MODULE__, :stub_return}, default)
end
