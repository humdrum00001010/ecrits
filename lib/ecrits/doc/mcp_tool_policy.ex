defmodule Ecrits.Doc.MCPToolPolicy do
  @moduledoc false

  alias Ecrits.Prompt

  @vfs_primary_tools ~w(doc.open_doc doc.find)
  @vfs_fallback_tools ~w(doc.edit)
  @vfs_allowed_tools @vfs_primary_tools ++ @vfs_fallback_tools
  @vfs_edit_fallback_reasons ~w(unrepresentable)
  @vfs_native_picture_op_keys ~w(op ref src)

  # The projection owns every ordinary document mutation in VFS mode. The sole
  # native escape hatch is precise picture placement at an existing marker.

  # [deprecated] dead code — no callers; all internal uses read the module attribute directly (dead-code audit 2026-07-13)
  @spec vfs_allowed_tools() :: [String.t()]
  def vfs_allowed_tools, do: @vfs_allowed_tools

  @spec vfs_allowed?(String.t()) :: boolean()
  def vfs_allowed?(name), do: name in @vfs_allowed_tools

  @doc "The normal VFS entry points; `doc.edit` is deliberately not one of them."
  @spec vfs_primary_tools() :: [String.t()]
  def vfs_primary_tools, do: @vfs_primary_tools

  @doc "The narrow ACP escape hatch that is available only with explicit evidence."
  @spec vfs_fallback_tools() :: [String.t()]
  def vfs_fallback_tools, do: @vfs_fallback_tools

  @doc "Validate the explicit native-capability evidence required for a `doc.edit` fallback."
  @spec validate_vfs_edit_fallback(map()) :: :ok | {:error, map()}
  def validate_vfs_edit_fallback(%{"fallback" => %{} = fallback} = args) do
    reason = Map.get(fallback, "reason")
    detail = Map.get(fallback, "detail")
    attempted = Map.get(fallback, "attempted")
    mounted_at = Map.get(fallback, "mounted_at")

    cond do
      attempted != "vfs" or reason not in @vfs_edit_fallback_reasons or
        not is_binary(detail) or String.trim(detail) == "" or not is_binary(mounted_at) or
          String.trim(mounted_at) == "" ->
        {:error, vfs_edit_fallback_required_message()}

      not vfs_unrepresentable_edit?(args) ->
        {:error, vfs_fallback_unrepresentable_required_message()}

      true ->
        :ok
    end
  end

  def validate_vfs_edit_fallback(_args), do: {:error, vfs_edit_fallback_required_message()}

  @doc "Gate a cached or newly discovered MCP call while VFS mode is active."
  @spec authorize_vfs_call(String.t(), map()) :: :ok | {:error, map()}
  def authorize_vfs_call("doc.edit", args), do: validate_vfs_edit_fallback(args)
  def authorize_vfs_call(name, _args) when name in @vfs_primary_tools, do: :ok
  def authorize_vfs_call(name, _args), do: {:error, disabled_in_vfs_message(name)}

  @doc "Fresh per-turn sequence state for the mounted ACP workflow."
  @spec new_vfs_sequence() :: map()
  def new_vfs_sequence, do: %{phase: :awaiting_open}

  @doc "Authorize one document-tool call against the mounted ACP turn sequence."
  @spec authorize_vfs_sequence(String.t(), map(), map(), map()) ::
          :ok | {:error, map()}
  def authorize_vfs_sequence(name, args, sequence, evidence \\ %{})

  def authorize_vfs_sequence(
        "doc.open_doc",
        %{"path" => "current"},
        %{phase: :awaiting_open},
        _evidence
      ),
      do: :ok

  def authorize_vfs_sequence("doc.open_doc", _args, %{phase: :awaiting_open}, _evidence),
    do: {:error, current_open_required_message()}

  def authorize_vfs_sequence("doc.open_doc", _args, _sequence, _evidence),
    do: {:error, repeated_open_message()}

  def authorize_vfs_sequence(
        "doc.find",
        _args,
        %{native_marker_find_spent?: true},
        _evidence
      ),
      do: {:error, native_marker_find_spent_message()}

  def authorize_vfs_sequence("doc.find", _args, %{phase: :awaiting_open}, _evidence),
    do: {:error, native_marker_find_before_open_message()}

  def authorize_vfs_sequence(name, _args, %{phase: :awaiting_open}, _evidence)
      when name != "doc.open_doc",
      do: {:error, open_first_message(name)}

  def authorize_vfs_sequence("doc.find", args, %{phase: :acp_primary} = sequence, evidence) do
    with :ok <- validate_native_marker_find(args, sequence),
         :ok <- check_find_commit_evidence(evidence),
         :ok <- check_find_pattern_addressable(args, sequence, evidence) do
      :ok
    end
  end

  def authorize_vfs_sequence("doc.find", _args, _sequence, _evidence),
    do: {:error, native_marker_find_spent_message()}

  def authorize_vfs_sequence(
        "doc.edit",
        args,
        %{phase: :native_marker_ref_ready} = sequence,
        _evidence
      ) do
    with :ok <- validate_vfs_edit_fallback(args),
         :ok <- validate_native_picture_edit(args, sequence) do
      :ok
    end
  end

  def authorize_vfs_sequence("doc.edit", _args, _sequence, _evidence),
    do: {:error, native_marker_ref_required_message()}

  def authorize_vfs_sequence(name, _args, _sequence, _evidence),
    do: {:error, disabled_in_vfs_message(name)}

  @doc "Record a successful `doc.open_doc` and its accepted projection revision."
  @spec record_vfs_open(map(), map(), binary() | nil) :: map()
  def record_vfs_open(sequence, result, revision) when is_map(result) do
    if valid_open_result?(result, revision) do
      %{
        sequence
        | phase: :acp_primary
      }
      |> Map.put(:document, Map.get(result, "document"))
      |> Map.put(:mounted_at, Map.get(result, "mounted_at"))
      |> Map.put(:mount_name, Map.get(result, "mount_name"))
      |> Map.put(:source_path, Map.get(result, "path"))
      |> Map.put(:baseline_revision, revision)
    else
      sequence
    end
  end

  @doc "Add server-owned placement details after the one native-marker fallback is authorized."
  @spec prepare_vfs_call(String.t(), map(), map()) :: map()
  def prepare_vfs_call(name, args, sequence \\ %{})

  def prepare_vfs_call("doc.edit", %{"op" => %{} = op} = args, sequence) do
    marker = Map.get(sequence, :native_marker)

    placement =
      %{"inline_in_cell" => false}
      |> maybe_put_marker_length(marker)

    Map.put(args, "op", Map.merge(op, placement))
  end

  # `occurrence` is policy-level addressing, not a search argument: the
  # underlying find runs with limit = occurrence so its document-ordered result
  # contains the intended match last, and `finalize_vfs_find_result/2` selects it.
  def prepare_vfs_call("doc.find", %{"occurrence" => occurrence} = args, _sequence)
      when is_integer(occurrence) and occurrence >= 1 do
    args
    |> Map.delete("occurrence")
    |> Map.put("limit", occurrence)
  end

  def prepare_vfs_call("doc.find", args, _sequence), do: Map.delete(args, "occurrence")

  def prepare_vfs_call(_name, args, _sequence), do: args

  @doc "Consume the one marker lookup and retain its unique exact returned evidence."
  @spec record_vfs_find(map(), map(), map()) :: map()
  def record_vfs_find(sequence, result, request \\ %{})

  def record_vfs_find(sequence, result, request) when is_map(result) do
    requested_marker = Map.get(request, "marker")

    matches =
      result
      |> Map.get("matches", [])
      |> Enum.flat_map(fn
        %{
          "before_marker_ref" => ref,
          "marker" => marker,
          "marker_offset" => offset
        }
        when is_binary(ref) and ref != "" and is_binary(marker) and marker != "" and
               is_integer(offset) and offset >= 0 and marker == requested_marker ->
          [%{ref: ref, marker: marker, offset: offset}]

        _match ->
          []
      end)
      |> Enum.uniq()

    case matches do
      [%{ref: ref, marker: marker, offset: offset}] ->
        sequence
        |> Map.put(:phase, :native_marker_ref_ready)
        |> Map.put(:native_marker_ref, ref)
        |> Map.put(:native_marker, marker)
        |> Map.put(:native_marker_offset, offset)

      _matches ->
        Map.put(sequence, :phase, :native_marker_find_spent)
    end
  end

  def record_vfs_find(sequence, _result, _request),
    do: Map.put(sequence, :phase, :native_marker_find_spent)

  @doc "Make every completed marker lookup explicitly terminal unless it returned one usable ref."
  @spec finalize_vfs_find_result({:ok, term()} | {:error, term()}, map()) ::
          {:ok, term()} | {:error, map()}
  def finalize_vfs_find_result(result, request \\ %{})

  def finalize_vfs_find_result({:ok, %{} = result}, request) do
    requested_marker = Map.get(request, "marker")
    occurrence = Map.get(request, "occurrence")
    raw_matches = Map.get(result, "matches", [])
    usable = Enum.filter(raw_matches, &usable_marker_match?(&1, requested_marker))

    cond do
      is_integer(occurrence) and occurrence >= 1 ->
        # The find ran with limit = occurrence over the committed document
        # order, so the intended paragraph is the last usable match. Ordinals
        # only hold if every returned match was usable.
        chosen = Enum.at(usable, occurrence - 1)

        if length(usable) == length(raw_matches) and not is_nil(chosen) do
          {:ok, Map.put(result, "matches", [chosen])}
        else
          {:error, native_marker_not_found_message()}
        end

      true ->
        case Enum.uniq_by(usable, &Map.take(&1, ["before_marker_ref", "marker", "marker_offset"])) do
          [_match] -> {:ok, result}
          [] -> {:error, native_marker_not_found_message()}
          many -> {:error, native_marker_not_unique_message(length(many))}
        end
    end
  end

  def finalize_vfs_find_result({:error, reason}, _request),
    do: {:error, native_marker_lookup_failed_message(reason)}

  def finalize_vfs_find_result(other, _request),
    do: {:error, native_marker_lookup_failed_message(other)}

  defp usable_marker_match?(
         %{
           "before_marker_ref" => ref,
           "marker" => marker,
           "marker_offset" => offset
         },
         requested_marker
       )
       when is_binary(ref) and ref != "" and is_binary(marker) and marker != "" and
              is_integer(offset) and offset >= 0,
       do: marker == requested_marker

  defp usable_marker_match?(_match, _requested_marker), do: false

  @doc "Consume the single native picture fallback, whether it succeeds or fails."
  @spec record_vfs_edit(map()) :: map()
  def record_vfs_edit(sequence), do: Map.put(sequence, :phase, :native_fallback_spent)

  @spec restrict_for_vfs([map()], boolean()) :: [map()]
  def restrict_for_vfs(tools, true) when is_list(tools) do
    tools
    |> Enum.filter(&(tool_name(&1) in @vfs_allowed_tools))
    |> Enum.map(&vfs_tool_descriptor/1)
  end

  def restrict_for_vfs(tools, _vfs_enabled), do: tools

  @spec disabled_in_vfs_message(String.t()) :: map()
  def disabled_in_vfs_message(name) do
    %{
      "error" => "disabled_in_fuse_mode",
      "tool" => name,
      "message" =>
        "This tool is unavailable while the primary workspace document surface is active. " <>
          "`doc.edit` is fallback-only when that surface cannot represent the change."
    }
  end

  defp vfs_tool_descriptor(tool) do
    case tool_name(tool) do
      "doc.open_doc" -> vfs_open_doc_descriptor(tool)
      "doc.find" -> vfs_find_descriptor(tool)
      "doc.edit" -> vfs_fallback_edit_descriptor(tool)
      _name -> tool
    end
  end

  defp vfs_open_doc_descriptor(tool) do
    tool
    |> Map.put("description", Prompt.vfs_open_doc_tool_description())
    |> Map.put("inputSchema", %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "const" => "current", "default" => "current"}
      },
      "required" => ["path"],
      "additionalProperties" => false
    })
  end

  defp vfs_find_descriptor(tool),
    do:
      tool
      |> Map.put(
        "description",
        "One post-commit marker lookup only: copy the exact requested target paragraph containing its existing marker exactly once, then use before_marker_ref verbatim. If that exact paragraph text repeats in the document, add occurrence (1-based, document order) to pick the intended one."
      )
      |> Map.put("inputSchema", native_marker_find_schema())

  defp vfs_fallback_edit_descriptor(tool) do
    fallback_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "description" => "Required evidence for a fallback edit.",
      "properties" => %{
        "attempted" => %{
          "type" => "string",
          "enum" => ["vfs"],
          "description" => "Primary surface attempted."
        },
        "reason" => %{
          "type" => "string",
          "enum" => @vfs_edit_fallback_reasons,
          "description" => "Why the primary surface cannot represent the native change."
        },
        "detail" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Observed limitation or failure."
        },
        "mounted_at" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Exact primary-surface path for this document."
        }
      },
      "required" => ["attempted", "reason", "detail", "mounted_at"]
    }

    picture_op_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "op" => %{"type" => "string", "enum" => ["insert_picture"]},
        "ref" => %{
          "type" => "string",
          "description" => "Exact before_marker_ref returned by post-commit doc.find."
        },
        "src" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Original user-supplied workspace image."
        }
      },
      "required" => ["op", "ref", "src"]
    }

    input_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "document" => %{"type" => "string"},
        "op" => picture_op_schema,
        "fallback" => fallback_schema
      },
      "required" => ["document", "op", "fallback"]
    }

    tool
    |> Map.put("description", Prompt.vfs_edit_fallback_tool_description())
    |> Map.put("inputSchema", input_schema)
  end

  defp vfs_edit_fallback_required_message do
    %{
      "error" => "vfs_fallback_required",
      "tool" => "doc.edit",
      "message" =>
        "`doc.edit` needs evidence that the primary workspace document surface cannot " <>
          "represent this native change.",
      "required_fallback" => %{
        "attempted" => "vfs",
        "reason" => @vfs_edit_fallback_reasons,
        "detail" => "exact unsupported native construct",
        "mounted_at" => "the exact path returned by doc.open_doc"
      }
    }
  end

  defp vfs_fallback_unrepresentable_required_message do
    %{
      "error" => "vfs_fallback_unrepresentable_required",
      "tool" => "doc.edit",
      "message" =>
        "`doc.edit` with `reason: unrepresentable` is limited to an explicitly requested native picture at an exact existing marker. Use the primary surface for text, tables, and node changes; pass the unique marker reference returned by this turn's lookup."
    }
  end

  defp native_marker_find_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "document" => %{"type" => "string", "minLength" => 1},
        "pattern" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Exact committed target paragraph containing the requested marker once."
        },
        "type" => %{"type" => "string", "const" => "paragraph"},
        "marker" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Literal marker already present where the requested picture belongs."
        },
        "case_sensitive" => %{"type" => "boolean", "const" => true},
        "limit" => %{"type" => "integer", "const" => 1},
        "occurrence" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" =>
            "Only when the exact target paragraph text repeats in the document: " <>
              "1-based index of the intended paragraph in document order."
        }
      },
      "required" => ["document", "pattern", "type", "marker", "case_sensitive", "limit"]
    }
  end

  defp validate_native_marker_find(args, sequence) do
    pattern = Map.get(args, "pattern")
    marker = Map.get(args, "marker")
    occurrence = Map.get(args, "occurrence")

    cond do
      Map.get(args, "document") != Map.get(sequence, :document) ->
        {:error, exact_native_marker_find_required_message()}

      Map.get(args, "type") != "paragraph" or
        Map.get(args, "case_sensitive") != true or Map.get(args, "limit") != 1 ->
        {:error, exact_native_marker_find_required_message()}

      not is_binary(pattern) or pattern == "" or not is_binary(marker) or marker == "" or
          length(:binary.matches(pattern, marker)) != 1 ->
        {:error, exact_native_marker_find_required_message()}

      not (is_nil(occurrence) or (is_integer(occurrence) and occurrence >= 1)) ->
        {:error, exact_native_marker_find_required_message()}

      Map.has_key?(args, "patterns") or Map.get(args, "all") == true or
          Map.get(args, "regex") == true ->
        {:error, exact_native_marker_find_required_message()}

      true ->
        :ok
    end
  end

  # Commit evidence and pattern addressability are separate failures with
  # separate recoveries: a missing commit has not performed a lookup and can be
  # retried without consuming one, while a stale or repeated pattern earns one
  # corrected retry (see `retryable_find_error?/1`), because 2026-07-19 field
  # evidence showed a full
  # brief-driven fill making every annex signature row byte-identical — the
  # unique-pattern grammar simply cannot address 1-of-N without an ordinal.
  defp check_find_commit_evidence(evidence) do
    cond do
      Map.get(evidence, :committed_projection?) != true ->
        {:error, acp_commit_required_message()}

      Map.get(evidence, :primary_committed?) != true ->
        {:error, acp_commit_required_message()}

      true ->
        :ok
    end
  end

  defp check_find_pattern_addressable(args, sequence, evidence) do
    count = Map.get(evidence, :exact_count, 0)
    occurrence = Map.get(args, "occurrence")
    retry_allowed? = Map.get(sequence, :find_retry_used?) != true

    cond do
      count == 0 ->
        {:error, find_pattern_not_committed_message(retry_allowed?)}

      is_nil(occurrence) and count == 1 ->
        :ok

      is_integer(occurrence) and occurrence <= count ->
        :ok

      true ->
        {:error, find_pattern_ambiguous_message(count, occurrence, retry_allowed?)}
    end
  end

  @doc "Find failures that allow another attempt."
  @spec retryable_find_error?(term()) :: boolean()
  def retryable_find_error?(%{"error" => error}),
    do:
      error in [
        "acp_commit_required",
        "find_pattern_not_committed",
        "find_pattern_ambiguous"
      ]

  def retryable_find_error?(_reason), do: false

  @doc "Find failures raised before any native lookup, so neither retry allowance is consumed."
  @spec non_consuming_find_error?(term()) :: boolean()
  def non_consuming_find_error?(%{"error" => "acp_commit_required"}), do: true
  def non_consuming_find_error?(_reason), do: false

  defp validate_native_picture_edit(args, sequence) do
    op = Map.get(args, "op", %{})
    fallback = Map.get(args, "fallback", %{})

    cond do
      Map.get(args, "document") != Map.get(sequence, :document) ->
        {:error, native_marker_ref_required_message()}

      Map.get(op, "op") != "insert_picture" or
        Map.get(op, "ref") != Map.get(sequence, :native_marker_ref) or
          not exact_native_picture_op_keys?(op) ->
        {:error, native_marker_ref_required_message()}

      Map.get(fallback, "mounted_at") != Map.get(sequence, :mounted_at) ->
        {:error, native_marker_ref_required_message()}

      true ->
        :ok
    end
  end

  defp valid_open_result?(result, revision) do
    nonempty_binary?(Map.get(result, "document")) and
      nonempty_binary?(Map.get(result, "mounted_at")) and
      nonempty_binary?(Map.get(result, "mount_name")) and
      nonempty_binary?(Map.get(result, "path")) and
      is_nil(Map.get(result, "mount_error")) and is_binary(revision)
  end

  defp nonempty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp open_first_message(name) do
    %{
      "error" => "doc_open_required_first",
      "tool" => name,
      "message" => "Call doc.open_doc once with path current before any other document tool."
    }
  end

  defp current_open_required_message do
    %{
      "error" => "current_document_open_required",
      "tool" => "doc.open_doc",
      "message" => "Open only the current document: doc.open_doc {path: current}."
    }
  end

  defp repeated_open_message do
    %{
      "error" => "doc_already_opened_for_turn",
      "tool" => "doc.open_doc",
      "message" => "The current projection is already open for this turn; keep using it."
    }
  end

  defp acp_commit_required_message do
    %{
      "error" => "acp_commit_required",
      "tool" => "doc.find",
      "message" =>
        "No native-marker lookup ran because the primary ACP edit is not durably committed yet. This attempt was not consumed. Wait for or correct the durable commit, then call doc.find again with the same exact marker request."
    }
  end

  defp find_pattern_not_committed_message(retry_allowed?) do
    %{
      "error" => "find_pattern_not_committed",
      "tool" => "doc.find",
      "message" =>
        "The exact pattern does not appear as a committed paragraph, so no marker reference was produced." <>
          if retry_allowed? do
            " One corrected retry is allowed: reread the mounted projection now and copy the committed target paragraph text exactly."
          else
            " The corrected retry was already used; do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
          end
    }
  end

  defp find_pattern_ambiguous_message(count, occurrence, retry_allowed?) do
    occurrence_note =
      if is_integer(occurrence) do
        "The requested occurrence #{occurrence} exceeds the committed match count. "
      else
        ""
      end

    %{
      "error" => "find_pattern_ambiguous",
      "tool" => "doc.find",
      "count" => count,
      "message" =>
        "#{occurrence_note}The exact pattern appears #{count} times in the committed projection, so it cannot address one target by itself." <>
          if retry_allowed? do
            " One corrected retry is allowed: add occurrence (a 1-based index in document order, between 1 and #{count}) to pick the intended paragraph."
          else
            " The corrected retry was already used; do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
          end
    }
  end

  defp native_marker_find_before_open_message do
    %{
      "error" => "native_marker_find_before_open",
      "tool" => "doc.find",
      "message" =>
        "The one native-marker lookup was attempted before doc.open_doc and is now consumed. Do not call doc.find again in this turn. Open the current document, finish supported ACP edits, and report that the native picture fallback could not run."
    }
  end

  defp exact_native_marker_find_required_message do
    %{
      "error" => "exact_native_marker_find_required",
      "tool" => "doc.find",
      "message" =>
        "The one native-marker lookup was malformed or did not exactly match the committed target and is now consumed. Do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
    }
  end

  defp native_marker_find_spent_message do
    %{
      "error" => "native_marker_find_already_used",
      "tool" => "doc.find",
      "message" =>
        "The single native-marker lookup is unavailable or already consumed. Do not call doc.find again in this turn."
    }
  end

  defp native_marker_ref_required_message do
    %{
      "error" => "native_marker_ref_required",
      "tool" => "doc.edit",
      "message" =>
        "Insert one requested picture at the exact existing-marker ref returned by this turn's lookup and the exact mounted_at returned by doc.open_doc. Placement and sizing are server-owned."
    }
  end

  defp native_marker_not_found_message do
    %{
      "error" => "native_marker_not_found",
      "tool" => "doc.find",
      "message" =>
        "The one native-marker lookup returned no usable exact marker reference and is now consumed. Do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
    }
  end

  defp native_marker_not_unique_message(count) do
    %{
      "error" => "native_marker_not_unique",
      "tool" => "doc.find",
      "count" => count,
      "message" =>
        "The one native-marker lookup did not return one unique marker reference and is now consumed. Do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
    }
  end

  defp native_marker_lookup_failed_message(reason) do
    %{
      "error" => "native_marker_lookup_failed",
      "tool" => "doc.find",
      "cause" => inspect(reason, limit: 20, printable_limit: 200),
      "message" =>
        "The one native-marker lookup failed downstream and is now consumed. Do not call doc.find again in this turn. Finish supported ACP edits and report that the native picture fallback could not run."
    }
  end

  defp maybe_put_marker_length(placement, marker) when is_binary(marker) and marker != "",
    do: Map.put(placement, "overlay_marker_length", String.length(marker))

  defp maybe_put_marker_length(placement, _marker), do: placement

  defp vfs_unrepresentable_edit?(args) do
    ops =
      case Map.get(args, "ops") do
        ops when is_list(ops) -> ops
        _ -> List.wrap(Map.get(args, "op"))
      end

    ops != [] and
      Enum.all?(ops, &vfs_unrepresentable_op?/1)
  end

  defp vfs_unrepresentable_op?(
         %{
           "op" => "insert_picture",
           "ref" => ref,
           "src" => src
         } = op
       )
       when is_binary(ref) and is_binary(src) and src != "" do
    with true <- exact_native_picture_op_keys?(op),
         {:ok, decoded} <- Jason.decode(ref),
         section when is_integer(section) and section >= 0 <- Map.get(decoded, "section"),
         paragraph when is_integer(paragraph) and paragraph >= 0 <- Map.get(decoded, "paragraph"),
         offset when is_integer(offset) and offset >= 0 <- Map.get(decoded, "offset"),
         true <- valid_optional_cell_path?(decoded) do
      true
    else
      _ -> false
    end
  end

  defp vfs_unrepresentable_op?(_op), do: false

  defp exact_native_picture_op_keys?(op) when is_map(op),
    do: op |> Map.keys() |> Enum.sort() == Enum.sort(@vfs_native_picture_op_keys)

  defp valid_optional_cell_path?(ref) do
    case Map.get(ref, "cellPath") || Map.get(ref, "cell_path") do
      nil ->
        true

      cell_path when is_list(cell_path) and cell_path != [] ->
        Enum.all?(cell_path, &valid_cell_path_step?/1)

      _invalid ->
        false
    end
  end

  defp valid_cell_path_step?(step) when is_map(step) do
    Enum.all?(~w(controlIndex cellIndex cellParaIndex), fn key ->
      value = Map.get(step, key)
      is_integer(value) and value >= 0
    end)
  end

  defp valid_cell_path_step?(_step), do: false

  defp tool_name(%{"namespace" => ns, "name" => name}) when is_binary(ns) and is_binary(name),
    do: ns <> "." <> name

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(_tool), do: nil
end
