defmodule StoreWeb.ShopLive.Show do
  @moduledoc """
  Public storefront product detail by slug.
  """

  use StoreWeb, :live_view

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Catalog.Facade, as: CatalogFacade
  alias Store.Catalog.ProductDetailTelemetry
  alias Store.Support.Telemetry.RepoStats
  alias StoreWeb.Live.EntitlementAware
  alias StoreWeb.Params.Carts.CartItemParams
  alias StoreWeb.Params.Catalog.ProductDetailParams

  @impl true
  def mount(_params, session, socket) do
    cart_token = Map.get(session, "cart_token")

    {:ok,
     socket
     |> EntitlementAware.maybe_subscribe()
     |> EntitlementAware.assign_entitlement_set()
     |> assign(:detail, nil)
     |> assign(:cart_token, cart_token)
     |> assign(:selector_form, to_form(%{}, as: :selection))
     |> assign(:plan_form, to_form(%{}, as: :subscription_plan))
     |> assign(:quantity_form, to_form(%{"quantity" => "1"}, as: :cart_line))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns[:current_user]
    started_at = System.monotonic_time()
    before_snapshot = ProductDetailTelemetry.process_snapshot()
    phase = if connected?(socket), do: :live_join, else: :static_render
    slug = normalize_slug(Map.get(params, "slug") || Map.get(params, :slug))
    selection_count = selection_count(params)

    attrs = %{
      slug: slug,
      selection_count: selection_count,
      phase: phase,
      connected?: connected?(socket)
    }

    {{socket, result}, repo_stats} =
      RepoStats.capture(fn -> load_detail(socket, actor, params) end)

    ProductDetailTelemetry.emit_shop_live(
      started_at,
      attrs,
      result,
      repo_stats,
      before_snapshot,
      ProductDetailTelemetry.process_snapshot()
    )

    {:noreply, socket}
  end

  defp load_detail(socket, actor, params) do
    case ProductDetailParams.query(params) do
      {:ok, query} -> load_detail_from_query(socket, actor, query)
      {:error, reason} -> {not_found_socket(socket), {:error, reason}}
    end
  end

  defp load_detail_from_query(socket, actor, query) do
    case CatalogFacade.get_product_detail_for_public(actor, query) do
      {:ok, detail} ->
        {
          socket
          |> assign(:detail, detail)
          |> assign(:selector_form, selector_form(detail))
          |> assign(:plan_form, plan_form(detail)),
          {:ok, detail}
        }

      {:error, reason} ->
        {not_found_socket(socket), {:error, reason}}
    end
  end

  @impl true
  def handle_event("select_options", %{"selection" => selection}, socket) do
    slug = socket.assigns.detail.product.slug

    query =
      selection
      |> Enum.reduce(%{}, fn {option_slug, value_slug}, acc ->
        value_slug = to_string(value_slug || "") |> String.trim()

        if value_slug == "" do
          acc
        else
          Map.put(acc, option_slug, value_slug)
        end
      end)

    path =
      query =
      maybe_put_selected_plan_key(query, socket.assigns.detail)

    if map_size(query) == 0 do
      "/shop/#{slug}"
    else
      "/shop/#{slug}?" <> URI.encode_query(query)
    end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("select_subscription_plan", %{"subscription_plan" => params}, socket) do
    slug = socket.assigns.detail.product.slug

    query =
      current_selection_query(socket.assigns.detail)
      |> maybe_put_subscription_plan_key(Map.get(params, "subscription_plan_key"))

    path =
      if map_size(query) == 0 do
        "/shop/#{slug}"
      else
        "/shop/#{slug}?" <> URI.encode_query(query)
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("queue_cart_line", %{"cart_line" => %{"quantity" => quantity}}, socket) do
    actor = socket.assigns[:current_user]
    {:noreply, queue_cart_line(socket, actor, quantity)}
  end

  @impl true
  def handle_info(message, socket) do
    case EntitlementAware.handle_invalidation(socket, message) do
      {:handled, socket} -> {:noreply, socket}
      :ignored -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section :if={@detail} id="shop-show" class="space-y-6">
        <header class="space-y-2">
          <p class="text-xs uppercase tracking-wide text-base-content/60">{@detail.product.slug}</p>
          <h1 class="text-2xl font-semibold">{@detail.product.title}</h1>
          <p :if={@detail.product.subtitle} class="text-sm text-base-content/70">
            {@detail.product.subtitle}
          </p>
        </header>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="space-y-3">
            <div
              :for={image <- display_images(@detail)}
              class="rounded-xl border border-base-300 bg-base-200/50 p-3"
            >
              <img
                src={image.url}
                alt={image.alt || @detail.product.title}
                class="h-56 w-full rounded-lg object-cover"
              />
            </div>

            <div
              :if={display_images(@detail) == []}
              class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
            >
              No product images available.
            </div>
          </div>

          <div class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-5">
            <p class="text-sm font-semibold">{format_money(current_price_minor(@detail))}</p>

            <p :if={@detail.product.description} class="text-sm leading-6 text-base-content/80">
              {@detail.product.description}
            </p>

            <.form
              :if={@detail.options != []}
              for={@selector_form}
              id="variant-selector-form"
              phx-change="select_options"
            >
              <div class="space-y-3">
                <div :for={option <- @detail.options}>
                  <.input
                    field={@selector_form[option.slug]}
                    type="select"
                    label={option.name}
                    prompt={prompt_for_option(option)}
                    options={Enum.map(option.values, &{&1.name, &1.slug})}
                  />
                </div>
              </div>
            </.form>

            <p :if={resolution_message(@detail)} class="text-sm text-error">
              {resolution_message(@detail)}
            </p>

            <.form
              :if={show_subscription_plan_picker?(@detail)}
              for={@plan_form}
              id="subscription-plan-form"
              phx-change="select_subscription_plan"
            >
              <div class="space-y-2 rounded-lg border border-base-300 bg-base-100 p-3">
                <.input
                  field={@plan_form[:subscription_plan_key]}
                  type="select"
                  label="Plan"
                  prompt={subscription_plan_prompt(@detail)}
                  options={
                    Enum.map(@detail.subscription_plan_options, &{plan_option_label(&1), &1.key})
                  }
                />
              </div>
            </.form>

            <.form for={@quantity_form} id="cart-line-form" phx-submit="queue_cart_line">
              <.input field={@quantity_form[:quantity]} type="number" min="1" label="Quantity" />
              <.button
                id="add-to-cart-handoff"
                type="submit"
                class="mt-3"
                disabled={!add_to_cart_enabled?(@detail)}
              >
                Add to Cart
              </.button>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp selector_form(detail) do
    selected_by_option_slug =
      Enum.reduce(detail.options, %{}, fn option, acc ->
        selected_value_id = Map.get(detail.selected, option.id)
        selected_slug = selected_value_slug(option.values, selected_value_id)

        Map.put(acc, option.slug, selected_slug)
      end)

    to_form(selected_by_option_slug, as: :selection)
  end

  defp plan_form(detail) do
    to_form(
      %{"subscription_plan_key" => detail.selected_subscription_plan_key || ""},
      as: :subscription_plan
    )
  end

  defp queue_cart_line(socket, actor, quantity) do
    case resolved_variant_id(socket.assigns.detail) do
      nil ->
        put_flash(socket, :error, "Please choose a valid in-stock variant first")

      variant_id ->
        queue_cart_line_for_variant(socket, actor, variant_id, quantity)
    end
  end

  defp queue_cart_line_for_variant(socket, actor, variant_id, quantity) do
    params =
      %{
        "variant_id" => variant_id,
        "qty" => quantity
      }
      |> maybe_put_subscription_plan_id(socket.assigns.detail)

    case CartItemParams.input(params) do
      {:ok, input} -> add_cart_line_to_cart(socket, actor, input)
      {:error, _error} -> put_flash(socket, :error, "Invalid cart line input")
    end
  end

  defp add_cart_line_to_cart(socket, actor, input) do
    case CartsFacade.add_item_for_user(actor, socket.assigns.cart_token, input) do
      {:ok, _cart} ->
        socket
        |> put_flash(:info, "Added to cart")
        |> push_navigate(to: ~p"/cart")

      {:error, _error} ->
        put_flash(socket, :error, "Unable to add item to cart")
    end
  end

  defp selected_value_slug(values, selected_value_id) do
    case Enum.find(values, &(&1.id == selected_value_id)) do
      nil -> ""
      value -> value.slug
    end
  end

  defp prompt_for_option(%{selection_required: true, name: name}), do: "Select #{name}"
  defp prompt_for_option(%{name: name}), do: "Any #{name}"

  defp subscription_plan_prompt(%{subscription_plan_required?: true}), do: "Select plan"
  defp subscription_plan_prompt(_detail), do: nil

  defp not_found_socket(socket) do
    socket
    |> put_flash(:error, "Product not found")
    |> push_navigate(to: ~p"/shop")
  end

  defp selection_count(params) when is_map(params) do
    Enum.count(params, fn {key, _value} ->
      to_string(key) not in ["slug", "subscription_plan_key"]
    end)
  end

  defp selection_count(_params), do: 0

  defp normalize_slug(slug) when is_binary(slug), do: slug
  defp normalize_slug(slug) when is_atom(slug), do: Atom.to_string(slug)
  defp normalize_slug(_slug), do: nil

  defp add_to_cart_enabled?(%{resolution: %{status: :ok}} = detail) do
    not subscription_plan_selection_missing?(detail)
  end

  defp add_to_cart_enabled?(_detail), do: false

  defp resolved_variant_id(%{resolution: %{status: :ok, variant_id: variant_id}}), do: variant_id
  defp resolved_variant_id(_detail), do: nil

  defp current_price_minor(%{selected_subscription_plan_id: selected_plan_id} = detail)
       when is_binary(selected_plan_id) do
    case Enum.find(detail.subscription_plan_options, &(&1.id == selected_plan_id)) do
      %{amount_minor: minor} when is_integer(minor) -> minor
      _ -> current_variant_price_minor(detail)
    end
  end

  defp current_price_minor(detail), do: current_variant_price_minor(detail)

  defp current_variant_price_minor(%{resolution: %{status: :ok, variant: variant}})
       when is_map(variant) and is_integer(variant.price_minor),
       do: variant.price_minor

  defp current_variant_price_minor(%{product: product}) do
    case product.default_variant do
      %{price_minor: minor} when is_integer(minor) -> minor
      _ -> nil
    end
  end

  defp resolution_message(%{resolution: %{status: :ok}}), do: nil

  defp resolution_message(%{resolution: %{reason: :invalid_selection}}),
    do: "Invalid option combination. Choose valid option values."

  defp resolution_message(%{resolution: %{reason: :selection_ambiguous}}),
    do: "Selection is ambiguous. Choose additional options to continue."

  defp resolution_message(%{resolution: %{reason: :out_of_stock}}),
    do: "Selected variant is out of stock."

  defp resolution_message(_detail), do: nil

  defp display_images(%{product: product} = detail) do
    sorted_images = Enum.sort_by(product.images || [], &{&1.position, &1.id})

    case detail do
      %{resolution: %{status: :ok, variant: %{image_id: image_id}}} when is_binary(image_id) ->
        case Enum.split_with(sorted_images, &(&1.id == image_id)) do
          {[selected_image], rest} -> [selected_image | rest]
          _ -> sorted_images
        end

      _ ->
        sorted_images
    end
  end

  defp format_money(nil), do: "Price unavailable"

  defp format_money(minor) when is_integer(minor),
    do: "$#{:erlang.float_to_binary(minor / 100, decimals: 2)}"

  defp show_subscription_plan_picker?(%{
         product: %{product_kind: :subscription},
         resolution: %{status: :ok},
         subscription_plan_options: [_ | _]
       }),
       do: true

  defp show_subscription_plan_picker?(_detail), do: false

  defp subscription_plan_selection_missing?(%{
         subscription_plan_required?: true,
         selected_subscription_plan_id: nil
       }),
       do: true

  defp subscription_plan_selection_missing?(_detail), do: false

  defp maybe_put_subscription_plan_id(params, %{selected_subscription_plan_id: plan_id})
       when is_binary(plan_id) do
    Map.put(params, "subscription_plan_id", plan_id)
  end

  defp maybe_put_subscription_plan_id(params, _detail), do: params

  defp current_selection_query(detail) do
    Enum.reduce(detail.options, %{}, fn option, acc ->
      case selected_value_slug(option.values, Map.get(detail.selected, option.id)) do
        "" -> acc
        value_slug -> Map.put(acc, option.slug, value_slug)
      end
    end)
  end

  defp maybe_put_selected_plan_key(query, %{selected_subscription_plan_key: plan_key})
       when is_binary(plan_key) do
    Map.put(query, "subscription_plan_key", plan_key)
  end

  defp maybe_put_selected_plan_key(query, _detail), do: query

  defp maybe_put_subscription_plan_key(query, plan_key) when is_binary(plan_key) do
    trimmed = String.trim(plan_key)

    if trimmed == "" do
      Map.delete(query, "subscription_plan_key")
    else
      Map.put(query, "subscription_plan_key", trimmed)
    end
  end

  defp maybe_put_subscription_plan_key(query, _plan_key),
    do: Map.delete(query, "subscription_plan_key")

  defp plan_option_label(plan_option) do
    "#{plan_option.name} (#{format_money(plan_option.price_minor)})"
  end
end
