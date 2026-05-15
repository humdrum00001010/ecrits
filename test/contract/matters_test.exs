defmodule Contract.MattersTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Matters
  alias Contract.Matters.Matter

  defp scope(opts \\ []) do
    tenant =
      case Keyword.get(opts, :tenant, :auto) do
        :auto -> Ecto.UUID.generate()
        nil -> nil
        explicit -> explicit
      end

    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    %Context{
      user: %Contract.Accounts.User{id: user_id, email: "u#{System.unique_integer([:positive])}@x"},
      tenant: tenant
    }
  end

  describe "create/2" do
    test "creates a matter owned by the scope user" do
      s = scope()
      assert {:ok, %Matter{name: "M1", owner_id: owner, tenant_id: tenant}} =
               Matters.create(s, %{"name" => "M1"})

      assert owner == s.user.id
      assert tenant == s.tenant
    end

    test "without a user is :forbidden" do
      assert {:error, :forbidden} =
               Matters.create(%Context{tenant: "t"}, %{"name" => "x"})
    end

    test "returns changeset on missing required" do
      assert {:error, %Ecto.Changeset{}} = Matters.create(scope(), %{})
    end
  end

  describe "list_for_scope/1" do
    test "returns active matters in the scope's tenant" do
      s = scope()
      {:ok, m1} = Matters.create(s, %{"name" => "A"})
      {:ok, m2} = Matters.create(s, %{"name" => "B"})

      ids = s |> Matters.list_for_scope() |> Enum.map(& &1.id)
      assert m1.id in ids
      assert m2.id in ids
    end

    test "filters out archived matters" do
      s = scope()
      {:ok, m} = Matters.create(s, %{"name" => "to_archive"})
      {:ok, _} = Matters.archive(s, m.id)

      ids = s |> Matters.list_for_scope() |> Enum.map(& &1.id)
      refute m.id in ids
    end

    test "scopes by tenant — cross-tenant matters invisible" do
      a = scope()
      b = scope()
      {:ok, ma} = Matters.create(a, %{"name" => "A's"})

      ids_b = b |> Matters.list_for_scope() |> Enum.map(& &1.id)
      refute ma.id in ids_b
    end

    test "tenant-nil matters are visible to any scope" do
      a = scope()

      {:ok, m} =
        Matters.create(a, %{"name" => "single-tenant", "tenant_id" => nil})

      # Re-read via Repo to confirm tenant_id is nil
      reloaded = Contract.Repo.get!(Matter, m.id)
      assert reloaded.tenant_id == nil

      b = scope()
      ids_b = b |> Matters.list_for_scope() |> Enum.map(& &1.id)
      assert m.id in ids_b
    end
  end

  describe "get/2" do
    test "fetches a matter the scope can see" do
      s = scope()
      {:ok, m} = Matters.create(s, %{"name" => "g"})

      assert {:ok, %Matter{id: id}} = Matters.get(s, m.id)
      assert id == m.id
    end

    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Matters.get(scope(), Ecto.UUID.generate())
    end

    test "scope mismatch returns :forbidden" do
      a = scope()
      b = scope()
      {:ok, m} = Matters.create(a, %{"name" => "x"})

      assert {:error, :forbidden} = Matters.get(b, m.id)
    end

    test "malformed uuid returns :not_found" do
      assert {:error, :not_found} = Matters.get(scope(), "not-a-uuid")
    end
  end

  describe "archive/2" do
    test "owner can archive" do
      s = scope()
      {:ok, m} = Matters.create(s, %{"name" => "to-arch"})
      assert {:ok, %Matter{status: :archived}} = Matters.archive(s, m.id)
    end

    test "non-owner cannot archive even within tenant" do
      tenant = Ecto.UUID.generate()
      owner = scope(tenant: tenant)
      other = scope(tenant: tenant)
      {:ok, m} = Matters.create(owner, %{"name" => "x"})

      assert {:error, :forbidden} = Matters.archive(other, m.id)
    end
  end
end
