defmodule Ecrits.Doc do
  @moduledoc """
  Engine-adapter behaviour for editable documents (the MCP document abstraction).

  This is the `Ecrits.Doc` behaviour from the document-editing MCP design
  (`docs/plans/2026-06-04-doc-editing-mcp-design.md`, §4.2). It mirrors each
  engine's own object/property model so that a *small* set of reflective MCP
  tools (`read`/`find`/`get` (type+values+settable+children)/`set` (universal,
  incl. char formatting)/`edit`/`save`) can drive any backend without one tool
  per editing operation.

  Implementations:

    * `Ecrits.Doc.Rhwp` — HWP/HWPX, backed by the headless `ehwp` server NIF.
    * `Ecrits.Doc.Office` — docx/pptx via LibreOffice (the pure-UNO `libreofficex`
      NIF). The server arm for Office docs, mirroring `Rhwp`.

  ## Refs are opaque

  A `ref` is an opaque term issued by `outline/3`, `find/3` (or `hit_test`).
  The agent receives a ref and hands it back; only the issuing backend decodes
  it. For HWP a ref encodes `(sec, para, off)` / cell paths; for Office it is a
  UNO path. Callers MUST NOT construct refs by hand.

  Mutating callbacks return `{:ok, applied}` where `applied` carries only the
  engine-level effect. Ordering is owned by `Ecrits.Doc.Editor`'s mailbox, not by
  a document ordering token.
  """

  @typedoc "Opaque element reference issued by a backend."
  @type ref :: term()

  @typedoc "An opened engine document handle (engine-specific)."
  @type handle :: term()

  @typedoc "Document kind."
  @type kind :: :hwp | :hwpx | :office | :docx | :pptx | :xlsx

  @typedoc """
  Engine-level result of a mutation.

  `invalidated` is the list of pages a renderer must redraw.
  """
  @type applied :: %{
          optional(:invalidated) => [integer()],
          optional(atom()) => term()
        }

  @doc "The document kind this backend serves."
  @callback kind() :: kind()

  @doc "Open a document from a path (or engine-specific opts), returning a handle."
  @callback open(path :: String.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc "Create a NEW empty document (engine blank template), returning a handle."
  @callback new(opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Reload an OPEN handle from freshly-persisted `bytes`, returning a new handle
  (the Editor closes the old one). Bytes-native backends (rhwp) can skip this —
  the Editor falls back to `open(bytes, [])`. Path-native backends (office/UNO,
  whose `open/2` opens a FILE, never a byte buffer) implement it to reopen from
  disk; the canonical file already holds `bytes` by the time this is called (the
  save/checkpoint twin-sync writes the file first). Optional.
  """
  @callback reopen(handle(), bytes :: binary()) :: {:ok, handle()} | {:error, term()}

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

  @doc """
  Reflective discovery for `ref` (design §4.1, §4.4 `inspect`).

  Mirrors the engine's own self-description so the agent never hard-codes a
  property name: for Office this is `XServiceInfo` + `XPropertySetInfo` +
  children; for rhwp it is the element's type plus the *native* property names
  (`Bold`/`Italic`/`Width`/…) that `get/3`/`set/3` understand for that element
  kind, plus its child refs. The returned map carries at least `:ref`,
  `:type`, and `:properties` (a list of native property names).
  """
  @callback inspect(handle(), ref() | nil) :: {:ok, map()} | {:error, term()}

  @doc "Read native properties of `ref` (nil props = all)."
  @callback get(handle(), ref(), props :: [String.t()] | nil) ::
              {:ok, map()} | {:error, term()}

  @doc "Universal property edit. Routes native setters per element kind."
  @callback set(handle(), ref(), props :: map()) :: {:ok, applied()} | {:error, term()}

  @doc "Structural verb (see `Ecrits.Doc.Op`)."
  @callback edit(handle(), op :: map()) :: {:ok, applied()} | {:error, term()}

  @doc "Persist to disk (or export bytes). May be unsupported on some engines."
  @callback save(handle(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Full-IR element enumeration (design's `doc.find {type:…}`/`doc.read` over the
  whole taxonomy).

  Returns `{:ok, [node]}` where each node is a map with at least `:ref`,
  `:type`, and `:text` (plus `:row`/`:col` for table cells and a `:context`
  breadcrumb for in-table elements). Backends whose engine cannot enumerate the
  full IR return `{:error, {:not_supported, _}}` so callers fall back to
  `find/3`/`read/2`. Optional.
  """
  @callback elements(handle(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks save: 2, new: 1, elements: 2, reopen: 2

  @doc "Backends registered for each document kind."
  @spec backend_for(kind()) :: module() | nil
  def backend_for(:hwp), do: Ecrits.Doc.Rhwp
  def backend_for(:hwpx), do: Ecrits.Doc.Rhwp
  def backend_for(:docx), do: Ecrits.Doc.Office
  def backend_for(:pptx), do: Ecrits.Doc.Office
  def backend_for(:xlsx), do: Ecrits.Doc.Office
  def backend_for(:office), do: Ecrits.Doc.Office
  def backend_for(_other), do: nil
end
