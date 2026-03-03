defmodule Store.Catalog.VariantOptionSelection do
  @moduledoc """
  Variant-to-option-value assignments used for deterministic resolution.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  alias Store.Catalog.{ProductOption, ProductOptionValue, Variant, VariantSignature}
  alias Store.Repo

  attributes do
    uuid_v7_primary_key(:id)

    attribute :product_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :product, Store.Catalog.Product do
      allow_nil?(false)
      attribute_writable?(false)
      public?(true)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :product_option, Store.Catalog.ProductOption do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :product_option_value, Store.Catalog.ProductOptionValue do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_variant_option, [:variant_id, :product_option_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_variant do
      argument(:variant_id, :uuid, allow_nil?: false)
      filter(expr(variant_id == ^arg(:variant_id)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :create do
      accept([:variant_id, :product_option_id, :product_option_value_id])
      change(&hydrate_product_id/2)
      validate(&validate_integrity/2)
      change(&sync_variant_signature_after_action/2)
    end

    update :update do
      require_atomic?(false)
      accept([:product_option_value_id])
      validate(&validate_integrity/2)
      change(&sync_variant_signature_after_action/2)
    end

    destroy :destroy do
      require_atomic?(false)
      change(&sync_variant_signature_after_action/2)
    end
  end

  postgres do
    table("variant_option_selections")
    repo(Store.Repo)

    custom_indexes do
      index([:product_option_value_id], name: "variant_option_selections_value_id_index")
      index([:product_id, :variant_id], name: "variant_option_selections_product_variant_index")

      index([:product_id, :product_option_id],
        name: "variant_option_selections_product_option_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp hydrate_product_id(changeset, _context) do
    variant_id = get_attr_or_data(changeset, :variant_id)

    case Repo.get(Variant, variant_id) do
      %Variant{product_id: product_id} ->
        Ash.Changeset.change_attribute(changeset, :product_id, product_id)

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :variant_id,
          message: "variant must exist"
        )
    end
  end

  defp validate_integrity(changeset, _context) do
    variant_id = get_attr_or_data(changeset, :variant_id)
    product_option_id = get_attr_or_data(changeset, :product_option_id)
    product_option_value_id = get_attr_or_data(changeset, :product_option_value_id)

    with %Variant{} = variant <- Repo.get(Variant, variant_id),
         %ProductOption{} = option <- Repo.get(ProductOption, product_option_id),
         %ProductOptionValue{} = value <- Repo.get(ProductOptionValue, product_option_value_id),
         :ok <- validate_value_option(value, option),
         :ok <- validate_variant_option_product(variant, option) do
      :ok
    else
      nil ->
        {:error,
         field: :variant_id,
         message: "variant, option, and option value must exist and belong to the same product"}

      {:error, reason} ->
        reason
    end
  end

  defp validate_value_option(%ProductOptionValue{} = value, %ProductOption{} = option) do
    if value.product_option_id == option.id do
      :ok
    else
      {:error,
       field: :product_option_value_id, message: "option value must belong to selected option"}
    end
  end

  defp validate_variant_option_product(%Variant{} = variant, %ProductOption{} = option) do
    if variant.product_id == option.product_id do
      :ok
    else
      {:error, field: :variant_id, message: "variant and option must belong to the same product"}
    end
  end

  defp sync_variant_signature_after_action(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, selection ->
      case VariantSignature.sync_variant_signature(selection.variant_id) do
        :ok -> {:ok, selection}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp get_attr_or_data(changeset, attr) do
    Ash.Changeset.get_attribute(changeset, attr) || Map.get(changeset.data, attr)
  end
end
