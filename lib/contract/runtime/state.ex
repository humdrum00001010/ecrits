defmodule Contract.Runtime.State do
  @moduledoc """
  The in-memory projection of a document that `Contract.Session.Reducer`
  compiles against and the Session hydrates from `Contract.Store`.

  ## Projection shape

  The `:projection` map is the pure data the Engine mutates. Its shape:

      %{
        title:      String.t() | nil,
        type_key:   Contract.Types.contract_type_key() | nil,
        metadata:   map(),
        nodes:      %{node_id => node_t()},
        node_order: [node_id],         # top-level order; tree is per-node parent_id
        fields:     %{field_id => field_t()},
        marks:      %{mark_id  => mark_t()},
        refs:       %{ref_id   => ref_target_t()}
      }

  ## Node kinds

  Per SPEC.md §15 invariant 15 ("soft meaning belongs in Marks, not in a giant
  hard legal ontology"), the Engine intentionally does **not** enumerate a
  fixed legal ontology of node kinds. The recommended baseline kinds are:

      :paragraph, :heading, :list, :list_item, :table, :cell, :section, :field_ref

  Authors and agents are free to use additional kinds as soft labels; the
  Engine treats node kinds as opaque atoms. Any "is this a clause?" semantics
  belong in marks, not in node kinds.

  ## Table + cell IR-richness attrs (task #37)

  To preserve HWPX-grade fidelity through ingest → projection → export, the
  `:table` and `:cell` node kinds carry the following optional `attrs` keys.
  All are additive — readers that don't know about them ignore them; writers
  that don't set them fall back to defaults.

  ### `:table` attrs

    * `:column_widths` — `[pos_integer]`, HWP units (1/100 mm) per column.
    * `:border_fill_id` — `String.t() | nil`, default borderFillID for cells.
    * `:header_row_count` — `non_neg_integer`, default `0`.
    * `:footer_row_count` — `non_neg_integer`, default `0`.
    * `:rows`, `:cols` — existing dimension hints (unchanged).

  ### `:cell` attrs

    * `:row_span` — `pos_integer`, default `1`.
    * `:col_span` — `pos_integer`, default `1`.
    * `:border_fill_id` — `String.t() | nil`, per-cell override of the
      table-level borderFillID.
    * `:vertical_alignment` — `:top | :center | :bottom`, default `:top`.
    * `:padding_top`, `:padding_right`, `:padding_bottom`, `:padding_left` —
      `non_neg_integer`, HWP units (1/100 mm), default `0`.
  """

  alias Contract.Types, as: T

  @type node_id :: T.id()
  @type field_id :: T.field_id()
  @type mark_id :: T.mark_id()
  @type ref_id :: T.id()

  @type node_t :: %{
          required(:id) => node_id(),
          required(:kind) => atom(),
          optional(:parent_id) => node_id() | nil,
          optional(:content) => String.t(),
          optional(:children) => [node_id()],
          optional(:attrs) => map()
        }

  @type field_t :: %{
          required(:id) => field_id(),
          optional(:key) => atom() | String.t(),
          optional(:value) => term(),
          optional(:attrs) => map()
        }

  @type mark_t :: %{
          required(:id) => mark_id(),
          required(:intent) => atom(),
          required(:source) => atom(),
          optional(:text) => String.t(),
          optional(:target_type) => atom(),
          optional(:target_id) => T.id() | nil,
          optional(:confidence) => atom(),
          optional(:data) => map()
        }

  @type ref_target_t :: %{
          required(:id) => ref_id(),
          required(:source_node_id) => node_id(),
          required(:target_id) => T.id(),
          optional(:type) => atom()
        }

  @type projection_t :: %{
          title: String.t() | nil,
          type_key: T.contract_type_key() | nil,
          metadata: map(),
          nodes: %{optional(node_id()) => node_t()},
          node_order: [node_id()],
          fields: %{optional(field_id()) => field_t()},
          marks: %{optional(mark_id()) => mark_t()},
          refs: %{optional(ref_id()) => ref_target_t()}
        }

  @type t :: %__MODULE__{
          document_id: T.document_id() | nil,
          revision: T.revision(),
          projection: projection_t()
        }

  @empty_projection %{
    title: nil,
    type_key: nil,
    metadata: %{},
    nodes: %{},
    node_order: [],
    fields: %{},
    marks: %{},
    refs: %{}
  }

  defstruct document_id: nil,
            revision: 0,
            projection: @empty_projection

  @doc """
  Returns an empty projection map. Useful for tests and Store hydration.
  """
  @spec empty_projection() :: projection_t()
  def empty_projection, do: @empty_projection

  # ----------------------------------------------------------------------------
  # IR-richness helpers (task #37): allowed attr keys per node kind.
  # ----------------------------------------------------------------------------

  @table_attr_keys [
    :column_widths,
    :border_fill_id,
    :header_row_count,
    :footer_row_count,
    :rows,
    :cols
  ]

  @cell_attr_keys [
    :row_span,
    :col_span,
    :border_fill_id,
    :vertical_alignment,
    :padding_top,
    :padding_right,
    :padding_bottom,
    :padding_left
  ]

  @doc """
  Allowed attr keys for `:table` nodes (HWPX-grade metadata). Used by
  `Contract.Engine` `:set_attr` validation. Additive — extra keys are not
  rejected, but these are the canonical names.
  """
  @spec table_attr_keys() :: [atom()]
  def table_attr_keys, do: @table_attr_keys

  @doc """
  Allowed attr keys for `:cell` nodes (HWPX-grade metadata).
  """
  @spec cell_attr_keys() :: [atom()]
  def cell_attr_keys, do: @cell_attr_keys
end
