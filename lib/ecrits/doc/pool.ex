defmodule Ecrits.Doc.Pool do
  @moduledoc """
  Multi-document registry (design §4.3).

  The Pool maps `document_id => %{kind, backing, editor_pid, path, revision}`
  and starts exactly one `Ecrits.Doc.Editor` per document. Documents run in
  parallel (separate Editors), while a single document's ops are serial (its
  Editor's mailbox).

    * `open/3`     — load a document into the pool (need not be the one the
      session is viewing).
    * `list/1`     — `[%{id, kind, path, revision, backing}]`.
    * `with_doc/3` — run a function against a document's Editor (serial).
    * `route/2`    — where the authoritative model lives: `{:server, editor}`
      for headless/Office docs, `{:browser, lv_pid}` for a viewed HWP doc.
    * `close/2`    — drop a document.

  `backing` is `:server` for the headless HWP/Office case (NIF authority). The
  `:browser` backing (viewed HWP → WASM authority, agent ops pushed to the
  LiveView) is represented but not exercised here: browser registration is the
  live LiveView wiring left for follow-up. `route/2` returns `{:browser, pid}`
  once a viewer registers via `attach_browser/3`.
  """

  use GenServer

  alias Ecrits.Doc
  alias Ecrits.Doc.Editor

  @default_name __MODULE__

  @type document_id :: String.t()

  # --- client API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @default_name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Open `path` into the default-named pool. Returns a stable `document_id`
  (same path/kind opened twice returns the same id and reuses the Editor).
  """
  @spec open(String.t(), keyword()) :: {:ok, document_id()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) and is_list(opts),
    do: open(@default_name, path, opts)

  @doc """
  Open `path` into an explicit `pool` process.

  Kept distinct from `open/2` (path + opts) to avoid the two-defaults arg
  ambiguity that would otherwise bind a path string to the `pool` parameter.
  """
  @spec open(GenServer.server(), String.t(), keyword()) ::
          {:ok, document_id()} | {:error, term()}
  def open(pool, path, opts) when is_binary(path) and is_list(opts) do
    GenServer.call(pool, {:open, path, opts})
  end

  @spec list(GenServer.server()) :: [map()]
  def list(pool \\ @default_name), do: GenServer.call(pool, :list)

  @spec with_doc(GenServer.server(), document_id(), (Editor.t() -> term())) ::
          term() | {:error, :not_found}
  def with_doc(pool \\ @default_name, document_id, fun) when is_function(fun, 1) do
    case GenServer.call(pool, {:editor, document_id}) do
      {:ok, editor} -> fun.(editor)
      {:error, _} = error -> error
    end
  end

  @doc "Authoritative location of a document's model."
  @spec route(GenServer.server(), document_id()) ::
          {:server, Editor.t()} | {:browser, pid()} | {:error, :not_found}
  def route(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:route, document_id})

  @doc "Register a viewing LiveView so the agent's ops route to the browser model."
  @spec attach_browser(GenServer.server(), document_id(), pid()) :: :ok | {:error, :not_found}
  def attach_browser(pool \\ @default_name, document_id, lv_pid) when is_pid(lv_pid),
    do: GenServer.call(pool, {:attach_browser, document_id, lv_pid})

  @spec info(GenServer.server(), document_id()) :: {:ok, map()} | {:error, :not_found}
  def info(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:info, document_id})

  @spec close(GenServer.server(), document_id()) :: :ok | {:error, :not_found}
  def close(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:close, document_id})

  # --- server --------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, %{sup: sup, docs: %{}, by_path: %{}}}
  end

  @impl true
  def handle_call({:open, path, opts}, _from, st) do
    kind = Keyword.get(opts, :kind, :hwp)

    case Doc.backend_for(kind) do
      nil ->
        {:reply, {:error, {:unsupported_kind, kind}}, st}

      backend ->
        document_id = Keyword.get(opts, :document_id) || document_id_for(path, kind)

        case Map.get(st.docs, document_id) do
          %{editor: editor} when is_pid(editor) ->
            if Process.alive?(editor),
              do: {:reply, {:ok, document_id}, st},
              else: do_open(st, document_id, path, kind, backend, opts)

          _ ->
            do_open(st, document_id, path, kind, backend, opts)
        end
    end
  end

  def handle_call(:list, _from, st) do
    entries =
      Enum.map(st.docs, fn {id, doc} ->
        %{
          id: id,
          kind: doc.kind,
          path: doc.path,
          revision: revision(doc),
          backing: backing(doc)
        }
      end)

    {:reply, entries, st}
  end

  def handle_call({:editor, document_id}, _from, st) do
    {:reply, fetch_editor(st, document_id), st}
  end

  def handle_call({:route, document_id}, _from, st) do
    reply =
      case Map.get(st.docs, document_id) do
        %{browser: lv} when is_pid(lv) -> {:browser, lv}
        %{editor: editor} when is_pid(editor) -> {:server, editor}
        _ -> {:error, :not_found}
      end

    {:reply, reply, st}
  end

  def handle_call({:attach_browser, document_id, lv_pid}, _from, st) do
    case Map.get(st.docs, document_id) do
      nil ->
        {:reply, {:error, :not_found}, st}

      doc ->
        Process.monitor(lv_pid)
        st = put_in(st.docs[document_id], Map.put(doc, :browser, lv_pid))
        {:reply, :ok, st}
    end
  end

  def handle_call({:info, document_id}, _from, st) do
    reply =
      case Map.get(st.docs, document_id) do
        nil ->
          {:error, :not_found}

        doc ->
          {:ok,
           %{
             id: document_id,
             kind: doc.kind,
             path: doc.path,
             revision: revision(doc),
             backing: backing(doc)
           }}
      end

    {:reply, reply, st}
  end

  def handle_call({:close, document_id}, _from, st) do
    case Map.pop(st.docs, document_id) do
      {nil, _docs} ->
        {:reply, {:error, :not_found}, st}

      {doc, docs} ->
        if is_pid(doc.editor) and Process.alive?(doc.editor) do
          DynamicSupervisor.terminate_child(st.sup, doc.editor)
        end

        by_path = Map.delete(st.by_path, doc.path)
        {:reply, :ok, %{st | docs: docs, by_path: by_path}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    # an editor or an attached browser LV went down
    docs =
      st.docs
      |> Enum.reduce(%{}, fn {id, doc}, acc ->
        cond do
          doc.editor == pid -> acc
          Map.get(doc, :browser) == pid -> Map.put(acc, id, Map.delete(doc, :browser))
          true -> Map.put(acc, id, doc)
        end
      end)

    {:noreply, %{st | docs: docs}}
  end

  # --- helpers -------------------------------------------------------------

  defp do_open(st, document_id, path, kind, backend, opts) do
    editor_opts = [
      document_id: document_id,
      kind: kind,
      backend: backend,
      path: path,
      open_opts: Keyword.get(opts, :open_opts, [])
    ]

    case DynamicSupervisor.start_child(st.sup, {Editor, editor_opts}) do
      {:ok, editor} ->
        Process.monitor(editor)

        doc = %{kind: kind, backend: backend, path: path, editor: editor, browser: nil}

        st = %{
          st
          | docs: Map.put(st.docs, document_id, doc),
            by_path: Map.put(st.by_path, path, document_id)
        }

        {:reply, {:ok, document_id}, st}

      {:error, reason} ->
        {:reply, {:error, {:open_failed, reason}}, st}
    end
  end

  defp fetch_editor(st, document_id) do
    case Map.get(st.docs, document_id) do
      %{editor: editor} when is_pid(editor) -> {:ok, editor}
      _ -> {:error, :not_found}
    end
  end

  defp revision(%{editor: editor}) when is_pid(editor) do
    if Process.alive?(editor), do: Editor.revision(editor), else: 0
  end

  defp revision(_doc), do: 0

  defp backing(%{browser: lv}) when is_pid(lv), do: :browser
  defp backing(_doc), do: :server

  defp document_id_for(path, kind) do
    hash =
      :crypto.hash(:sha256, "#{kind}:#{path}")
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 16)

    "d_#{kind}_#{hash}"
  end
end
