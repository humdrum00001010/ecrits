defmodule Contract.CommandTest do
  use ExUnit.Case, async: true

  alias Contract.Command

  describe "changeset/2" do
    test "requires :kind" do
      cs = Command.changeset(%Command{}, %{})
      refute cs.valid?
      assert {:kind, _} = List.keyfind(cs.errors, :kind, 0)
    end

    test "defaults actor_type to :user when missing" do
      cs = Command.changeset(%Command{}, %{kind: :create_document})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :user
    end

    test "respects an explicit actor_type" do
      cs = Command.changeset(%Command{}, %{kind: :create_document, actor_type: :agent})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :agent
    end

    test "idempotency_key must be 6..128 chars" do
      short =
        Command.changeset(%Command{}, %{kind: :create_document, idempotency_key: "abc"})

      long =
        Command.changeset(%Command{}, %{
          kind: :create_document,
          idempotency_key: String.duplicate("x", 129)
        })

      ok =
        Command.changeset(%Command{}, %{kind: :create_document, idempotency_key: "abc-123-xyz"})

      refute short.valid?
      assert List.keyfind(short.errors, :idempotency_key, 0)
      refute long.valid?
      assert ok.valid?
    end

    test "every document-scoped kind requires :document_id and accepts it when supplied" do
      doc_id = "11111111-1111-1111-1111-111111111111"

      for kind <- [
            :edit_document,
            :edit_text,
            :rename_document,
            :update_metadata,
            :set_contract_type
          ] do
        missing = Command.changeset(%Command{}, %{kind: kind})
        refute missing.valid?, "expected #{kind} to require :document_id"
        assert List.keyfind(missing.errors, :document_id, 0)

        present = Command.changeset(%Command{}, %{kind: kind, document_id: doc_id})
        assert present.valid?, "expected #{kind} to be valid with :document_id"
      end
    end

    test "kinds that aren't document-scoped do not require :document_id" do
      cs = Command.changeset(%Command{}, %{kind: :agent_change})
      assert cs.valid?
    end
  end

  describe "document_scoped_kinds/0" do
    test "returns the documented list" do
      kinds = Command.document_scoped_kinds()
      assert :edit_document in kinds
      assert :edit_text in kinds
      assert :rename_document in kinds
      assert :update_metadata in kinds
      assert :set_contract_type in kinds
      refute :create_document in kinds
      refute :agent_change in kinds
    end
  end
end
