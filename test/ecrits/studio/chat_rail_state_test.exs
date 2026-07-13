defmodule Ecrits.Studio.ChatRailStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Studio.ChatRailState
  alias Ecrits.Studio.State

  test "projects the rail's application state through one embedded schema" do
    state =
      ChatRailState.new(%{
        studio_state: %State{mode: :reviewing, agent_run_id: "run-1"},
        agent_document_status: %{
          current_attempt: %{id: "run-1"},
          queue: [%{id: "run-2"}]
        },
        current_scope: %{perms: [:read, :write, :commit, :agent_run]},
        chat_thread: %{title: "Review", message_count: 3},
        layout: :mobile_full,
        grill_active?: true,
        grill_marks: [%{id: "ask-1", intent: :ask, text: "Confirm?"}]
      })

    assert %ChatRailState{
             mode: :reviewing,
             agent_run_id: "run-1",
             agent_status: :queued,
             agent_current_run_id: "run-1",
             agent_queue_size: 1,
             permissions: [:read, :write, :commit, :agent_run],
             thread_title: "Review",
             thread_message_count: 3,
             layout: :mobile_full,
             grill_active?: true,
             grill_marks: [%{id: "ask-1", intent: :ask, text: "Confirm?"}]
           } = state

    assert ChatRailState.mobile?(state)
    assert ChatRailState.observer_mode?(state)
    assert ChatRailState.busy?(state)
    refute ChatRailState.chat_context_empty?(state)
  end

  test "changeset owns typed validation" do
    changeset =
      ChatRailState.changeset(%ChatRailState{}, %{
        layout: :unknown,
        agent_queue_size: -1,
        thread_message_count: -1
      })

    refute changeset.valid?
    assert errors_on(changeset).layout != []
    assert errors_on(changeset).agent_queue_size != []
    assert errors_on(changeset).thread_message_count != []

    assert %ChatRailState{layout: :default, agent_queue_size: 0, thread_message_count: 0} =
             ChatRailState.new(%{
               layout: :unknown,
               agent_queue_size: -1,
               thread_message_count: -1
             })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
