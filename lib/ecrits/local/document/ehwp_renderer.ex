defmodule Ecrits.Local.Document.EhwpRenderer do
  @moduledoc """
  Server-side SVG renderer for local HWP/HWPX documents.
  """

  alias Ecrits.Local.Document

  @spec render_pages(Document.t()) :: {:ok, map()} | {:error, term()}
  def render_pages(%Document{} = document) do
    case Ehwp.open(document.path, ehwp_opts()) do
      {:ok, handle, metadata} ->
        try do
          with {:ok, page_count} <- page_count(handle, metadata),
               {:ok, pages} <- render_pages(handle, page_count) do
            {:ok, %{page_count: page_count, pages: pages}}
          end
        after
          Ehwp.close(handle)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_count(handle, metadata) do
    case metadata_page_count(metadata) || Ehwp.page_count(handle) do
      page_count when is_integer(page_count) and page_count >= 0 -> {:ok, page_count}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_page_count, other}}
    end
  end

  defp metadata_page_count(%{page_count: page_count}) when is_integer(page_count), do: page_count

  defp metadata_page_count(%{"page_count" => page_count}) when is_integer(page_count),
    do: page_count

  defp metadata_page_count(_metadata), do: nil

  defp render_pages(handle, page_count) do
    0..max(page_count - 1, -1)
    |> Enum.reduce_while({:ok, []}, fn page_index, {:ok, pages} ->
      case Ehwp.render_page_svg(handle, page_index) do
        {:ok, svg, _metadata} when is_binary(svg) ->
          page = %{index: page_index, number: page_index + 1, svg: svg}
          {:cont, {:ok, [page | pages]}}

        {:ok, svg} when is_binary(svg) ->
          page = %{index: page_index, number: page_index + 1, svg: svg}
          {:cont, {:ok, [page | pages]}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:invalid_svg_page, page_index, other}}}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ehwp_opts do
    Application.get_env(:ecrits, :local_ehwp_opts, [])
  end
end
