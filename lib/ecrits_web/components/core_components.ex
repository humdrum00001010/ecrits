defmodule EcritsWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: EcritsWeb.Gettext

  alias Ecrits.WorkspaceMount
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a v33 ecrits product button.

  Use this for product surfaces that should share the app chrome button
  treatment without relying on global `.button--*` CSS.
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary)
  slot :inner_block, required: true

  def cs_button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => [
        "border-transparent bg-[var(--cs-green)] text-[var(--cs-bg)]",
        "hover:bg-[color-mix(in_oklab,var(--cs-green)_86%,white)]"
      ],
      "secondary" => [
        "border-[color-mix(in_oklab,var(--cs-ink)_16%,transparent)] bg-transparent text-[var(--cs-ink)]",
        "hover:bg-[color-mix(in_oklab,var(--cs-ink)_6%,transparent)]"
      ]
    }

    assigns =
      assign(assigns, :button_class, [
        "inline-flex h-9 items-center justify-center gap-2 rounded-md border px-3 text-sm font-semibold",
        "transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)]",
        "disabled:cursor-not-allowed disabled:opacity-50",
        Map.fetch!(variants, assigns.variant),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@button_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@button_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Wraps sanitized Markdown/Observex HTML with the shared prose treatment.

  The descendants are raw renderer output, so their styling is expressed as
  Tailwind arbitrary variants on the wrapper instead of global CSS selectors.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def markdown_prose(assigns) do
    assigns = assign(assigns, :prose_class, markdown_prose_class(assigns.class))

    ~H"""
    <div class={@prose_class} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  def markdown_prose_class(extra \\ nil) do
    [
      "min-w-0 max-w-full text-left break-words hyphens-auto",
      "[&>*:first-child]:mt-0 [&>*:last-child]:mb-0",
      "[&_p]:my-[0.4em] [&_ul]:my-[0.4em] [&_ol]:my-[0.4em]",
      "[&_pre]:my-[0.4em] [&_table]:my-[0.4em] [&_blockquote]:my-[0.4em]",
      "[&_p]:break-words [&_li]:break-words [&_blockquote]:break-words",
      "[&_h1]:mt-[0.8em] [&_h1]:mb-[0.35em] [&_h1]:text-[1.25em]",
      "[&_h2]:mt-[0.8em] [&_h2]:mb-[0.35em] [&_h2]:text-[1.15em]",
      "[&_h3]:mt-[0.8em] [&_h3]:mb-[0.35em] [&_h3]:text-[1.05em]",
      "[&_h4]:mt-[0.8em] [&_h4]:mb-[0.35em] [&_h4]:text-[1em]",
      "[&_h5]:mt-[0.8em] [&_h5]:mb-[0.35em] [&_h5]:text-[1em]",
      "[&_h6]:mt-[0.8em] [&_h6]:mb-[0.35em] [&_h6]:text-[1em]",
      "[&_h1]:font-semibold [&_h2]:font-semibold [&_h3]:font-semibold",
      "[&_h4]:font-semibold [&_h5]:font-semibold [&_h6]:font-semibold",
      "[&_h1]:leading-[1.3] [&_h2]:leading-[1.3] [&_h3]:leading-[1.3]",
      "[&_h4]:leading-[1.3] [&_h5]:leading-[1.3] [&_h6]:leading-[1.3]",
      "[&_h1]:text-base-content [&_h2]:text-base-content [&_h3]:text-base-content",
      "[&_h4]:text-base-content [&_h5]:text-base-content [&_h6]:text-base-content",
      "[&_strong]:font-semibold [&_strong]:text-base-content [&_em]:italic",
      "[&_del]:line-through [&_del]:opacity-75",
      "[&_ul]:list-disc [&_ul]:pl-[1.35em] [&_ol]:list-decimal [&_ol]:pl-[1.35em]",
      "[&_li]:my-[0.15em] [&_li>ul]:my-[0.15em] [&_li>ol]:my-[0.15em]",
      "[&_input]:mr-[0.4em] [&_input]:align-middle",
      "[&_a]:text-primary [&_a]:underline [&_a]:underline-offset-2",
      "[&_a]:decoration-current/45 [&_a:hover]:decoration-current",
      "[&_:not(pre)>code]:break-words [&_:not(pre)>code]:whitespace-break-spaces",
      "[&_:not(pre)>code]:rounded [&_:not(pre)>code]:bg-base-content/[0.09]",
      "[&_:not(pre)>code]:px-[0.3em] [&_:not(pre)>code]:py-[0.1em]",
      "[&_:not(pre)>code]:font-mono [&_:not(pre)>code]:text-[0.85em]",
      "[&_pre]:max-w-full [&_pre]:overflow-x-auto [&_pre]:break-normal [&_pre]:rounded-md",
      "[&_pre]:border [&_pre]:border-base-content/10 [&_pre]:px-[0.7em] [&_pre]:py-[0.6em]",
      "[&_pre]:text-[0.8em] [&_pre]:leading-[1.45]",
      "[&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_pre_code]:font-mono [&_pre_code]:whitespace-pre",
      "[&_blockquote]:border-l-[3px] [&_blockquote]:border-base-content/25",
      "[&_blockquote]:pl-[0.75em] [&_blockquote]:text-base-content/75",
      "[&_blockquote>*:first-child]:mt-0 [&_blockquote>*:last-child]:mb-0",
      "[&_table]:block [&_table]:w-max [&_table]:max-w-full [&_table]:overflow-x-auto",
      "[&_table]:border-collapse [&_table]:text-[0.85em]",
      "[&_th]:border [&_th]:border-base-content/15 [&_td]:border [&_td]:border-base-content/15",
      "[&_th]:px-[0.5em] [&_th]:py-[0.25em] [&_td]:px-[0.5em] [&_td]:py-[0.25em]",
      "[&_th]:text-left [&_td]:text-left [&_th]:align-top [&_td]:align-top",
      "[&_thead_th]:bg-base-content/[0.06] [&_thead_th]:font-semibold",
      "[&_hr]:my-[0.8em] [&_hr]:border-0 [&_hr]:border-t [&_hr]:border-base-content/15",
      "[&_img]:h-auto [&_img]:max-w-full",
      extra
    ]
  end

  @doc """
  Renders the compact v33 document status dot.
  """
  attr :status, :any, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def status_dot(assigns) do
    assigns =
      assign(assigns, :dot_class, [
        "inline-block w-2 h-2 flex-none rounded-full align-middle",
        status_dot_bg(assigns.status),
        # Keep the data attribute so legacy CSS-grep tests and external
        # selectors can still target the status by name.
        assigns.class
      ])

    ~H"""
    <span
      class={@dot_class}
      data-status={status_dot_modifier(@status)}
      aria-hidden="true"
      {@rest}
    >
    </span>
    """
  end

  defp status_dot_modifier(nil), do: nil

  defp status_dot_modifier(status) do
    "status-dot--#{status |> to_string() |> String.replace("_", "-")}"
  end

  # Background-color utility per logical status. Maps each known status
  # to a daisyUI semantic color so the chrome stays palette-driven.
  defp status_dot_bg(nil), do: "bg-base-content/45"
  defp status_dot_bg(:draft), do: "bg-base-content/45"
  defp status_dot_bg("draft"), do: "bg-base-content/45"
  defp status_dot_bg(:importing), do: "bg-info"
  defp status_dot_bg("importing"), do: "bg-info"
  defp status_dot_bg(:in_progress), do: "bg-info"
  defp status_dot_bg("in-progress"), do: "bg-info"
  defp status_dot_bg("in_progress"), do: "bg-info"
  defp status_dot_bg(:editing), do: "bg-success"
  defp status_dot_bg("editing"), do: "bg-success"
  defp status_dot_bg(:ready), do: "bg-success"
  defp status_dot_bg("ready"), do: "bg-success"
  defp status_dot_bg(:export_ready), do: "bg-success"
  defp status_dot_bg("export-ready"), do: "bg-success"
  defp status_dot_bg("export_ready"), do: "bg-success"
  defp status_dot_bg(:review), do: "bg-warning"
  defp status_dot_bg("review"), do: "bg-warning"
  defp status_dot_bg(:reviewing), do: "bg-warning"
  defp status_dot_bg("reviewing"), do: "bg-warning"
  defp status_dot_bg(:error), do: "bg-error"
  defp status_dot_bg("error"), do: "bg-error"
  defp status_dot_bg(_), do: "bg-base-content/45"

  @doc """
  Renders the local workspace mount panel.

  The screen is page-specific, but the chrome, button, input row, and error
  treatment are component-owned so the global stylesheet can stay focused on
  fonts, theme tokens, and semantic rendered content.
  """
  attr :workspace_mount, :any, required: true

  def workspace_mount_panel(%{workspace_mount: %WorkspaceMount{}} = assigns) do
    assigns =
      assign(
        assigns,
        :workspace_mount_form,
        to_form(%{"path" => assigns.workspace_mount.path}, as: :local_path)
      )

    ~H"""
    <div
      id="local-mount-root"
      class="flex min-h-[calc(100vh-60px)] items-center justify-center px-5 py-8"
    >
      <section
        id="local-native-directory-picker"
        data-role="native-directory-picker"
        class={workspace_mount_panel_class()}
        aria-label="Open workspace folder"
      >
        <div class="flex h-[2.1rem] items-center gap-2.5 border-b border-base-content/10 bg-base-300/35 px-3.5">
          <span class="inline-flex gap-1.5" aria-hidden="true">
            <span class="size-2 rounded-full bg-base-content/20"></span>
            <span class="size-2 rounded-full bg-base-content/20"></span>
            <span class="size-2 rounded-full bg-base-content/20"></span>
          </span>
          <span class="inline-flex min-w-0 items-center gap-1.5 font-mono text-[0.72rem] text-base-content/70">
            <.icon name="hero-folder-micro" class="size-3.5 shrink-0" />
            <span class="truncate">no folder open</span>
          </span>
        </div>

        <div
          id="local-mount-picker-surface"
          data-role="mount-picker-surface"
          class="grid gap-[1.35rem] p-6 pb-5"
        >
          <header>
            <h1
              id="local-native-directory-status"
              class="m-0 text-[1.06rem] font-semibold leading-snug text-base-content"
            >
              Open a workspace folder
            </h1>
            <p class="m-0 mt-1.5 text-[0.84rem] leading-6 text-base-content/70">
              Point Ecrits at a folder on this machine to start editing. Everything
              stays on disk.
            </p>
          </header>

          <div
            id="local-mount-control-row"
            data-role="mount-control-row"
            class="m-0 flex flex-col gap-4"
          >
            <button
              id="local-mount-choose"
              type="button"
              phx-click="workspace.directory_picker.open"
              phx-disable-with="Opening picker..."
              disabled={@workspace_mount.picker_busy?}
              aria-busy={to_string(@workspace_mount.picker_busy?)}
              data-busy={to_string(@workspace_mount.picker_busy?)}
              class={workspace_mount_open_class()}
            >
              <%= if @workspace_mount.picker_busy? do %>
                <.icon name="hero-arrow-path-micro" class="size-4 shrink-0 animate-spin" />
                <span>Opening picker...</span>
              <% else %>
                <.icon name="hero-folder-open-micro" class="size-4 shrink-0" />
                <span>Open folder...</span>
              <% end %>
            </button>

            <.form
              for={@workspace_mount_form}
              id="local-path-form"
              phx-submit="workspace.path.open"
              class="m-0"
            >
              <label
                for="local-path-input"
                class="mb-1.5 block text-[0.72rem] font-medium text-base-content/70"
              >
                or enter a path
              </label>
              <div class={workspace_mount_path_field_class()}>
                <span
                  class="inline-flex select-none items-center justify-center font-mono text-base leading-none text-base-content/40"
                  aria-hidden="true"
                >
                  &rsaquo;
                </span>
                <.input
                  field={@workspace_mount_form[:path]}
                  id="local-path-input"
                  type="text"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder="/Users/name/workspace"
                  wrapper_class="m-0 min-w-0 self-stretch p-0"
                  label_class="block h-full"
                  class="h-full w-full border-0 bg-transparent px-2.5 font-mono text-[0.82rem] text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0"
                />
                <button
                  id="local-path-submit"
                  type="submit"
                  aria-label="Open path"
                  title="Open this path"
                  class={workspace_mount_path_submit_class()}
                >
                  <.icon name="hero-arrow-turn-down-left-micro" class="size-3.5" />
                  <span class="leading-none">Open</span>
                </button>
              </div>
            </.form>
          </div>

          <p
            :if={@workspace_mount.error}
            id="local-mount-error"
            role="alert"
            class="m-0 mt-1 flex items-start gap-2 rounded-md border border-error/30 bg-error/10 px-3 py-2 text-[0.82rem] leading-[1.45] text-error"
          >
            <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
            <span>{@workspace_mount.error}</span>
          </p>
        </div>
      </section>
    </div>
    """
  end

  defp workspace_mount_panel_class do
    [
      "w-full max-w-[30rem] overflow-hidden rounded-lg",
      "border border-base-content/10 bg-base-200 shadow-[0_8px_28px_rgba(0,0,0,0.45)]"
    ]
  end

  defp workspace_mount_open_class do
    [
      "inline-flex h-10 w-full items-center justify-center gap-2 rounded-md border border-transparent px-4 text-sm font-semibold text-white",
      "bg-[oklch(44%_0.13_162)] transition-colors duration-150 hover:bg-[oklch(40%_0.13_162)] active:bg-[oklch(36%_0.13_162)]",
      "focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-[oklch(44%_0.13_162/0.38)]",
      "disabled:cursor-progress disabled:opacity-65"
    ]
  end

  defp workspace_mount_path_field_class do
    [
      "grid min-h-11 grid-cols-[auto_minmax(0,1fr)_auto] items-center rounded-md border border-base-content/15",
      "bg-base-content/[0.02] py-1 pl-3 pr-1 transition-[border-color,box-shadow,background-color] duration-150",
      "focus-within:border-primary focus-within:bg-base-200 focus-within:ring-[3px] focus-within:ring-primary/15"
    ]
  end

  defp workspace_mount_path_submit_class do
    [
      "m-0 inline-flex min-h-[2.15rem] shrink-0 items-center justify-center gap-1 rounded px-3.5",
      "bg-base-content/10 text-[0.78rem] font-semibold text-base-content/75 transition-colors duration-150",
      "hover:bg-primary hover:text-primary-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/35"
    ]
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :wrapper_class, :any, default: nil, doc: "the wrapper class to use over defaults"
  attr :label_class, :any, default: nil, doc: "the label wrapper class to use"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={@wrapper_class || "fieldset mb-2"}>
      <label for={@id} class={@label_class}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={@wrapper_class || "fieldset mb-2"}>
      <label for={@id} class={@label_class}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={@wrapper_class || "fieldset mb-2"}>
      <label for={@id} class={@label_class}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class={@wrapper_class || "fieldset mb-2"}>
      <label for={@id} class={@label_class}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="transition-colors hover:bg-base-200/60 [&:has(td[data-table-action]:hover)]:!bg-transparent"
        >
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold" data-table-action>
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/css/plugins/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-out duration-150",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(EcritsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EcritsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
