defmodule Ecrits.Doc.Office.Native do
  @moduledoc """
  Raw UNO-session lifecycle helpers for `Ecrits.Doc.Office.Instance`.

  This module isolates the *resource* side of the office NIF — booting/opening a
  UNO session, reopening one from disk after an LRU eviction, saving, and
  closing — from the *op* side (`Ecrits.Doc.Office`, which classifies refs and
  shapes the `doc.*` results). The Instance owns these sessions; the backend
  issues per-op closures against a live session the Instance hands it.

  Keeping the install-dir / profile / absolute-path resolution here (rather than
  importing it from `Ecrits.Doc.Office`) avoids an `Office <-> Instance` cyclic
  dependency: `Office.Instance` depends only on this leaf module + the NIF.
  """

  alias Libreofficex.LokBackend.Native

  @docx_filter "MS Word 2007 XML"
  @pptx_filter "Impress MS PowerPoint 2007 XML"

  @typedoc "An opened UNO session plus the args needed to reopen it after eviction."
  @type opened :: %{
          session: term(),
          kind: :docx | :pptx,
          path: String.t(),
          install_dir: String.t(),
          profile: String.t()
        }

  @doc """
  Boot the office (once, process-wide) and open `path` as a UNO session. Returns
  `{:ok, opened}` carrying the live session AND the resolved install_dir/profile
  so the Instance can reopen the doc later without re-resolving. `kind` is
  `opts[:kind]` (docx/pptx) or inferred from the extension.
  """
  @spec open_session(String.t(), keyword()) :: {:ok, opened()} | {:error, term()}
  def open_session(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, install_dir} <- install_dir(),
         {:ok, abs} <- absolute_path(path) do
      profile = profile_url(abs)

      case Native.uno_open(install_dir, abs, profile) do
        {:ok, session} ->
          {:ok,
           %{
             session: session,
             kind: doc_kind(opts, path),
             path: abs,
             install_dir: install_dir,
             profile: profile
           }}

        {:error, :uno_unavailable} ->
          {:error,
           {:office_unavailable, "libreofficex UNO arm not built (no LO SDK at build time)"}}

        {:error, {:open_failed, msg}} ->
          {:error, {:open_failed, to_string(msg)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, {:office_unavailable, inspect(e.original)}}
  end

  @doc """
  Reopen a previously-evicted doc from disk (its saved bytes). Reuses the entry's
  install_dir/profile/path so the rematerialised session is byte-identical to the
  one that was saved-then-closed. Returns `{:ok, session}`.
  """
  @spec reopen_session(map()) :: {:ok, term()} | {:error, term()}
  def reopen_session(%{install_dir: install_dir, path: path, profile: profile}) do
    case Native.uno_open(install_dir, path, profile) do
      {:ok, session} -> {:ok, session}
      {:error, :uno_unavailable} -> {:error, {:office_unavailable, "uno arm not built"}}
      {:error, {:open_failed, msg}} -> {:error, {:open_failed, to_string(msg)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, {:office_unavailable, inspect(e.original)}}
  end

  @doc "Persist a live session to `path` using the kind's export filter (eviction save)."
  @spec save_session(term(), String.t(), :docx | :pptx) :: :ok | {:error, term()}
  def save_session(session, path, kind) do
    case Native.uno_save(session, path, filter_for(kind)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :save_failed}
  end

  @doc "Dispose a live UNO session (release the NIF resource)."
  @spec close_session(term()) :: :ok
  def close_session(session) do
    _ = Native.uno_close(session)
    :ok
  rescue
    _ -> :ok
  end

  # ── resolution helpers (mirrors Ecrits.Doc.Office) ─────────────────

  @doc "Resolve the LOK install dir (app config -> LOK_INSTALL_DIR -> ~/Desktop/core)."
  @spec install_dir() :: {:ok, String.t()} | {:error, :no_install_dir}
  def install_dir do
    candidates =
      [
        Application.get_env(:ecrits, Ecrits.Doc.Office, [])[:install_dir],
        System.get_env("LOK_INSTALL_DIR"),
        default_install_dir()
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case Enum.find(candidates, &lok_present?/1) do
      nil -> {:error, :no_install_dir}
      dir -> {:ok, dir}
    end
  end

  defp default_install_dir do
    case System.user_home() do
      home when is_binary(home) ->
        Path.join([
          home,
          "Desktop",
          "core",
          "instdir",
          "LibreOffice.app",
          "Contents",
          "Frameworks"
        ])

      _ ->
        nil
    end
  end

  defp lok_present?(dir) when is_binary(dir),
    do: File.exists?(Path.join(dir, "libsofficeapp.dylib")) or File.dir?(dir)

  defp lok_present?(_dir), do: false

  defp profile_url(abs_path) do
    hash =
      :crypto.hash(:sha256, abs_path) |> Base.url_encode64(padding: false) |> String.slice(0, 16)

    dir = Path.join([System.tmp_dir!(), "ecrits_office_profile", hash])
    File.mkdir_p(dir)
    "file://" <> dir
  end

  # `open_session/2` already guards `is_binary(path)`, so this only ever receives
  # a binary; expanding it to an absolute path can't fail here.
  defp absolute_path(path) when is_binary(path), do: {:ok, Path.expand(path)}

  defp doc_kind(opts, path) do
    case Keyword.get(opts, :kind) do
      :pptx -> :pptx
      :docx -> :docx
      _ -> from_extension(path)
    end
  end

  defp from_extension(path) do
    case path |> Path.extname() |> String.downcase() do
      ".pptx" -> :pptx
      ".ppt" -> :pptx
      _ -> :docx
    end
  end

  defp filter_for(:pptx), do: @pptx_filter
  defp filter_for(:docx), do: @docx_filter
  defp filter_for(_other), do: @docx_filter
end
