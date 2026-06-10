defmodule Ecrits.RhwpSnapshotMaterializerTest do
  use ExUnit.Case, async: false

  alias Ecrits.RhwpSnapshot.Materializer

  test "ensure_committed returns no_live_editor without a registered editor" do
    document_id = Ecto.UUID.generate()

    assert {:error, :no_live_editor} = Materializer.ensure_committed(document_id, timeout: 25)
  end

  test "failure ack returns the editor reason" do
    document_id = Ecto.UUID.generate()
    editor = start_editor!(document_id)

    ensure = start_ensure!(document_id, timeout: 500)

    assert_receive {:editor_request, ^editor, request}

    send(editor, {:ack, request.request_id, {:error, :render_failed}})

    assert {:error, :render_failed} = receive_ensure_result(ensure)
  end

  test "ack for another document is ignored until a matching ack arrives" do
    document_id = Ecto.UUID.generate()
    other_document_id = Ecto.UUID.generate()
    editor = start_editor!(document_id)

    ensure = start_ensure!(document_id, timeout: 500)

    assert_receive {:editor_request, ^editor, request}

    send(
      editor,
      {:ack, request.request_id, committed(other_document_id, %{wrong_document: true})}
    )

    send(editor, {:ack, request.request_id, committed(document_id, %{fresh: true})})

    assert {:ok,
            %{
              request_id: request_id,
              document_id: ^document_id,
              snapshot: %{fresh: true}
            }} = receive_ensure_result(ensure)

    assert request_id == request.request_id
  end

  test "ensure_committed includes committed text events in editor request" do
    document_id = Ecto.UUID.generate()
    editor = start_editor!(document_id)
    text_events = [%{"kind" => "insert_text", "text" => "materialize-me"}]
    base_snapshot = %{url: "/documents/#{document_id}/rhwp-snapshots/current.hwp"}

    ensure =
      start_ensure!(document_id,
        timeout: 500,
        text_events: text_events,
        base_snapshot: base_snapshot
      )

    assert_receive {:editor_request, ^editor, request}
    assert request.text_events == text_events
    assert request.base_snapshot == base_snapshot

    send(editor, {:ack, request.request_id, committed(document_id, %{fresh: true})})

    assert {:ok, %{snapshot: %{fresh: true}}} = receive_ensure_result(ensure)
  end

  test "first good ack wins" do
    document_id = Ecto.UUID.generate()
    first = start_editor!(document_id)
    second = start_editor!(document_id)

    ensure = start_ensure!(document_id, timeout: 500)

    request_id =
      receive_request_id(first, second)

    send(first, {:ack, request_id, committed(document_id, %{winner: :first})})

    assert {:ok,
            %{
              request_id: ^request_id,
              document_id: ^document_id,
              snapshot: %{winner: :first}
            }} = receive_ensure_result(ensure)

    send(second, {:ack, request_id, committed(document_id, %{winner: :second})})
  end

  defp start_editor!(document_id) do
    parent = self()

    pid =
      start_supervised!(%{
        id: {:rhwp_materializer_test_editor, make_ref()},
        start:
          {Task, :start_link,
           [
             fn ->
               :ok = Materializer.register_editor(document_id)
               send(parent, {:editor_registered, self()})
               editor_loop(parent)
             end
           ]},
        restart: :temporary
      })

    assert_receive {:editor_registered, ^pid}

    pid
  end

  defp start_ensure!(document_id, opts) do
    parent = self()

    start_supervised!(%{
      id: {:rhwp_materializer_test_ensure, make_ref()},
      start:
        {Task, :start_link,
         [
           fn ->
             result = Materializer.ensure_committed(document_id, opts)
             send(parent, {:ensure_result, self(), result})
           end
         ]},
      restart: :temporary
    })
  end

  defp receive_ensure_result(pid) do
    assert_receive {:ensure_result, ^pid, result}, 1_000
    result
  end

  defp editor_loop(parent) do
    receive do
      {:rhwp_positional_index_request, request} ->
        send(parent, {:editor_request, self(), request})
        editor_loop(parent)

      {:ack, request_id, result} ->
        :ok = Materializer.ack(request_id, result)
        editor_loop(parent)
    end
  end

  defp committed(document_id, snapshot) do
    %{
      status: :committed,
      document_id: document_id,
      snapshot: snapshot
    }
  end

  defp receive_request_id(first, second) do
    assert_receive {:editor_request, ^first, first_request}
    assert_receive {:editor_request, ^second, second_request}
    assert first_request.request_id == second_request.request_id
    first_request.request_id
  end
end
