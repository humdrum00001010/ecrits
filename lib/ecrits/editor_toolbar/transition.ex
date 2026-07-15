defmodule Ecrits.EditorToolbar.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.EditorToolbar

  @commands ~w(bold italic underline strikethrough bullets numbering align-left align-center align-right align-justify)

  def reset(%EditorToolbar{}), do: EditorToolbar.new()

  def put_engine_state(%EditorToolbar{} = toolbar, attrs, active_document_id)
      when is_map(attrs) and is_binary(active_document_id) do
    state = EditorToolbar.changeset(toolbar, attrs)

    if state.valid? and get_field(state, :document_id) == active_document_id,
      do: apply_changes(state),
      else: toolbar
  end

  def put_engine_state(%EditorToolbar{} = toolbar, _attrs, _active_document_id), do: toolbar

  def command(%EditorToolbar{} = toolbar, command, attrs, document)
      when is_map(attrs) and is_map(document) do
    command_changeset = EditorToolbar.command_changeset(command)

    with true <- command_changeset.valid?,
         command <- get_change(command_changeset, :command),
         {:ok, extra} <- command_payload(command, attrs) do
      base_command(toolbar, document, command, extra)
    else
      _ -> :error
    end
  end

  def command(%EditorToolbar{}, _command, _attrs, _document), do: :error

  def shortcut_command(attrs) when is_map(attrs) do
    shortcut = EditorToolbar.shortcut_changeset(attrs)
    primary? = get_field(shortcut, :meta_key, false) != get_field(shortcut, :ctrl_key, false)
    shift? = get_field(shortcut, :shift_key, false)
    alt? = get_field(shortcut, :alt_key, false)
    key = shortcut |> get_field(:key, "") |> String.downcase()

    case {primary?, shift?, alt?, key} do
      {true, false, false, "b"} -> "bold"
      {true, false, false, "i"} -> "italic"
      {true, false, false, "u"} -> "underline"
      {true, true, false, "x"} -> "strikethrough"
      {true, true, false, "l"} -> "align-left"
      {true, true, false, "e"} -> "align-center"
      {true, true, false, "r"} -> "align-right"
      {true, true, false, "j"} -> "align-justify"
      _ -> nil
    end
  end

  def shortcut_command(_attrs), do: nil

  defp command_payload(command, _attrs) when command in @commands, do: {:ok, %{}}

  defp command_payload("font-size-set", attrs) do
    changeset = EditorToolbar.font_size_changeset(attrs)
    if changeset.valid?, do: {:ok, %{size: get_change(changeset, :size)}}, else: :error
  end

  defp command_payload(command, attrs) when command in ["text-color", "highlight"] do
    changeset = EditorToolbar.color_changeset(attrs)
    if changeset.valid?, do: {:ok, %{color: get_change(changeset, :color)}}, else: :error
  end

  defp command_payload("image", attrs) do
    changeset = EditorToolbar.image_changeset(attrs)

    if changeset.valid? do
      mime_type = get_change(changeset, :mime_type)

      {:ok,
       %{
         image_base64: get_change(changeset, :image_base64),
         mime_type: mime_type,
         file_name: get_change(changeset, :file_name, "image"),
         extension: get_change(changeset, :extension) || extension_from_mime(mime_type),
         natural_width_px: get_change(changeset, :natural_width_px),
         natural_height_px: get_change(changeset, :natural_height_px)
       }}
    else
      :error
    end
  end

  defp base_command(toolbar, document, command, extra) do
    document_id = document[:id] || document["id"] || toolbar.document_id
    format = document[:format] || document["format"] || ""
    identity = EditorToolbar.identity_changeset(document_id, format)

    if identity.valid? do
      {:ok,
       Map.merge(
         %{
           command: command,
           source: "liveview-editor-toolbar",
           document_id: get_change(identity, :document_id),
           format: get_change(identity, :format, "")
         },
         extra
       )}
    else
      :error
    end
  end

  defp extension_from_mime(mime_type) do
    extension = mime_type |> String.split("/", parts: 2) |> List.last()

    if Regex.match?(~r/\A[a-zA-Z0-9]+\z/, extension),
      do: String.downcase(extension),
      else: "png"
  end
end
