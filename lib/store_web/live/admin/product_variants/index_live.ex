defmodule StoreWeb.Admin.ProductVariants.IndexLive do
  @moduledoc """
  Dedicated admin CRUD surface for product options, values, variants, and selections.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Catalog.Facade, as: CatalogFacade

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:product, nil)
       |> assign(:options, [])
       |> assign(:variants, [])
       |> assign(:selections, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(%{"id" => product_id}, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, product} <- CatalogFacade.get_product_for_admin(actor, product_id),
         {:ok, options} <- CatalogFacade.list_product_options_for_admin(actor, product_id),
         {:ok, variants} <- CatalogFacade.list_variants_for_admin(actor, product_id),
         {:ok, selections} <- CatalogFacade.list_variant_selections_for_admin(actor, product_id) do
      {:noreply,
       socket
       |> assign(:product, product)
       |> assign(:options, options)
       |> assign(:variants, variants)
       |> assign(:selections, selections)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load product variants")
         |> push_navigate(to: ~p"/admin/products")}
    end
  end

  @impl true
  def handle_event("create_option", %{"option" => option_params}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id

    attrs = %{
      name: Map.get(option_params, "name"),
      slug: Map.get(option_params, "slug"),
      position: parse_non_negative_int(Map.get(option_params, "position"), 0),
      selection_required: truthy?(Map.get(option_params, "selection_required"))
    }

    case CatalogFacade.create_product_option_for_admin(actor, product_id, attrs) do
      {:ok, _option} ->
        {:noreply,
         socket
         |> put_flash(:info, "Option created")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to create option")}
    end
  end

  def handle_event("create_value", %{"value" => value_params}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id
    option_id = Map.get(value_params, "product_option_id")

    attrs = %{
      name: Map.get(value_params, "name"),
      slug: Map.get(value_params, "slug"),
      position: parse_non_negative_int(Map.get(value_params, "position"), 0)
    }

    case CatalogFacade.create_product_option_value_for_admin(actor, option_id, attrs) do
      {:ok, _value} ->
        {:noreply,
         socket
         |> put_flash(:info, "Option value created")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to create option value")}
    end
  end

  def handle_event("create_variant", %{"variant" => variant_params}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id

    attrs = %{
      sku: Map.get(variant_params, "sku"),
      title: blank_to_nil(Map.get(variant_params, "title")),
      currency_code: Map.get(variant_params, "currency_code"),
      price_minor: parse_non_negative_int(Map.get(variant_params, "price_minor"), 0),
      compare_at_price_minor:
        parse_optional_non_negative_int(Map.get(variant_params, "compare_at_price_minor")),
      weight_grams: parse_non_negative_int(Map.get(variant_params, "weight_grams"), 0),
      is_default: truthy?(Map.get(variant_params, "is_default")),
      status: parse_variant_status(Map.get(variant_params, "status")),
      image_id: blank_to_nil(Map.get(variant_params, "image_id"))
    }

    case CatalogFacade.create_variant_for_admin(actor, product_id, attrs) do
      {:ok, _variant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Variant created")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Unable to create variant. Active variants must include required option selections."
         )}
    end
  end

  def handle_event("archive_variant", %{"id" => variant_id}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id

    case CatalogFacade.archive_variant_for_admin(actor, variant_id) do
      {:ok, _variant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Variant archived")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to archive variant")}
    end
  end

  def handle_event("set_selection", %{"selection" => selection_params}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id

    variant_id = Map.get(selection_params, "variant_id")
    option_id = Map.get(selection_params, "product_option_id")
    value_id = Map.get(selection_params, "product_option_value_id")

    case CatalogFacade.set_variant_selection_for_admin(actor, variant_id, option_id, value_id) do
      {:ok, _selection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Selection saved")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to save selection")}
    end
  end

  def handle_event("delete_selection", %{"id" => selection_id}, socket) do
    actor = socket.assigns.current_user
    product_id = socket.assigns.product.id

    case CatalogFacade.delete_variant_selection_for_admin(actor, selection_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Selection removed")
         |> push_patch(to: ~p"/admin/products/#{product_id}/variants")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to remove selection")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section :if={@product} id="admin-product-variants" class="space-y-6">
        <header class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Variant Management</h1>
            <p class="text-sm text-base-content/70">{@product.title}</p>
          </div>
          <.link navigate={~p"/admin/products"} class="btn btn-soft btn-sm">Back to Products</.link>
        </header>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
          <h2 class="text-lg font-semibold">Options</h2>

          <.table
            id="product-options"
            rows={@options}
            row_id={fn row -> row.option.id end}
            row_item={fn row -> row end}
          >
            <:col :let={row} label="Name">{row.option.name}</:col>
            <:col :let={row} label="Slug">{row.option.slug}</:col>
            <:col :let={row} label="Required">
              {if row.option.selection_required, do: "Yes", else: "No"}
            </:col>
            <:col :let={row} label="Values">
              <span
                :for={value <- row.values}
                class="mr-2 inline-flex rounded border px-2 py-1 text-xs"
              >
                {value.name} ({value.slug})
              </span>
            </:col>
          </.table>

          <div class="grid gap-4 lg:grid-cols-2">
            <.form id="create-option-form" for={%{}} as={:option} phx-submit="create_option">
              <.input name="option[name]" type="text" label="Name" />
              <.input name="option[slug]" type="text" label="Slug" />
              <.input name="option[position]" type="number" value="0" label="Position" />
              <.input
                name="option[selection_required]"
                type="checkbox"
                value="true"
                checked
                label="Required"
              />
              <.button type="submit">Create Option</.button>
            </.form>

            <.form id="create-option-value-form" for={%{}} as={:value} phx-submit="create_value">
              <.input
                name="value[product_option_id]"
                type="select"
                label="Option"
                options={option_choices(@options)}
                prompt="Select option"
              />
              <.input name="value[name]" type="text" label="Name" />
              <.input name="value[slug]" type="text" label="Slug" />
              <.input name="value[position]" type="number" value="0" label="Position" />
              <.button type="submit">Create Value</.button>
            </.form>
          </div>
        </section>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
          <h2 class="text-lg font-semibold">Variants</h2>

          <.table
            id="variants"
            rows={@variants}
            row_id={fn variant -> variant.id end}
            row_item={fn variant -> variant end}
          >
            <:col :let={variant} label="SKU">{variant.sku}</:col>
            <:col :let={variant} label="Title">{variant.title || "-"}</:col>
            <:col :let={variant} label="Status">{variant.status}</:col>
            <:col :let={variant} label="Price">{variant.price_minor}</:col>
            <:col :let={variant} label="Signature">
              <span :if={is_binary(variant.selection_signature)}>
                {Base.encode16(variant.selection_signature, case: :lower)}
              </span>
              <span :if={!is_binary(variant.selection_signature)}>-</span>
            </:col>
            <:action :let={variant}>
              <.button
                :if={variant.status != :archived}
                id={"archive-#{variant.id}"}
                phx-click="archive_variant"
                phx-value-id={variant.id}
                class="btn btn-xs"
              >
                Archive
              </.button>
            </:action>
          </.table>

          <.form id="create-variant-form" for={%{}} as={:variant} phx-submit="create_variant">
            <.input name="variant[sku]" type="text" label="SKU" />
            <.input name="variant[title]" type="text" label="Title" />
            <.input name="variant[currency_code]" type="text" value="USD" label="Currency" />
            <.input name="variant[price_minor]" type="number" value="0" label="Price (minor)" />
            <.input
              name="variant[compare_at_price_minor]"
              type="number"
              label="Compare At (minor)"
            />
            <.input name="variant[weight_grams]" type="number" value="0" label="Weight (grams)" />
            <.input name="variant[image_id]" type="text" label="Image ID" />
            <.input
              name="variant[status]"
              type="select"
              label="Status"
              options={[{"Archived", "archived"}, {"Active", "active"}]}
            />
            <.input name="variant[is_default]" type="checkbox" label="Default" />
            <.button type="submit">Create Variant</.button>
          </.form>
        </section>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
          <h2 class="text-lg font-semibold">Variant Selections</h2>

          <.table
            id="variant-selections"
            rows={@selections}
            row_id={fn selection -> selection.id end}
            row_item={fn selection -> selection end}
          >
            <:col :let={selection} label="Variant ID">{selection.variant_id}</:col>
            <:col :let={selection} label="Option ID">{selection.product_option_id}</:col>
            <:col :let={selection} label="Value ID">{selection.product_option_value_id}</:col>
            <:action :let={selection}>
              <.button
                id={"delete-selection-#{selection.id}"}
                phx-click="delete_selection"
                phx-value-id={selection.id}
                class="btn btn-xs"
              >
                Delete
              </.button>
            </:action>
          </.table>

          <.form id="set-selection-form" for={%{}} as={:selection} phx-submit="set_selection">
            <.input
              name="selection[variant_id]"
              type="select"
              label="Variant"
              options={Enum.map(@variants, &{&1.sku, &1.id})}
              prompt="Select variant"
            />
            <.input
              name="selection[product_option_id]"
              type="select"
              label="Option"
              options={option_choices(@options)}
              prompt="Select option"
            />
            <.input name="selection[product_option_value_id]" type="text" label="Value ID" />
            <.button type="submit">Save Selection</.button>
          </.form>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp option_choices(options) do
    Enum.map(options, fn row ->
      {row.option.name, row.option.id}
    end)
  end

  defp parse_non_negative_int(nil, default), do: default
  defp parse_non_negative_int("", default), do: default

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_non_negative_int(_value, default), do: default

  defp parse_optional_non_negative_int(nil), do: nil
  defp parse_optional_non_negative_int(""), do: nil
  defp parse_optional_non_negative_int(value), do: parse_non_negative_int(value, 0)

  defp parse_variant_status("active"), do: :active
  defp parse_variant_status(:active), do: :active
  defp parse_variant_status(_), do: :archived

  defp truthy?(value) when value in [true, "true", "on", 1, "1"], do: true
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
