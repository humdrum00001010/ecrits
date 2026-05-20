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
end
