defmodule Store.Catalog.Variant do
  @moduledoc """
  Sellable variant identity used for inventory and checkout normalization.
  """

  import Ash.Expr
  import Ecto.Query

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  alias Store.Catalog.{ProductImage, ProductOption, VariantOptionSelection, VariantSignature}
  alias Store.Repo

  attributes do
    uuid_v7_primary_key(:id)

    attribute :is_default, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :sku, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :title, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :currency_code, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :price_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :compare_at_price_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :weight_grams, :integer do
      allow_nil?(false)
      constraints(min: 0)
      default(0)
      public?(true)
    end

    attribute :image_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :selection_signature, :binary do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, Store.Catalog.Types.VariantStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :product, Store.Catalog.Product do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :image, Store.Catalog.ProductImage do
      source_attribute(:image_id)
      destination_attribute(:id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    has_many :option_selections, Store.Catalog.VariantOptionSelection do
      destination_attribute(:variant_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_sku, [:sku])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_public do
      filter(expr(status == :active))
    end

    read(:read_for_admin)

    create :create do
      accept([
        :product_id,
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :weight_grams,
        :image_id,
        :status
      ])

      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
      validate(&validate_image_belongs_to_product/2)
      validate(&validate_active_required_completeness/2)
      validate(&validate_active_signature_uniqueness/2)
      change(&sync_signature_after_action/2)
    end

    create :create_for_product do
      accept([
        :product_id,
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :weight_grams,
        :image_id,
        :status
      ])

      argument(:forced_id, :uuid, allow_nil?: false, public?: false)

      change(&force_id_from_argument/2)
      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
      validate(&validate_image_belongs_to_product/2)
      validate(&validate_active_required_completeness/2)
      validate(&validate_active_signature_uniqueness/2)
      change(&sync_signature_after_action/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :weight_grams,
        :image_id,
        :status
      ])

      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
      validate(&validate_image_belongs_to_product/2)
      validate(&validate_active_required_completeness/2)
      validate(&validate_active_signature_uniqueness/2)
      change(&sync_signature_after_action/2)
    end

    update :archive do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :archived))
      change(&sync_signature_after_action/2)
    end
  end

  postgres do
    table("variants")
    repo(Store.Repo)

    custom_indexes do
      index([:product_id], name: "variants_product_id_index")
      index([:is_default], name: "variants_is_default_index")
      index([:image_id], name: "variants_image_id_index")
    end
  end

  policies do
    policy action(:read_for_public) do
      authorize_if(always())
    end

    policy action([:read, :read_for_admin]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:archive) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:sku, &String.upcase/1)
    |> normalize_attr(:currency_code, &String.upcase/1)
    |> normalize_title()
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized = value |> String.trim() |> transform.()
        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _ ->
        changeset
    end
  end

  defp normalize_title(changeset) do
    case Ash.Changeset.get_attribute(changeset, :title) do
      value when is_binary(value) ->
        value = String.trim(value)
        Ash.Changeset.change_attribute(changeset, :title, empty_to_nil(value))

      _ ->
        changeset
    end
  end

  defp validate_compare_at(changeset, _context) do
    price_minor = Ash.Changeset.get_attribute(changeset, :price_minor)
    compare_minor = Ash.Changeset.get_attribute(changeset, :compare_at_price_minor)

    if is_integer(compare_minor) and is_integer(price_minor) and compare_minor < price_minor do
      {:error, field: :compare_at_price_minor, message: "must be greater than or equal to price"}
    else
      :ok
    end
  end

  defp validate_image_belongs_to_product(changeset, _context) do
    image_id = Ash.Changeset.get_attribute(changeset, :image_id)
    product_id = Ash.Changeset.get_attribute(changeset, :product_id) || changeset.data.product_id

    cond do
      is_nil(image_id) ->
        :ok

      not is_binary(product_id) ->
        {:error, field: :product_id, message: "product_id is required"}

      true ->
        case Repo.get(ProductImage, image_id) do
          %ProductImage{product_id: ^product_id} ->
            :ok

          %ProductImage{} ->
            {:error, field: :image_id, message: "image must belong to the same product"}

          nil ->
            {:error, field: :image_id, message: "image must exist"}
        end
    end
  end

  defp validate_active_required_completeness(changeset, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status

    if status != :active do
      :ok
    else
      product_id =
        Ash.Changeset.get_attribute(changeset, :product_id) || changeset.data.product_id

      variant_id = changeset.data.id

      product_id
      |> required_option_ids_for_product()
      |> validate_required_selections_for_active_variant(variant_id)
    end
  end

  defp validate_active_signature_uniqueness(changeset, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status

    if status != :active do
      :ok
    else
      product_id =
        Ash.Changeset.get_attribute(changeset, :product_id) || changeset.data.product_id

      variant_id = changeset.data.id
      signature = selection_signature_for_validation(product_id, variant_id)

      if is_binary(signature) and active_signature_conflict?(product_id, variant_id, signature) do
        {:error,
         field: :status, message: "active variant option combination must be unique per product"}
      else
        :ok
      end
    end
  end

  defp selection_signature_for_validation(product_id, variant_id) do
    options = VariantSignature.ordered_options_for_product(product_id)

    selections =
      if is_binary(variant_id) do
        VariantOptionSelection
        |> where([selection], selection.variant_id == ^variant_id)
        |> Repo.all()
      else
        []
      end

    case VariantSignature.build_signature(options, selections) do
      {:ok, signature} -> signature
      {:incomplete_required, _missing} -> nil
    end
  end

  defp active_signature_conflict?(product_id, variant_id, signature) do
    query =
      __MODULE__
      |> where([variant], variant.product_id == ^product_id and variant.status == :active)
      |> where([variant], variant.selection_signature == ^signature)

    query =
      if is_binary(variant_id) do
        where(query, [variant], variant.id != ^variant_id)
      else
        query
      end

    Repo.exists?(query)
  end

  defp force_id_from_argument(changeset, _context) do
    case Ash.Changeset.get_argument(changeset, :forced_id) do
      nil -> changeset
      id -> Ash.Changeset.force_change_attribute(changeset, :id, id)
    end
  end

  defp sync_signature_after_action(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, variant ->
      case VariantSignature.sync_variant_signature(variant.id) do
        :ok -> {:ok, variant}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp required_option_ids_for_product(product_id) do
    ProductOption
    |> where([option], option.product_id == ^product_id and option.selection_required == true)
    |> select([option], option.id)
    |> Repo.all()
  end

  defp validate_required_selections_for_active_variant([], _variant_id), do: :ok

  defp validate_required_selections_for_active_variant(_required_option_ids, nil) do
    {:error,
     field: :status,
     message:
       "active variant requires required option selections before activation; create archived first"}
  end

  defp validate_required_selections_for_active_variant(required_option_ids, variant_id) do
    selected_required_count =
      VariantOptionSelection
      |> where([selection], selection.variant_id == ^variant_id)
      |> where([selection], selection.product_option_id in ^required_option_ids)
      |> select([selection], count(fragment("DISTINCT ?", selection.product_option_id)))
      |> Repo.one() || 0

    if selected_required_count == length(required_option_ids) do
      :ok
    else
      {:error,
       field: :status,
       message: "active variant must include exactly one selection for each required option"}
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
