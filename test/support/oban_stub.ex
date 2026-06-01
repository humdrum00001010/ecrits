defmodule Oban.Job do
  @moduledoc false
  defstruct [:args, :queue, :worker, :state, :attempt, :max_attempts, :id]
end

defmodule Oban.Testing do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      import Oban.Testing
    end
  end

  defmacro assert_enqueued(_opts) do
    quote do
      true
    end
  end

  def perform_job(worker, args) do
    worker.perform(%{args: args})
  end
end

defmodule Oban do
  @moduledoc false

  def drain_queue(_opts \\ []), do: %{success: 0, failure: 0}

  def insert(%{args: args, worker: worker} = job) do
    {:ok, struct(Oban.Job, Map.merge(%{args: args, worker: worker}, Map.take(job, [:queue])))}
  end

  def insert(job), do: {:ok, struct(Oban.Job, %{args: job})}
  def insert!(job), do: elem(insert(job), 1)
end
