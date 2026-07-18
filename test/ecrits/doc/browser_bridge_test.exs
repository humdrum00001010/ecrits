defmodule Ecrits.Doc.BrowserBridgeTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.BrowserBridge

  @tag :edit_failure
  test "returns immediately when the target viewer dies during a request" do
    owner = self()

    viewer =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:doc_browser_request, _from, _ref, :vfs_write, _payload} ->
               send(owner, :viewer_received_request)
           end
         end}
      )

    assert {:error, {:browser_unavailable, :normal}} =
             BrowserBridge.call(viewer, :vfs_write, %{edit_id: "dead-viewer"}, timeout: 1_000)

    assert_receive :viewer_received_request
  end

  @tag :edit_failure
  test "budgets pre-upload work and relays a binary error after the client upload deadline" do
    assert BrowserBridge.vfs_write_timeout() == 65_000

    pre_upload_budget = 20
    client_upload_deadline = 30
    reply_margin = 50
    server_deadline = pre_upload_budget + client_upload_deadline + reply_margin

    viewer =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:doc_browser_request, from, ref, :vfs_write, _payload} ->
               receive do
               after
                 pre_upload_budget + client_upload_deadline + 10 ->
                   send(from, {:doc_browser_reply, ref, {:error, "octet upload timed out"}})
               end

               receive do
                 {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
                   send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
               end
           end
         end}
      )

    assert {:error, "octet upload timed out"} =
             BrowserBridge.call(viewer, :vfs_write, %{edit_id: "near-deadline"},
               timeout: server_deadline
             )
  end

  @tag :edit_failure
  test "times out with an explicit cancellation before a late browser reply" do
    owner = self()

    viewer =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:doc_browser_request, from, ref, :vfs_write, payload} ->
               send(owner, {:viewer_received_request, ref, payload})

               receive do
                 {:doc_browser_request_cancelled, ^from, ^ref, reason} ->
                   send(owner, {:viewer_received_cancellation, ref, reason})
                   send(from, {:doc_browser_reply, ref, {:ok, %{octet_id: "late-octet"}}})
               end
           end
         end}
      )

    assert {:error, {:browser_timeout, "viewer did not reply in time"}} =
             BrowserBridge.call(viewer, :vfs_write, %{edit_id: "timed-out"}, timeout: 20)

    assert_receive {:viewer_received_request, ref, %{edit_id: "timed-out"}}
    assert_receive {:viewer_received_cancellation, ^ref, :timeout}
    assert_receive {:doc_browser_reply, ^ref, {:ok, %{octet_id: "late-octet"}}}
    refute_receive {:doc_browser_request_completed, _, ^ref}
    refute_receive {:doc_browser_request_completed, _, ^ref, _ack_ref}
  end

  test "does not return a successful reply until the viewer processes completion" do
    owner = self()

    viewer =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:doc_browser_request, from, ref, :vfs_commit, %{edit_id: edit_id}} ->
               send(from, {:doc_browser_reply, ref, {:ok, %{edit_id: edit_id}}})

               receive do
                 {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
                   send(owner, {:viewer_received_completion, self(), ref})

                   receive do
                     :release_completion_ack ->
                       send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
                   end
               end
           end
         end}
      )

    caller =
      Task.async(fn ->
        BrowserBridge.call(viewer, :vfs_commit, %{edit_id: "commit-ack"}, timeout: 1_000)
      end)

    assert_receive {:viewer_received_completion, ^viewer, _ref}
    refute Task.yield(caller, 0)
    send(viewer, :release_completion_ack)

    assert {:ok, %{edit_id: "commit-ack"}} = Task.await(caller, 1_000)
  end
end
