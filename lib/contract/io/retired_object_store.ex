defmodule Contract.IO.RetiredObjectStore do
  @moduledoc """
  Retired object-store driver for legacy SaaS code paths.

  Active local-first document snapshots/checkpoints are persisted under the
  workspace `.contract` directory. Legacy DB-backed callers keep compiling,
  but no cloud storage request is attempted.
  """

  @retired_error {:error, :cloud_storage_retired}

  @spec put(binary(), binary(), keyword()) :: {:error, :cloud_storage_retired}
  def put(_key, _body, _opts \\ []), do: @retired_error

  @spec get(binary(), keyword()) :: {:error, :cloud_storage_retired}
  def get(_key, _opts \\ []), do: @retired_error

  @spec delete(binary(), keyword()) :: {:error, :cloud_storage_retired}
  def delete(_key, _opts \\ []), do: @retired_error

  @spec presigned_url(binary(), keyword()) :: {:error, :cloud_storage_retired}
  def presigned_url(_key, _opts \\ []), do: @retired_error
end
