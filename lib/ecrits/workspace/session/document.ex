defmodule Ecrits.Workspace.Session.Document do
  @moduledoc """
  Session-owned document UI state.

  This is distinct from `Ecrits.Local.Document.t/0`, which describes the opened
  file/runtime document. This module describes what the durable workspace
  session needs to restore: path, handles, and scroll position.
  """

  @type path :: String.t()
  @type id :: String.t()
  @type pool_document_id :: String.t()
  @type scroll_coordinate :: non_neg_integer()

  @type t :: %__MODULE__{
          path: path(),
          id: id() | nil,
          pool_document_id: pool_document_id() | nil,
          scroll_top: scroll_coordinate(),
          scroll_left: scroll_coordinate()
        }

  defstruct path: nil,
            id: nil,
            pool_document_id: nil,
            scroll_top: 0,
            scroll_left: 0
end
