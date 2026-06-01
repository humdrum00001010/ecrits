defmodule Contract.ContractTypesDocumentTypeTest do
  use Contract.DataCase, async: true

  alias Contract.ContractTypes
  alias Contract.ContractTypes.DocumentType

  test "matching book is stored on the admin-managed document type row" do
    matching_book = %{
      "indexesById" => %{"a" => %{"raw" => "left", "occurrence" => 0}},
      "itemsById" => %{"field" => %{"aboveIndex" => "a", "belowIndex" => nil}}
    }

    assert {:ok, %DocumentType{key: "service_agreement_v1"} = document_type} =
             ContractTypes.upsert_matching_book("service_agreement_v1", matching_book)

    assert document_type.default_matching_book == matching_book

    assert %DocumentType{default_matching_book: ^matching_book} =
             Repo.get_by(DocumentType, key: "service_agreement_v1")

    assert {:ok, ^matching_book} =
             ContractTypes.get_matching_book("service_agreement_v1")
  end

  test "known stale rows are reconciled from TOML without losing matching book" do
    matching_book = %{
      "indexesById" => %{"idx" => %{"raw" => "사용자", "positionIndex" => 0}},
      "itemsById" => %{"employer" => %{"aboveIndex" => "idx", "belowIndex" => nil}}
    }

    Repo.insert!(%DocumentType{
      key: "employment_v1",
      family: "other",
      name_en: "employment_v1",
      version: "legacy",
      source: "custom",
      default_matching_book: matching_book
    })

    assert {:ok, ^matching_book} = ContractTypes.get_matching_book("employment_v1")

    assert %DocumentType{} = row = Repo.get_by!(DocumentType, key: "employment_v1")
    assert row.family == "employment"
    assert row.name_en == "Employment Contract (Korean Labour Standards Act aligned)"
    assert row.name_ko == "근로계약서"
    assert row.source == "mte"
    assert row.template_hwp_path == "/assets/standard_contracts/employment_v1.hwp"
    assert row.default_matching_book == matching_book
  end
end
