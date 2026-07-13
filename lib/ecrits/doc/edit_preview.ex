defmodule Ecrits.Doc.EditPreview do
  @moduledoc """
  Server-side partial edit previews for persisted chat-rail descriptors.

  HWP/HWPX refs are decoded into the positional target accepted by
  `Ehwp.render_preview/3`. Office refs stay engine-native and are rendered by
  `Libreofficex.Preview` through the single serialized UNO governor.
  """

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Office.Instance
  alias Ecrits.Doc.Rhwp.Ref
  alias Ecrits.Document

  @preview_width 720

  @spec render(String.t(), String.t(), String.t() | map() | nil) ::
          {:ok, binary(), map()} | {:error, term()}
  def render(path, format, ref) when is_binary(path) and is_binary(format) do
    cond do
      Document.ehwp_format?(format) -> render_hwp(path, ref)
      Document.libreoffice_format?(format) -> render_office(path, ref)
      true -> {:error, :unsupported_format}
    end
  end

  defp render_hwp(path, ref) do
    with {:ok, handle, _metadata} <- Ehwp.open(path) do
      try do
        with {:ok, target} <- hwp_target(ref),
             {:ok, png, metadata} <- Ehwp.render_preview(handle, target, width: @preview_width) do
          {:ok, png, metadata}
        end
      after
        Ehwp.close(handle)
      end
    end
  end

  defp render_office(path, ref) do
    with {:ok, handle} <- Office.open(path) do
      try do
        case Instance.run(handle, fn session ->
               Libreofficex.Preview.render(session, office_ref(ref), scale: 0.75)
             end) do
          {:ok, %{image: image} = metadata} -> {:ok, image, Map.delete(metadata, :image)}
          {:error, _reason} = error -> error
          other -> {:error, {:preview_failed, other}}
        end
      after
        Office.close(handle)
      end
    end
  end

  defp hwp_target(nil), do: {:ok, %{section: 0, paragraph: 0, offset: 0}}
  defp hwp_target(%{} = ref), do: hwp_target(Jason.encode!(ref))

  defp hwp_target(ref) when is_binary(ref) do
    decoded_ref = decode_ref_map(ref)

    case Ref.decode(ref) do
      {:ok, %{kind: :char, sec: section, para: paragraph, off: offset}} ->
        {:ok,
         %{section: section, paragraph: paragraph, offset: offset}
         |> maybe_put_highlight_length(decoded_ref)}

      {:ok, %{kind: :paragraph, sec: section, para: paragraph}} ->
        {:ok,
         %{section: section, paragraph: paragraph, offset: ref_offset(decoded_ref)}
         |> maybe_put_highlight_length(decoded_ref)}

      {:ok,
       %{
         kind: :cell_char,
         sec: section,
         para: paragraph,
         control: control,
         cell: cell,
         cell_para: cell_paragraph,
         off: offset
       }} ->
        {:ok,
         %{
           section: section,
           paragraph: paragraph,
           control: control,
           cell: cell,
           cell_para: cell_paragraph,
           offset: offset
         }
         |> maybe_put_highlight_length(decoded_ref)}

      {:ok, %{kind: :control, sec: section, para: paragraph}} ->
        {:ok, %{section: section, paragraph: paragraph, offset: 0}}

      {:ok, %{kind: :section, sec: section}} ->
        {:ok, %{section: section, paragraph: 0, offset: 0}}

      {:ok, %{kind: :document}} ->
        {:ok, %{section: 0, paragraph: 0, offset: 0}}

      {:error, _reason} = error ->
        error
    end
  end

  defp hwp_target(_ref), do: {:error, :invalid_ref}

  defp decode_ref_map(ref) do
    case Jason.decode(ref) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp ref_offset(ref) do
    case ref["offset"] || ref[:offset] do
      offset when is_integer(offset) and offset >= 0 -> offset
      _ -> 0
    end
  end

  defp maybe_put_highlight_length(target, ref) do
    case ref["highlightLength"] || ref["highlight_length"] || ref[:highlight_length] do
      length when is_integer(length) and length > 0 ->
        Map.put(target, :highlight_length, length)

      _ ->
        target
    end
  end

  defp office_ref(nil), do: ""
  defp office_ref(ref) when is_binary(ref), do: ref
  defp office_ref(%{} = ref), do: Jason.encode!(ref)
  defp office_ref(ref), do: to_string(ref)
end
