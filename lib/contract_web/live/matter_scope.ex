defmodule ContractWeb.MatterScope do
  @moduledoc """
  LiveView `on_mount` hook that:

    1. Reads `:matter_id` from the route params and stuffs the resolved
       matter into `socket.assigns.current_scope.matter`.
    2. Seeds `current_scope.perms` from the session (the persona sign-in
       flow in `ContractWeb.TestAuthController` writes `:user_perms` into
       the session, and we thread that here so components can gate on
       perms like `:write` / `:agent_run` / `:type_change`).

  The resolved matter is a real `Contract.Matters.Matter{}` row when the
  scope can see it, falling back to a stub `%{id: matter_id, name:
  "Matter " <> short}` for routes that pre-date the Matters context
  (e.g. tests that don't insert a row first). The `Contract.Context`
  struct accepts an opaque `:matter` field so callers handle both
  shapes.

  Perms seeding is unconditional: if the session has `:user_perms`, the
  scope gets them; if not, `current_scope.perms` stays at whatever
  upstream (`Contract.Context.for_user/1`) set it to (currently `nil`).
  Components that gate on perms must defensively treat `nil` as "no
  perms" (e.g. `Canvas.Empty`'s `can_write?(_), do: false`).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Contract.Context

  @doc """
  on_mount callback: seeds perms from the session and attaches matter
  (if matter_id present) onto `current_scope`.

  Document-pivot (SPEC.md §4): routes are now document-first. When
  `:document_id` is present in params, this hook resolves it through
  `Contract.Documents.get/2`, derives the matter from
  `document.matter_id`, and threads both `current_scope.matter` and
  `assigns.current_document_id` so downstream components have a single
  source of truth. The `:matter_id` branch is retained for the
  `/workspaces/:matter_id` (and legacy `/matters/...`) routes.
  """
  def on_mount(:assign_scope, params, session, socket) do
    document_id =
      case params do
        %{"document_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    matter_id =
      case params do
        %{"matter_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    socket =
      socket
      |> assign_perms(session)
      |> assign_current_document(document_id)
      |> assign_matter_from_document(document_id, matter_id)

    {:cont, socket}
  end

  defp assign_perms(%{assigns: %{current_scope: %Context{} = scope}} = socket, session) do
    case session_perms(session) do
      nil -> socket
      perms -> assign(socket, :current_scope, %Context{scope | perms: perms})
    end
  end

  defp assign_perms(socket, _session), do: socket

  defp session_perms(session) when is_map(session) do
    case Map.get(session, "user_perms") || Map.get(session, :user_perms) do
      perms when is_list(perms) -> perms
      _ -> nil
    end
  end

  defp session_perms(_), do: nil

  # Stash the document_id on the LV's assigns so downstream components
  # (canvas, chat-rail, breadcrumbs) read a single key rather than
  # cracking the path. Stays nil for /studio and /workspaces/:matter_id.
  defp assign_current_document(socket, nil),
    do: assign(socket, :current_document_id, nil)

  defp assign_current_document(socket, document_id) when is_binary(document_id),
    do: assign(socket, :current_document_id, document_id)

  # When a document_id was supplied, resolve it through Documents.get/2
  # and use its matter_id. Fall back to the explicit matter_id branch
  # (or nil) if the document can't be loaded — that keeps the LV alive
  # on tests / unseeded environments and lets Studio.load surface the
  # real error.
  defp assign_matter_from_document(socket, nil, matter_id),
    do: assign_matter(socket, matter_id)

  defp assign_matter_from_document(
         %{assigns: %{current_scope: %Context{} = scope}} = socket,
         document_id,
         fallback_matter_id
       )
       when is_binary(document_id) do
    case load_document(scope, document_id) do
      {:ok, %{matter_id: matter_id}} when is_binary(matter_id) ->
        assign_matter(socket, matter_id)

      _ ->
        assign_matter(socket, fallback_matter_id)
    end
  end

  defp assign_matter_from_document(socket, _document_id, matter_id),
    do: assign_matter(socket, matter_id)

  defp load_document(scope, document_id) do
    Contract.Documents.get(scope, document_id)
  rescue
    # Documents table not migrated yet — degrade gracefully.
    Postgrex.Error -> {:error, :unavailable}
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp assign_matter(socket, nil), do: socket

  defp assign_matter(%{assigns: %{current_scope: %Context{} = scope}} = socket, matter_id) do
    matter = load_matter(scope, matter_id)
    assign(socket, :current_scope, %Context{scope | matter: matter})
  end

  defp assign_matter(socket, _matter_id), do: socket

  # Tries the real Contract.Matters.get/2 first; falls back to the legacy
  # stub for tests + routes that haven't seeded a real row yet. The
  # fallback keeps StudioLive et al. unblocked while the matters table
  # is empty in CI.
  defp load_matter(scope, matter_id) when is_binary(matter_id) do
    case Contract.Matters.get(scope, matter_id) do
      {:ok, matter} -> matter
      {:error, _} -> stub_matter(matter_id)
    end
  rescue
    # Tolerates the matters table not existing yet — degrade gracefully
    # to the stub so the test suite keeps working pre-migrate.
    Postgrex.Error -> stub_matter(matter_id)
    DBConnection.ConnectionError -> stub_matter(matter_id)
  end

  defp stub_matter(matter_id) when is_binary(matter_id) do
    %{id: matter_id, name: "Matter " <> String.slice(matter_id, 0, 8)}
  end
end
