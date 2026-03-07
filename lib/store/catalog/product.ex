defmodule Store.Catalog.Product do
  @moduledoc """
  Catalog product record with strict publish lifecycle and default variant linkage.
  """

  import Ash.Expr
  require Ash.Query

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  alias Store.Catalog.{InventoryItem, Variant}
  alias Store.Support.ID.UUIDv7

  attributes do
    uuid_v7_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      constraints(min_length: 1, match: ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
      public?(true)
    end

    attribute :title, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :subtitle, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, Store.Catalog.Types.ProductStatus do
      allow_nil?(false)
      default(:draft)
      public?(true)
    end

    attribute :product_kind, Store.Catalog.Types.ProductKind do
      allow_nil?(false)
      default(:simple)
      public?(true)
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :archived_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :default_variant_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :category, Store.Catalog.Category do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :default_variant, Store.Catalog.Variant do
      allow_nil?(false)
      source_attribute(:default_variant_id)
      destination_attribute(:id)
      attribute_writable?(true)
      public?(true)
    end

    has_many :variants, Store.Catalog.Variant do
      destination_attribute(:product_id)
      public?(true)
    end

    has_many :options, Store.Catalog.ProductOption do
      destination_attribute(:product_id)
      public?(true)
    end

    has_many :images, Store.Catalog.ProductImage do
      destination_attribute(:product_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_public do
      prepare(fn query, _context ->
        query
        |> Ash.Query.filter(expr(status == :published and not is_nil(published_at)))
        |> Ash.Query.sort(inserted_at: :desc, id: :asc)
      end)
    end

    read :get_for_public do
      get?(true)

      argument :slug, :string do
        allow_nil?(false)
      end

      filter(expr(status == :published and not is_nil(published_at) and slug == ^arg(:slug)))
    end

    read :read_for_admin do
      prepare(fn query, _context ->
        Ash.Query.sort(query, inserted_at: :desc, id: :asc)
      end)
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :create_draft do
      accept([:slug, :title, :subtitle, :description, :category_id, :product_kind])

      argument :base_variant_sku, :string do
        allow_nil?(false)
      end

      argument :base_variant_title, :string do
        allow_nil?(true)
      end

      argument :base_variant_currency_code, :string do
        allow_nil?(false)
      end

      argument :base_variant_price_minor, :integer do
        allow_nil?(false)
        constraints(min: 0)
      end

      argument :base_variant_compare_at_price_minor, :integer do
        allow_nil?(true)
        constraints(min: 0)
      end

      argument :base_variant_stock_on_hand, :integer do
        allow_nil?(false)
        default(0)
        constraints(min: 0)
      end

      argument :base_variant_allow_oversell, :boolean do
        allow_nil?(false)
        default(false)
      end

      change(set_attribute(:status, :draft))
      change(set_attribute(:published_at, nil))
      change(&normalize_fields/2)
      change(&prepare_default_variant_id/2)
      change(&attach_base_variant_after_action/2)
    end

    update :update_draft do
      require_atomic?(false)
      accept([:slug, :title, :subtitle, :description, :category_id, :product_kind])
      validate(fn changeset, _context -> require_current_state(changeset, [:draft]) end)
      change(&normalize_fields/2)
    end

    update :publish do
      require_atomic?(false)
      accept([])
      validate(fn changeset, _context -> require_current_state(changeset, [:draft]) end)
      change(&apply_publish_transition/2)
    end

    update :unpublish do
      require_atomic?(false)
      accept([])
      validate(fn changeset, _context -> require_current_state(changeset, [:published]) end)
      change(&apply_unpublish_transition/2)
    end

    update :archive do
      require_atomic?(false)
      accept([])

      validate(fn changeset, _context ->
        require_current_state(changeset, [:draft, :published])
      end)

      change(&apply_archive_transition/2)
    end
  end

  code_interface do
    define(:list_for_public, action: :read_for_public)
    define(:get_for_public, action: :get_for_public, args: [:slug])
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
  end

  postgres do
    table("products")
    repo(Store.Repo)

    custom_indexes do
      index([:status], name: "products_status_index")
      index([:category_id], name: "products_category_id_index")
      index([:published_at], name: "products_published_at_index")
      index([:product_kind], name: "products_product_kind_index")
    end
  end

  policies do
    policy action([:read_for_public, :get_for_public]) do
      authorize_if(always())
    end

    policy action([:read, :read_for_admin, :get_for_admin]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:slug, &String.downcase/1)
    |> normalize_attr(:title, & &1)
    |> normalize_attr(:subtitle, & &1)
    |> normalize_attr(:description, & &1)
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> transform.()
          |> empty_to_nil()

        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _ ->
        changeset
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp prepare_default_variant_id(changeset, _context) do
    default_variant_id = UUIDv7.generate()
    Ash.Changeset.change_attribute(changeset, :default_variant_id, default_variant_id)
  end

  defp attach_base_variant_after_action(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn updated_changeset, product ->
      create_base_variant_and_inventory(updated_changeset, product)
    end)
  end

  defp create_base_variant_and_inventory(changeset, product) do
    base_variant_id = product.default_variant_id

    variant_attrs = %{
      product_id: product.id,
      is_default: true,
      sku: Ash.Changeset.get_argument(changeset, :base_variant_sku),
      title: Ash.Changeset.get_argument(changeset, :base_variant_title),
      currency_code: Ash.Changeset.get_argument(changeset, :base_variant_currency_code),
      price_minor: Ash.Changeset.get_argument(changeset, :base_variant_price_minor),
      compare_at_price_minor:
        Ash.Changeset.get_argument(changeset, :base_variant_compare_at_price_minor),
      status: :active
    }

    inventory_attrs = %{
      variant_id: base_variant_id,
      stock_on_hand: Ash.Changeset.get_argument(changeset, :base_variant_stock_on_hand),
      reserved_count: 0,
      allow_oversell: Ash.Changeset.get_argument(changeset, :base_variant_allow_oversell)
    }

    variant_changeset =
      Variant
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:forced_id, base_variant_id)
      |> Ash.Changeset.for_create(:create_for_product, variant_attrs, context: %{system?: true})

    with {:ok, variant} <-
           Ash.create(variant_changeset,
             domain: Store.Catalog,
             context: %{system?: true},
             authorize?: false
           ),
         :ok <- validate_default_variant_product(product, variant),
         {:ok, _inventory_item} <-
           InventoryItem
           |> Ash.Changeset.for_create(:create, inventory_attrs, context: %{system?: true})
           |> Ash.create(domain: Store.Catalog, context: %{system?: true}, authorize?: false) do
      {:ok, product}
    end
  end

  defp validate_default_variant_product(product, variant) do
    if variant.product_id == product.id and variant.id == product.default_variant_id do
      :ok
    else
      {:error, "default_variant_id must reference a variant that belongs to the same product"}
    end
  end

  defp require_current_state(changeset, allowed_states) do
    if changeset.data.status in allowed_states do
      :ok
    else
      {:error, field: :status, message: "invalid transition from #{changeset.data.status}"}
    end
  end

  defp apply_publish_transition(changeset, _context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset
    |> Ash.Changeset.change_attribute(:status, :published)
    |> Ash.Changeset.change_attribute(:published_at, now)
    |> Ash.Changeset.change_attribute(:archived_at, nil)
  end

  defp apply_unpublish_transition(changeset, _context) do
    changeset
    |> Ash.Changeset.change_attribute(:status, :draft)
    |> Ash.Changeset.change_attribute(:published_at, nil)
  end

  defp apply_archive_transition(changeset, _context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset
    |> Ash.Changeset.change_attribute(:status, :archived)
    |> Ash.Changeset.change_attribute(:archived_at, now)
  end
end
