defmodule EcritsWeb.Components.LocalFileTree do
  @moduledoc """
  File tree component for local workspace UI.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :nodes, :list, required: true
  attr :expanded_paths, :any, required: true
  attr :selected_path, :string, default: nil
  attr :open_paths, :map, default: %{}

  @open_extensions ~w(hwp hwpx doc docx docm dot dotx dotm xls xlsx xlsm xlt xltx xltm ppt pptx pptm pps ppsx ppsm pot potx potm rtf)

  def tree(assigns) do
    ~H"""
    <nav id={@id} aria-label="Workspace files" class="text-sm">
      <ul role="tree" class="py-1">
        <.tree_node
          :for={node <- visible_nodes(@nodes)}
          node={node}
          expanded_paths={@expanded_paths}
          selected_path={@selected_path}
          open_paths={@open_paths}
          depth={0}
        />
      </ul>
    </nav>
    """
  end

  attr :node, :map, required: true
  attr :expanded_paths, :any, required: true
  attr :selected_path, :string, default: nil
  attr :open_paths, :map, default: %{}
  attr :depth, :integer, required: true

  def tree_node(assigns) do
    assigns =
      assigns
      |> assign(:node_path, node_path(assigns.node))
      |> assign(:node_name, node_name(assigns.node))
      |> assign(:node_dom_id, node_dom_id(assigns.node))
      |> assign(:directory?, directory?(assigns.node))
      |> assign(:expanded?, expanded?(assigns.node, assigns.expanded_paths))
      |> assign(:selected?, selected?(assigns.node, assigns.selected_path))
      |> assign(:metadata?, metadata?(assigns.node))
      |> assign(:capability, capability(assigns.node))
      |> assign(:extension, extension(assigns.node))
      |> assign(
        :open_path,
        open_path(assigns.open_paths, node_path(assigns.node), capability(assigns.node))
      )
      |> assign(:visible_children, visible_nodes(node_children(assigns.node)))
      |> assign(:padding_style, "padding-left: #{8 + assigns.depth * 16}px")

    ~H"""
    <li role="none">
      <a
        :if={!@directory? && @open_path}
        id={@node_dom_id}
        href={@open_path}
        role="treeitem"
        aria-label={@node_name}
        data-role="repo-browser-row"
        data-node-path={@node_path}
        data-node-kind="file"
        data-tree-depth={@depth}
        data-selected={to_string(@selected?)}
        data-metadata={to_string(@metadata?)}
        data-file-extension={@extension}
        data-openable="true"
        class={[
          "flex h-8 min-w-0 cursor-pointer items-center gap-1 pr-2 text-base-content no-underline transition-colors",
          @selected? && "bg-base-300/70",
          @metadata? && "opacity-45",
          !@selected? && "hover:bg-base-200"
        ]}
        style={@padding_style}
      >
        <span class="size-5 shrink-0" aria-hidden="true"></span>

        <span class={[
          "flex min-w-0 flex-1 items-center gap-2 px-1 py-1 text-[13px]",
          @selected? && "font-medium text-base-content",
          !@selected? && "text-base-content/85"
        ]}>
          <span
            id={"#{@node_dom_id}-icon"}
            phx-update="ignore"
            class="inline-flex size-4 shrink-0 items-center justify-center text-base-content/50"
            aria-hidden="true"
          >
            <.icon name={file_icon(@extension)} class="size-4 shrink-0" />
          </span>
          <span class="truncate">{@node_name}</span>
        </span>
      </a>

      <div
        :if={@directory? || is_nil(@open_path)}
        id={@node_dom_id}
        role="treeitem"
        aria-label={@node_name}
        aria-expanded={if @directory?, do: to_string(@expanded?), else: nil}
        data-role="repo-browser-row"
        data-node-path={@node_path}
        data-node-kind={if @directory?, do: "directory", else: "file"}
        data-tree-depth={@depth}
        data-expanded={if @directory?, do: to_string(@expanded?), else: nil}
        data-selected={to_string(@selected?)}
        data-metadata={to_string(@metadata?)}
        data-file-extension={@extension}
        data-openable={to_string(@capability == :open)}
        phx-click={row_click(@directory?, @capability)}
        phx-value-path={row_click_path(@directory?, @capability, @node_path)}
        class={[
          "flex h-8 min-w-0 items-center gap-1 pr-2 transition-colors",
          @capability in [:open, :select] && "cursor-pointer",
          @selected? && "bg-base-300/70",
          @metadata? && "opacity-45",
          !@selected? && "hover:bg-base-200"
        ]}
        style={@padding_style}
      >
        <button
          :if={@directory?}
          id={"toggle-dir-#{dom_token(@node_path)}"}
          type="button"
          phx-click="toggle_dir"
          phx-value-path={@node_path}
          class="inline-flex size-5 shrink-0 items-center justify-center rounded text-base-content/55 hover:bg-base-300 hover:text-base-content"
          aria-label={if @expanded?, do: "Collapse #{@node_name}", else: "Expand #{@node_name}"}
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-3.5"
          />
        </button>

        <span :if={!@directory?} class="size-5 shrink-0" aria-hidden="true"></span>

        <button
          :if={@directory?}
          type="button"
          phx-click="toggle_dir"
          phx-value-path={@node_path}
          class={[
            "flex min-w-0 flex-1 items-center gap-2 px-1 py-1 text-left text-[13px] hover:text-base-content",
            @selected? && "font-medium text-base-content",
            !@selected? && "text-base-content/85"
          ]}
        >
          <.icon
            name={if @expanded?, do: "hero-folder-open", else: "hero-folder"}
            class="size-4 shrink-0 text-base-content/60"
          />
          <span class="truncate">{@node_name}</span>
          <span :if={@metadata?} class="shrink-0 text-xs text-base-content/45">metadata</span>
        </button>

        <span
          :if={!@directory?}
          class={[
            "flex min-w-0 flex-1 items-center gap-2 px-1 py-1 text-[13px]",
            @selected? && "font-medium text-base-content",
            !@selected? && "text-base-content/85"
          ]}
        >
          <span
            id={"#{@node_dom_id}-icon"}
            phx-update="ignore"
            class="inline-flex size-4 shrink-0 items-center justify-center text-base-content/50"
            aria-hidden="true"
          >
            <.icon name={file_icon(@extension)} class="size-4 shrink-0" />
          </span>
          <span class="truncate">{@node_name}</span>
        </span>
      </div>

      <ul :if={@directory? && @expanded? && @visible_children != []} role="group" class="py-0.5">
        <.tree_node
          :for={child <- @visible_children}
          node={child}
          expanded_paths={@expanded_paths}
          selected_path={@selected_path}
          open_paths={@open_paths}
          depth={@depth + 1}
        />
      </ul>
    </li>
    """
  end

  defp directory?(node), do: Map.get(node, :type) == :directory
  defp node_children(node), do: Map.get(node, :children, [])
  defp node_name(node), do: Map.fetch!(node, :name)
  defp node_path(node), do: Map.fetch!(node, :path)
  defp metadata?(node), do: Map.get(node, :metadata?, node_name(node) == ".ecrits")

  defp visible_nodes(nodes) do
    nodes
    |> Enum.filter(&visible_node?/1)
    |> Enum.uniq_by(&node_path/1)
  end

  defp visible_node?(node),
    do:
      not metadata?(node) and
        (directory?(node) or extension(node) in (@open_extensions ++ ["md"]))

  defp selected?(node, selected_path),
    do: not directory?(node) and node_path(node) == selected_path

  defp row_click(true, _capability), do: nil
  defp row_click(false, :open), do: "open_file"
  defp row_click(false, :select), do: "select_file"
  defp row_click(false, _capability), do: nil

  defp row_click_path(false, capability, path) when capability in [:open, :select], do: path
  defp row_click_path(_directory?, _capability, _path), do: nil

  defp open_path(open_paths, path, :open) when is_map(open_paths), do: Map.get(open_paths, path)
  defp open_path(_open_paths, _path, _capability), do: nil

  defp expanded?(node, expanded_paths) do
    directory?(node) and MapSet.member?(expanded_paths, node_path(node))
  end

  defp extension(node) do
    if directory?(node) do
      nil
    else
      node
      |> node_name()
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()
      |> case do
        "" -> nil
        ext -> ext
      end
    end
  end

  defp capability(node) do
    cond do
      directory?(node) -> :none
      extension(node) in @open_extensions -> :open
      extension(node) == "md" -> :open
      true -> :none
    end
  end

  defp file_icon("hwp"), do: "hero-document-check"
  defp file_icon("hwpx"), do: "hero-document-check"
  defp file_icon("md"), do: "hero-document-text"
  defp file_icon(_extension), do: "hero-document"

  defp node_dom_id(node), do: "local-file-node-#{dom_token(node_path(node))}"

  defp dom_token(path) do
    path = path |> to_string() |> String.normalize(:nfc)
    token = path |> ascii_dom_token() |> maybe_hash_token(path)

    if token == "", do: "root", else: token
  end

  defp ascii_dom_token(path) do
    path
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
  end

  defp maybe_hash_token(token, path) do
    if String.match?(path, ~r/^[\x00-\x7F]*$/) do
      token
    else
      base = if token == "", do: "node", else: token
      "#{base}-#{short_hash(path)}"
    end
  end

  defp short_hash(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
  end
end
