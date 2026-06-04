defmodule Ecrits.Local.OfficeEditSession do
  @moduledoc """
  A supervised, LiveView-owned LibreOfficeKit (LOK) editing session for one open
  office document (docx/pptx/xlsx).

  This is the editor counterpart to the read-only PDF-tile path. It holds the
  live `Libreofficex.Edit` session (the document in LOK memory) and serializes
  every NIF call onto THIS process so a blocking paint/edit never stalls the
  owning LiveView's mailbox. The LiveView drives it with casts carrying its own
  pid; results stream back as messages the LiveView forwards to the
  `OfficeEditor` JS hook via `push_event`:

    * `{:office_edit, {:caret, %{page, x, y, height}}}` — caret moved (px,
      page-local, 1-based page).
    * `{:office_edit, {:tile, %{part, x, y, width, height, png_base64}}}` — a
      painted tile (PNG data URI source). `x/y` are the tile's TWIP origin;
      `width/height` are the canvas pixel size.
    * `{:office_edit, {:error, reason}}` — a guarded failure (never crashes the
      LiveView).

  The session monitors its owner and closes (frees the LOK document) when the
  owner dies, so a navigated-away LiveView leaks nothing. Every public op is
  guarded: a degraded/absent NIF returns `{:error, ...}` rather than crashing.

  Coordinate model (mirrors `Libreofficex.Edit`): LOK is TWIPS internally;
  `hit_test`/caret are page-local PIXELS @96dpi; `paint_tile` takes a canvas
  pixel size + a document TWIP rect.
  """

  use GenServer

  alias Libreofficex.Edit

  require Logger

  @type t :: pid()

  # 1 px @96dpi = 15 twip.
  @twips_per_px 15

  # Live-typing repaint tuning (issue 3):
  #   * coalesce a burst of keystrokes into ONE paint after this quiet gap, so a
  #     fast typist paints once per ~50ms instead of once per key.
  @repaint_debounce_ms 45
  #   * paint at scale 1 while actively typing (half the pixels of devicePixelRatio
  #     2), then re-paint crisp at scale 2 once typing has been idle this long.
  @crisp_idle_ms 350
  @typing_scale 1.0
  @crisp_scale 2.0
  #   * twip margin above the caret line we still repaint (a descender / the line
  #     box just above), so the clip never visibly chops the current line.
  @caret_clip_margin_twip 240
  #   * while actively typing, paint only a BAND of this height around the caret
  #     line (~5 lines) instead of caret-to-bottom: a ~12KB PNG vs ~75KB, so each
  #     keystroke transfers/decodes far faster. The idle crisp repaint covers the
  #     full caret-to-bottom region, fixing any reflow below the band.
  @live_band_twip 1400

  defstruct [
    :edit,
    :owner,
    :owner_ref,
    # Open is async (handle_continue): the path/opts are stored so the heavy
    # LOK documentLoad happens OFF the LiveView's path.
    :path,
    :edit_opts,
    :doc_type,
    :part_count,
    :repaint_timer,
    :crisp_timer,
    # Pending coalesced repaint for the active part: a BAND around the caret
    # line, painted at the cheap typing scale when the debounce fires.
    :pending_repaint,
    # The full caret-to-bottom region for the one-shot crisp repaint after typing
    # goes idle (covers reflow below the live band).
    :full_repaint,
    # Last known caret (twips doc-space) so the clip can start at the caret line.
    :last_caret_twip_y,
    # Monotonic ms of the last live paint, for leading-edge debounce.
    :last_paint_ms,
    part: 0
  ]

  # --- Public API -------------------------------------------------------------

  @doc """
  Starts an edit session for `path`, owned by `owner` (default: the caller).

  Returns `{:ok, pid}` or `{:error, reason}`. On a machine without a built LOK
  runtime this returns `{:error, :backend_missing}` (never crashes the caller).
  """
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(path, opts \\ []) when is_binary(path) do
    owner = Keyword.get(opts, :owner, self())

    spec = {__MODULE__, Keyword.merge(opts, path: path, owner: owner)}

    # Returns as soon as the process starts; the heavy LOK documentLoad runs
    # async in handle_continue and the owner is notified with
    # `{:office_edit, {:opened, info}}` or `{:office_edit, {:open_error, reason}}`
    # — so a ~0.5s open never blocks the LiveView mailbox.
    case DynamicSupervisor.start_child(Ecrits.Local.OfficeEditSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Document metadata: `{:ok, %{doc_type, part_count, page_count}}`."
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  def info(pid), do: safe_call(pid, :info)

  @doc "Posts a click at page-local px on a 1-based page; sends back a `:caret`."
  @spec hit_test(pid(), pos_integer(), number(), number()) :: :ok
  def hit_test(pid, page, x, y), do: GenServer.cast(pid, {:hit_test, page, x, y})

  @doc "Posts a keyboard event (`%{text:}` or `%{key:}`); paints the dirty tiles."
  @spec keyboard(pid(), map()) :: :ok
  def keyboard(pid, event), do: GenServer.cast(pid, {:keyboard, event})

  @doc "Posts IME input (`%{preedit:}`/`%{commit:}`/`%{end: true}`); paints dirty."
  @spec ime(pid(), map()) :: :ok
  def ime(pid, event), do: GenServer.cast(pid, {:ime, event})

  @doc """
  Requests a paint of `part` covering the page-local px viewport rect
  `%{page, x, y, width, height}` (the host's visible window); sends back `:tile`.
  """
  @spec request_tile(pid(), map()) :: :ok
  def request_tile(pid, viewport), do: GenServer.cast(pid, {:request_tile, viewport})

  @doc "Sets the active part (0-based) and repaints; sends back the part dims."
  @spec set_part(pid(), non_neg_integer()) :: :ok
  def set_part(pid, part), do: GenServer.cast(pid, {:set_part, part})

  @doc "Saves the document in place. Returns `:ok` or `{:error, reason}`."
  @spec save(pid()) :: :ok | {:error, term()}
  def save(pid), do: safe_call(pid, :save)

  @doc "Closes the session (frees the LOK document)."
  @spec close(pid()) :: :ok
  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # --- GenServer --------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    owner = Keyword.fetch!(opts, :owner)
    edit_opts = Keyword.take(opts, [:install_dir, :user_profile_url])
    ref = Process.monitor(owner)

    state = %__MODULE__{owner: owner, owner_ref: ref, path: path, edit_opts: edit_opts}

    # Return immediately; open the document in handle_continue so the ~0.5s LOK
    # documentLoad runs off the LiveView's synchronous path.
    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    try do
      case Edit.open(state.path, state.edit_opts) do
        {:ok, %Edit{} = edit} ->
          part_count =
            case Edit.get_parts(edit) do
              n when is_integer(n) and n > 0 -> n
              _ -> 1
            end

          state = %{state | edit: edit, doc_type: edit.doc_type, part_count: part_count}
          notify(state, {:opened, build_info(state)})
          {:noreply, state}

        {:error, reason} ->
          notify(state, {:open_error, reason})
          {:stop, :normal, state}
      end
    rescue
      e ->
        Logger.warning("[office_edit] open crashed: #{Exception.message(e)}")
        notify(state, {:open_error, :open_crashed})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, build_info(state)}, state}
  end

  def handle_call(:save, _from, state) do
    {:reply, guarded(fn -> Edit.save(state.edit) end, {:error, :backend_missing}), state}
  end

  @impl true
  def handle_cast({:hit_test, page, x, y}, state) do
    case guarded(fn -> Edit.hit_test(state.edit, page, x, y) end, {:error, :no_cursor}) do
      {:ok, caret} -> notify(state, {:caret, normalize_caret(caret)})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:keyboard, event}, state) do
    {:noreply, apply_edit(state, fn -> Edit.keyboard(state.edit, event) end)}
  end

  def handle_cast({:ime, event}, state) do
    {:noreply, apply_edit(state, fn -> Edit.ext_text_input(state.edit, event) end)}
  end

  def handle_cast({:request_tile, viewport}, state) do
    state =
      if presentation?(state) do
        # Lazy slide paint (issue 1): the host asks for slide `page` (1-based)
        # when it scrolls into view. Each slide is a distinct LOK part, so switch
        # to it then paint the WHOLE slide at its real (landscape) extent. Track
        # the now-active part so a subsequent edit targets the visible slide.
        page = vp(viewport, :page, 1)
        paint_slide(state, page)
        %{state | part: page - 1}
      else
        paint_viewport(state, viewport)
        state
      end

    {:noreply, state}
  end

  def handle_cast({:set_part, part}, state) do
    guarded(fn -> Edit.set_part(state.edit, part) end, :ok)
    state = %{state | part: part}
    # Repaint the whole (now active) part at a default canvas.
    paint_full_part(state, part)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  # The coalesced live-typing repaint fired: paint the pending region ONCE (at
  # the cheap typing scale), then arm a one-shot crisp repaint for when typing
  # goes idle (issue 3a/3b/3c).
  def handle_info(:flush_repaint, state) do
    state =
      case state.pending_repaint do
        %{} = region ->
          paint_region(state, region, @typing_scale)
          crisp = state.full_repaint || region

          %{
            state
            | repaint_timer: nil,
              pending_repaint: nil,
              full_repaint: nil,
              last_paint_ms: System.monotonic_time(:millisecond)
          }
          |> arm_crisp_repaint(crisp)

        _ ->
          %{state | repaint_timer: nil}
      end

    {:noreply, state}
  end

  # Typing has been idle: re-paint the last region crisply (scale 2) so the
  # settled text is sharp. Cheap because it only happens once after a burst.
  def handle_info({:crisp_repaint, region}, state) do
    paint_region(state, region, @crisp_scale)
    {:noreply, %{state | crisp_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    guarded(fn -> Edit.close(state.edit) end, :ok)
    :ok
  end

  # --- internals --------------------------------------------------------------

  # Run an edit op (keyboard/ime), then push the new caret IMMEDIATELY (so the
  # blinking caret tracks the keystroke with no paint latency) and SCHEDULE a
  # coalesced repaint of the LOK-invalidated region. Returns the new state
  # (carrying the debounce timer + pending region).
  defp apply_edit(state, fun) do
    case guarded(fun, {:error, :backend_missing}) do
      {:ok, reply} ->
        caret = Map.get(reply, :cursor)

        state =
          case caret do
            %{} = c ->
              notify(state, {:caret, normalize_caret(c)})
              %{state | last_caret_twip_y: caret_twip_y(state, c)}

            _ ->
              state
          end

        schedule_repaint(state, Map.get(reply, :invalidated, []))

      _ ->
        state
    end
  end

  # Coalesce the LOK dirty rects into ONE pending region and arm a short debounce
  # (issue 3a). A typing burst keeps resetting the timer, so we paint once per
  # quiet gap instead of once per keystroke. The region is clipped to
  # caret-line-downward (issue 3c): text above the caret is unchanged, so we
  # never re-encode the top of a tall page.
  defp schedule_repaint(state, rects) when is_list(rects) and rects != [] do
    part = active_part(state)
    full = doc_extent_twips(state)

    # Union the dirty rects' vertical span; a whole-doc invalidation ({_,_,-1,-1})
    # spans the full part.
    {min_y, max_y} =
      Enum.reduce(rects, {nil, nil}, fn
        {_x, _y, w, h}, {lo, hi} when w <= 0 or h <= 0 ->
          {merge_min(lo, full.y), merge_max(hi, full.y + full.h)}

        {_x, y, _w, h}, {lo, hi} ->
          {merge_min(lo, y), merge_max(hi, y + max(h, 0))}

        _, acc ->
          acc
      end)

    if is_nil(min_y) do
      state
    else
      # Clip the TOP of the region to the caret line (minus a small margin) so we
      # never repaint text above the caret, which never changes while typing.
      clip_top =
        case state.last_caret_twip_y do
          y when is_integer(y) -> max(min_y, y - @caret_clip_margin_twip)
          _ -> min_y
        end

      crisp_region = %{
        part: part,
        x: full.x,
        y: clip_top,
        w: full.w,
        h: max(max_y - clip_top, 1)
      }

      # Live typing paints only a band around the caret line (small PNG, fast
      # transfer); the idle crisp repaint covers the whole caret-to-bottom span.
      live_region = %{crisp_region | h: min(crisp_region.h, @live_band_twip)}

      arm_repaint(%{
        state
        | pending_repaint: union_region(state.pending_repaint, live_region),
          full_repaint: union_region(state.full_repaint, crisp_region)
      })
    end
  end

  defp schedule_repaint(state, _), do: state

  # Paint the host's visible viewport (page-local px rect on a 1-based page)
  # converted to document twips for the active part.
  defp paint_viewport(state, viewport) when is_map(viewport) do
    part = active_part(state)
    page = vp(viewport, :page, 1)

    page_origin = page_origin_twips(state, page)
    x_px = vp(viewport, :x, 0)
    y_px = vp(viewport, :y, 0)
    w_px = vp(viewport, :width, 0)
    h_px = vp(viewport, :height, 0)

    tile_x = page_origin.x + px_to_twip(x_px)
    tile_y = page_origin.y + px_to_twip(y_px)
    tile_w = px_to_twip(max(w_px, 1))
    tile_h = px_to_twip(max(h_px, 1))

    paint_rect(state, part, tile_x, tile_y, tile_w, tile_h, @crisp_scale)
  end

  defp paint_viewport(_state, _), do: :ok

  # Paint the entire active part into a single canvas sized to the part's twip
  # extent (capped so we never allocate a huge buffer). Used for the initial
  # render and whole-doc invalidations.
  defp paint_full_part(state, part) do
    case guarded(fn -> Edit.doc_size(state.edit) end, {:error, :backend_missing}) do
      {:ok, %{width: tw, height: th}} when is_integer(tw) and is_integer(th) and tw > 0 and th > 0 ->
        paint_rect(state, part, 0, 0, tw, th, @crisp_scale)

      _ ->
        :ok
    end
  end

  # Lazily paint slide `page` (1-based) of a presentation (issue 1): each slide
  # is a distinct LOK part, so switch the active part to it FIRST, then paint the
  # whole slide at its real (landscape) extent. The part stays selected; we track
  # it so subsequent edits target the right slide.
  defp paint_slide(state, page) when is_integer(page) and page >= 1 do
    part = page - 1
    guarded(fn -> Edit.set_part(state.edit, part) end, :ok)

    case guarded(fn -> Edit.doc_size(state.edit) end, {:error, :backend_missing}) do
      {:ok, %{width: tw, height: th}}
      when is_integer(tw) and is_integer(th) and tw > 0 and th > 0 ->
        paint_rect(state, part, 0, 0, tw, th, @crisp_scale, page)

      _ ->
        :ok
    end
  end

  defp paint_slide(_state, _), do: :ok

  # Paint a coalesced live-typing region (issue 3) at the given scale.
  defp paint_region(state, %{part: part, x: x, y: y, w: w, h: h}, scale) do
    paint_rect(state, part, x, y, max(w, 1), max(h, 1), scale)
  end

  # Paint a document twip rect of `part` and push the resulting PNG tile. The
  # canvas pixel size is the rect's twip size at 96dpi times `scale`, capped.
  # `scale` is 2 for crisp (open / idle) paints and 1 for the cheaper live-typing
  # paint (issue 3b: half the pixels while a burst is in flight).
  defp paint_rect(state, part, tile_x, tile_y, tile_w, tile_h, scale, page \\ nil) do
    canvas_w = twip_to_px(tile_w) |> mul_round(scale) |> clamp(1, 4000)
    canvas_h = twip_to_px(tile_h) |> mul_round(scale) |> clamp(1, 4000)

    geo = %{
      canvas_w: canvas_w,
      canvas_h: canvas_h,
      tile_x: tile_x,
      tile_y: tile_y,
      tile_w: tile_w,
      tile_h: tile_h
    }

    case guarded(fn -> Edit.paint_tile(state.edit, part, geo) end, {:error, :backend_missing}) do
      {:ok, %{png: png} = tile} when is_binary(png) and byte_size(png) > 0 ->
        # For a presentation the host page == the slide (caller passes `page`);
        # the slide's own origin is its part's page rect. For a text doc the
        # page is whichever page box the twip-y falls in.
        page_origin =
          case page do
            p when is_integer(p) -> %{page: p, x: tile_x, y: tile_y}
            _ -> nearest_page_for_twip_y(state, tile_y)
          end

        notify(state, {
          :tile,
          %{
            part: part,
            page: page_origin.page,
            # px position WITHIN the page box (for the host to place the tile).
            x: twip_to_px(tile_x - page_origin.x),
            y: twip_to_px(tile_y - page_origin.y),
            tile_w: twip_to_px(tile_w),
            tile_h: twip_to_px(tile_h),
            width: Map.get(tile, :width, canvas_w),
            height: Map.get(tile, :height, canvas_h),
            png_base64: Base.encode64(png)
          }
        })

      _ ->
        :ok
    end
  end

  defp active_part(state), do: state.part

  defp presentation?(%{doc_type: :presentation}), do: true
  defp presentation?(_), do: false

  # Document metadata pushed to the hook on open.
  defp build_info(state) do
    %{
      doc_type: state.doc_type,
      part_count: state.part_count,
      page_count: guarded(fn -> Edit.page_count(state.edit) end, 0),
      # Per-part geometry (px @96dpi). For a presentation this sizes each slide
      # box to its REAL (landscape) dims BEFORE painting; empty for text docs.
      parts_geometry: parts_geometry(state)
    }
  end

  # Per-part geometry for the host (only meaningful for multi-part docs like
  # presentations). Returns [] for single-part text docs.
  #
  # Every slide in a deck shares ONE page size, so we measure the active part
  # once (doc_size, ~0ms) and replicate it for all parts — instead of walking
  # every part (each set_part forces a full slide relayout: ~2ms × N, which
  # blocked the open by ~160ms for an 84-slide deck). Same shape the hook reads.
  defp parts_geometry(state) do
    if presentation?(state) and state.part_count > 1 do
      case guarded(fn -> Edit.doc_size(state.edit) end, {:error, :backend_missing}) do
        {:ok, %{width: tw, height: th}}
        when is_integer(tw) and is_integer(th) and tw > 0 and th > 0 ->
          w = twip_to_px(tw)
          h = twip_to_px(th)

          for part <- 0..(state.part_count - 1) do
            %{part: part, width_twip: tw, height_twip: th, width_px: w, height_px: h}
          end

        _ ->
          []
      end
    else
      []
    end
  end

  # The active part's full twip extent (x/y origin + w/h). For a text doc the
  # origin is the first page box's; for a slide it's the part's doc size.
  defp doc_extent_twips(state) do
    {x0, y0} =
      case guarded_page_rects(state) do
        [%{x: x, y: y} | _] -> {x, y}
        _ -> {0, 0}
      end

    case guarded(fn -> Edit.doc_size(state.edit) end, {:error, :backend_missing}) do
      {:ok, %{width: tw, height: th}} when is_integer(tw) and is_integer(th) and tw > 0 ->
        %{x: x0, y: y0, w: tw, h: th}

      _ ->
        %{x: x0, y: y0, w: 11_906, h: 16_838}
    end
  end

  # Reconstruct the caret's absolute document-twip Y from the page-local px caret
  # (`y` is page-local px; add the page box's twip origin).
  defp caret_twip_y(state, %{page: page, y: y}) when is_number(y) do
    origin = page_origin_twips(state, page)
    origin.y + px_to_twip(y)
  end

  defp caret_twip_y(_state, _), do: nil

  # Union two pending repaint regions (same part assumed for a typing burst);
  # take the outer vertical span so one paint covers everything dirtied so far.
  defp union_region(nil, region), do: region

  defp union_region(%{part: p1} = a, %{part: p2} = b) when p1 == p2 do
    top = min(a.y, b.y)
    bot = max(a.y + a.h, b.y + b.h)
    %{part: p1, x: min(a.x, b.x), y: top, w: max(a.w, b.w), h: bot - top}
  end

  # Different part (e.g. switched slides mid-burst): the newer region wins.
  defp union_region(_a, b), do: b

  defp merge_min(nil, v), do: v
  defp merge_min(a, v), do: min(a, v)
  defp merge_max(nil, v), do: v
  defp merge_max(a, v), do: max(a, v)

  # (Re)arm the coalescing debounce: cancel any pending crisp repaint (typing
  # resumed) and (re)start the short flush timer so a burst paints once.
  # Leading-edge debounce: the FIRST keystroke (or first after an idle gap) paints
  # immediately (delay 0) so a single key has ~no added latency; keys arriving
  # within @repaint_debounce_ms of the last paint coalesce into one trailing
  # flush. A flush already armed just absorbs the merged region.
  defp arm_repaint(state) do
    state = cancel_timer(state, :crisp_timer)
    now = System.monotonic_time(:millisecond)

    cond do
      state.repaint_timer ->
        state

      is_integer(state.last_paint_ms) and now - state.last_paint_ms < @repaint_debounce_ms ->
        delay = @repaint_debounce_ms - (now - state.last_paint_ms)
        %{state | repaint_timer: Process.send_after(self(), :flush_repaint, delay)}

      true ->
        %{state | repaint_timer: Process.send_after(self(), :flush_repaint, 0)}
    end
  end

  # After a coalesced (scale-1) paint, schedule a single crisp (scale-2) repaint
  # for when typing has gone idle, so settled text ends up sharp.
  defp arm_crisp_repaint(state, region) do
    state = cancel_timer(state, :crisp_timer)
    timer = Process.send_after(self(), {:crisp_repaint, region}, @crisp_idle_ms)
    %{state | crisp_timer: timer}
  end

  defp cancel_timer(state, key) do
    case Map.get(state, key) do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        Map.put(state, key, nil)

      _ ->
        state
    end
  end

  # The page box (twips) whose y-range contains `doc_y`, or page 1 origin.
  defp nearest_page_for_twip_y(state, doc_y) do
    rects = guarded_page_rects(state)

    found =
      Enum.find_index(rects, fn %{y: y, height: h} -> doc_y >= y and doc_y <= y + h end)

    case found do
      nil ->
        case rects do
          [%{x: x, y: y} | _] -> %{page: 1, x: x, y: y}
          _ -> %{page: 1, x: 0, y: 0}
        end

      idx ->
        %{x: x, y: y} = Enum.at(rects, idx)
        %{page: idx + 1, x: x, y: y}
    end
  end

  defp page_origin_twips(state, page) do
    rects = guarded_page_rects(state)

    case Enum.at(rects, page - 1) do
      %{x: x, y: y} -> %{x: x, y: y}
      _ -> %{x: 0, y: 0}
    end
  end

  defp guarded_page_rects(state) do
    guarded(fn -> Edit.page_rects(state.edit) end, [])
  end

  defp normalize_caret(%{page: page, x: x, y: y, height: h}) do
    %{page: page, x: x, y: y, height: h}
  end

  defp normalize_caret(other), do: other

  defp notify(state, payload) do
    send(state.owner, {:office_edit, payload})
    :ok
  end

  # Run a guarded NIF op; map any raise/absent-NIF to `default`.
  defp guarded(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp safe_call(pid, msg, timeout \\ 10_000) do
    GenServer.call(pid, msg, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp px_to_twip(px) when is_number(px), do: round(px * @twips_per_px)
  defp twip_to_px(twip) when is_number(twip), do: round(twip / @twips_per_px)

  defp mul_round(n, scale), do: round(n * scale)
  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp vp(map, key, default) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_number(n) -> n
      _ -> default
    end
  end
end
