defmodule Ecrits.Doc do
  @moduledoc """
  Engine-adapter behaviour for editable documents (the MCP document abstraction).

  This is the `Ecrits.Doc` behaviour from the document-editing MCP design
  (`docs/plans/2026-06-04-doc-editing-mcp-design.md`, §4.2). It mirrors each
  engine's own object/property model so that a *small* set of reflective MCP
  tools (`doc.outline`/`read`/`find`/`get`/`set`/`edit`/`apply_style`/`save`)
  can drive any backend without one tool per editing operation.

  Implementations:

    * `Ecrits.Doc.Rhwp` — HWP/HWPX, backed by the headless `ehwp` server NIF.
    * `Ecrits.Doc.Office` — docx/pptx/xlsx via LibreOffice (LOK NIF). **Deferred.**

  ## Refs are opaque

  A `ref` is an opaque term issued by `outline/3`, `find/3` (or `hit_test`).
  The agent receives a ref and hands it back; only the issuing backend decodes
  it. For HWP a ref encodes `(sec, para, off)` / cell paths; for Office it is a
  UNO path. Callers MUST NOT construct refs by hand.

  ## Revisions & conflicts

  Every mutating callback (`set/4`, `edit/3`, `apply_style/3`) takes a
  `base_revision` so the owning `Ecrits.Doc.Editor` can detect interleaved
  writers and rebase. The authoritative revision counter lives in the Editor,
  not the engine. Mutating callbacks return `{:ok, applied}` where `applied`
  carries the *engine-level* effect; the Editor stamps the final revision.
  """

  @typedoc "Opaque element reference issued by a backend."
  @type ref :: term()

  @typedoc "An opened engine document handle (engine-specific)."
  @type handle :: term()

  @typedoc "Document kind."
  @type kind :: :hwp | :hwpx | :office

  @typedoc """
  Engine-level result of a mutation.

  `revision` is advisory (the Editor owns the authoritative counter);
  `invalidated` is the list of pages a renderer must redraw.
  """
  @type applied :: %{
          optional(:revision) => integer(),
          optional(:invalidated) => [integer()],
          optional(:rebased) => boolean(),
          optional(atom()) => term()
        }

  @doc "The document kind this backend serves."
  @callback kind() :: kind()

  @doc "Open a document from a path (or engine-specific opts), returning a handle."
  @callback open(path :: String.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc "Close/release a handle."
  @callback close(handle()) :: :ok

  @doc """
  Structural tree. `ref` is the subtree root (nil = whole document).
  Each node is a map with at least `:ref` and `:type`.
  """
  @callback outline(handle(), ref() | nil, opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Read a text chunk (windowed via opts: `:ref`, `:at`, `:size`)."
  @callback read(handle(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Literal search. Returns `[%{ref: ref, text: ...}]`-shaped matches."
  @callback find(handle(), pattern :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Read native properties of `ref` (nil props = all)."
  @callback get(handle(), ref(), props :: [String.t()] | nil) ::
              {:ok, map()} | {:error, term()}

  @doc "Universal property edit. Routes native setters per element kind."
  @callback set(handle(), ref(), props :: map(), base_revision :: integer() | nil) ::
              {:ok, applied()} | {:error, term()}

  @doc "Structural verb (see `Ecrits.Doc.Op`)."
  @callback edit(handle(), op :: map(), base_revision :: integer() | nil) ::
              {:ok, applied()} | {:error, term()}

  @doc "Apply a named style to `ref`."
  @callback apply_style(handle(), ref(), style :: String.t() | map()) ::
              {:ok, applied()} | {:error, term()}

  @doc "Persist to disk (or export bytes). May be unsupported on some engines."
  @callback save(handle(), opts :: keyword()) :: :ok | {:error, term()}

  @optional_callbacks save: 2

  @doc "Backends registered for each document kind."
  @spec backend_for(kind()) :: module() | nil
  def backend_for(:hwp), do: Ecrits.Doc.Rhwp
  def backend_for(:hwpx), do: Ecrits.Doc.Rhwp
  def backend_for(:office), do: nil
  def backend_for(_other), do: nil
end
