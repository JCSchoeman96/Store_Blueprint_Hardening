defmodule StoreWeb.ToolsLive.RiskAppetite do
  @moduledoc """
  Risk Appetite Calculator — multi-step wizard LiveView.

  Step 1: Questionnaire — rate statements on a 1–5 scale with live scoring.
  Step 2: Contact details — name, email, phone, consent checkboxes.
  Step 3: Result — display category, score, and description.
  """

  use StoreWeb, :live_view

  alias Store.Tools.Facade, as: ToolsFacade
  alias Store.Tools.RiskAppetite
  alias StoreWeb.Layouts
  alias StoreWeb.Params.Tools.LeadSubmissionParams

  @impl true
  def mount(_params, _session, socket) do
    statements = RiskAppetite.statements()

    socket =
      socket
      |> assign(:step, :questionnaire)
      |> assign(:statements, statements)
      |> assign(:answers, %{})
      |> assign(:started?, false)
      |> assign(:live_score, 50)
      |> assign(:live_category, RiskAppetite.categorize(50))
      |> assign(:contact_form, initial_contact_form())
      |> assign(:contact_errors, %{})
      |> assign(:submission, nil)
      |> assign(:submitting?, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_answers", %{"answers" => answers_params}, socket) do
    answers = Map.merge(socket.assigns.answers, answers_params)
    score = RiskAppetite.calculate_score(answers)
    category = RiskAppetite.categorize(score)

    socket =
      socket
      |> assign(:answers, answers)
      |> assign(:started?, true)
      |> assign(:live_score, score)
      |> assign(:live_category, category)

    {:noreply, socket}
  end

  @impl true
  def handle_event("continue_to_contact", _params, socket) do
    if socket.assigns.started? do
      {:noreply, assign(socket, :step, :contact)}
    else
      {:noreply,
       put_flash(socket, :error, "Please adjust at least one slider before continuing.")}
    end
  end

  @impl true
  def handle_event("validate_contact", %{"contact" => params}, socket) do
    errors = validate_contact_fields(params)
    form = Map.merge(socket.assigns.contact_form, normalize_contact_params(params))
    {:noreply, socket |> assign(:contact_form, form) |> assign(:contact_errors, errors)}
  end

  @impl true
  def handle_event("submit_lead", %{"contact" => params}, socket) do
    if socket.assigns.submitting? do
      {:noreply, socket}
    else
      errors = validate_contact_fields(params)

      if errors == %{} do
        do_submit(socket, params)
      else
        form = Map.merge(socket.assigns.contact_form, normalize_contact_params(params))

        {:noreply,
         socket
         |> assign(:contact_form, form)
         |> assign(:contact_errors, errors)}
      end
    end
  end

  @impl true
  def handle_event("back_to_questionnaire", _params, socket) do
    {:noreply, assign(socket, :step, :questionnaire)}
  end

  @impl true
  def handle_event("retake", _params, socket) do
    socket =
      socket
      |> assign(:step, :questionnaire)
      |> assign(:answers, %{})
      |> assign(:started?, false)
      |> assign(:live_score, 50)
      |> assign(:live_category, RiskAppetite.categorize(50))
      |> assign(:contact_form, initial_contact_form())
      |> assign(:contact_errors, %{})
      |> assign(:submission, nil)
      |> assign(:submitting?, false)
      |> clear_flash()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <header class="space-y-2">
          <.link navigate={~p"/tools"} class="text-sm text-base-content/60 hover:text-primary">
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back to Tools
          </.link>
          <h1 class="text-3xl font-bold">Risk Appetite Calculator</h1>
          <p class="text-base text-base-content/70">
            Discover your investment risk profile in under 5 minutes.
          </p>
        </header>
        
    <!-- Step indicator -->
        <ul class="steps steps-horizontal w-full">
          <li class={["step", step_class(@step, :questionnaire)]}>Questionnaire</li>
          <li class={["step", step_class(@step, :contact)]}>Your Details</li>
          <li class={["step", step_class(@step, :result)]}>Your Result</li>
        </ul>
        
    <!-- Step 1: Questionnaire -->
        <div :if={@step == :questionnaire} class="space-y-6">
          <.live_score_bar score={@live_score} category={@live_category} answers={@answers} />

          <form id="questionnaire-form" phx-change="update_answers" class="space-y-4">
            <div
              :for={statement <- @statements}
              class="rounded-xl border border-base-300 bg-base-200/50 p-5"
            >
              <p class="text-sm font-medium">{statement.text}</p>
              <div class="mt-3 flex items-center gap-3">
                <span class="text-xs text-base-content/50 w-28 shrink-0">Strongly Disagree</span>
                <input
                  type="range"
                  min="1"
                  max="5"
                  step="1"
                  name={"answers[#{statement.id}]"}
                  value={Map.get(@answers, statement.id, "3")}
                  class="range range-primary range-sm flex-1"
                  id={"slider-#{statement.id}"}
                />
                <span class="text-xs text-base-content/50 w-24 shrink-0 text-right">
                  Strongly Agree
                </span>
              </div>
              <div class="mt-1 flex justify-between px-28">
                <span :for={n <- 1..5} class="text-xs text-base-content/40">{n}</span>
              </div>
            </div>
          </form>

          <div class="flex justify-end">
            <.button
              id="continue-btn"
              phx-click="continue_to_contact"
              disabled={not @started?}
              class="btn-primary"
            >
              Continue <.icon name="hero-arrow-right-mini" class="size-4" />
            </.button>
          </div>
        </div>
        
    <!-- Step 2: Contact Details -->
        <div :if={@step == :contact} class="space-y-6">
          <.live_score_bar score={@live_score} category={@live_category} answers={@answers} />

          <div class="rounded-xl border border-base-300 bg-base-200/50 p-6">
            <h2 class="text-lg font-semibold">Your Details</h2>
            <p class="mt-1 text-sm text-base-content/70">
              Enter your details below to receive your personalised risk profile.
            </p>

            <form phx-change="validate_contact" phx-submit="submit_lead" class="mt-6 space-y-4">
              <div>
                <label for="contact-name" class="label text-sm font-medium">
                  Name <span class="text-error">*</span>
                </label>
                <input
                  id="contact-name"
                  type="text"
                  name="contact[name]"
                  value={@contact_form["name"]}
                  class={["input input-bordered w-full", @contact_errors[:name] && "input-error"]}
                  placeholder="Your full name"
                  required
                />
                <p :if={@contact_errors[:name]} class="mt-1 text-xs text-error">
                  {@contact_errors[:name]}
                </p>
              </div>

              <div>
                <label for="contact-email" class="label text-sm font-medium">
                  Email <span class="text-error">*</span>
                </label>
                <input
                  id="contact-email"
                  type="email"
                  name="contact[email]"
                  value={@contact_form["email"]}
                  class={["input input-bordered w-full", @contact_errors[:email] && "input-error"]}
                  placeholder="you@example.com"
                  required
                />
                <p :if={@contact_errors[:email]} class="mt-1 text-xs text-error">
                  {@contact_errors[:email]}
                </p>
              </div>

              <div>
                <label for="contact-phone" class="label text-sm font-medium">Phone</label>
                <input
                  id="contact-phone"
                  type="tel"
                  name="contact[phone]"
                  value={@contact_form["phone"]}
                  class="input input-bordered w-full"
                  placeholder="Optional"
                />
              </div>

              <div class="divider"></div>

              <div class="space-y-3">
                <label class="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    name="contact[consent_store_data]"
                    value="true"
                    checked={@contact_form["consent_store_data"] == "true"}
                    class={[
                      "checkbox checkbox-primary mt-0.5",
                      @contact_errors[:consent_store_data] && "checkbox-error"
                    ]}
                  />
                  <span class="text-sm">
                    I agree to have my information saved and used by Rossouw Financial Planning.
                    <span class="text-error">*</span>
                  </span>
                </label>
                <p :if={@contact_errors[:consent_store_data]} class="ml-8 text-xs text-error">
                  {@contact_errors[:consent_store_data]}
                </p>

                <label class="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    name="contact[consent_contact]"
                    value="true"
                    checked={@contact_form["consent_contact"] == "true"}
                    class={[
                      "checkbox checkbox-primary mt-0.5",
                      @contact_errors[:consent_contact] && "checkbox-error"
                    ]}
                  />
                  <span class="text-sm">
                    I agree to be contacted by Rossouw for a free, no-obligation consultation.
                    <span class="text-error">*</span>
                  </span>
                </label>
                <p :if={@contact_errors[:consent_contact]} class="ml-8 text-xs text-error">
                  {@contact_errors[:consent_contact]}
                </p>
              </div>

              <div class="flex items-center justify-between pt-2">
                <button
                  type="button"
                  phx-click="back_to_questionnaire"
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-arrow-left-mini" class="size-4" /> Back
                </button>

                <.button
                  type="submit"
                  id="submit-lead-btn"
                  disabled={@submitting?}
                  class="btn-primary"
                >
                  {if @submitting?, do: "Submitting...", else: "Get My Risk Profile"}
                </.button>
              </div>
            </form>
          </div>
        </div>
        
    <!-- Step 3: Result -->
        <div :if={@step == :result} class="space-y-6">
          <div class="rounded-xl border border-base-300 bg-base-200/50 p-8 text-center space-y-6">
            <div>
              <p class="text-sm text-base-content/60">Your Risk Appetite Score</p>
              <p class="mt-2 text-5xl font-bold">{@live_score}</p>
              <p class="mt-1 text-sm text-base-content/60">out of 100</p>
            </div>

            <div>
              <span class={[
                "badge badge-lg text-base font-semibold py-3 px-6",
                RiskAppetite.category_color(@live_category)
              ]}>
                {@live_category}
              </span>
            </div>
            
    <!-- Score spectrum bar -->
            <div class="w-full max-w-md mx-auto">
              <div class="relative h-4 rounded-full bg-gradient-to-r from-info via-warning to-error overflow-hidden">
                <div
                  class="absolute top-0 h-full w-1 bg-base-content rounded-full -translate-x-1/2"
                  style={"left: #{@live_score}%"}
                >
                </div>
              </div>
              <div class="flex justify-between mt-1 text-xs text-base-content/50">
                <span>Conservative</span>
                <span>Moderate</span>
                <span>Aggressive</span>
              </div>
            </div>

            <p class="text-sm text-base-content/80 max-w-lg mx-auto">
              {RiskAppetite.category_description(@live_category)}
            </p>

            <div class="divider"></div>

            <div class="space-y-2">
              <p class="text-sm text-base-content/60">
                Thank you, {(@submission && @submission.name) || ""}! Rossouw may reach out to you
                for a free, no-obligation consultation to discuss your financial goals.
              </p>
            </div>

            <button phx-click="retake" class="btn btn-outline btn-sm mt-4">
              <.icon name="hero-arrow-path-mini" class="size-4" /> Retake Quiz
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # -- Private --

  defp do_submit(socket, params) do
    contact = normalize_contact_params(params)

    lead_params = %{
      "tool_slug" => "risk-appetite",
      "name" => contact["name"],
      "email" => contact["email"],
      "phone" => contact["phone"],
      "consent_contact" => contact["consent_contact"],
      "consent_store_data" => contact["consent_store_data"],
      "score" => socket.assigns.live_score,
      "category" => socket.assigns.live_category,
      "answers" => socket.assigns.answers
    }

    socket = assign(socket, :submitting?, true)

    case LeadSubmissionParams.input(lead_params) do
      {:ok, input} ->
        case ToolsFacade.submit_lead(input) do
          {:ok, submission} ->
            {:noreply,
             socket
             |> assign(:submission, submission)
             |> assign(:step, :result)
             |> assign(:submitting?, false)}

          {:error, _error} ->
            {:noreply,
             socket
             |> put_flash(:error, "Something went wrong. Please try again.")
             |> assign(:submitting?, false)}
        end

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, error.message)
         |> assign(:submitting?, false)}
    end
  end

  defp initial_contact_form do
    %{
      "name" => "",
      "email" => "",
      "phone" => "",
      "consent_contact" => nil,
      "consent_store_data" => nil
    }
  end

  defp normalize_contact_params(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "email" => Map.get(params, "email", ""),
      "phone" => Map.get(params, "phone", ""),
      "consent_contact" => Map.get(params, "consent_contact"),
      "consent_store_data" => Map.get(params, "consent_store_data")
    }
  end

  defp validate_contact_fields(params) do
    errors = %{}
    name = String.trim(Map.get(params, "name", ""))
    email = String.trim(Map.get(params, "email", ""))

    errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors

    errors =
      cond do
        email == "" ->
          Map.put(errors, :email, "Email is required")

        not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) ->
          Map.put(errors, :email, "Please enter a valid email address")

        true ->
          errors
      end

    errors =
      if Map.get(params, "consent_store_data") != "true",
        do: Map.put(errors, :consent_store_data, "You must agree to have your information saved"),
        else: errors

    errors =
      if Map.get(params, "consent_contact") != "true",
        do: Map.put(errors, :consent_contact, "You must agree to be contacted"),
        else: errors

    errors
  end

  defp step_class(current, target) do
    steps = [:questionnaire, :contact, :result]
    current_idx = Enum.find_index(steps, &(&1 == current))
    target_idx = Enum.find_index(steps, &(&1 == target))

    if target_idx <= current_idx, do: "step-primary", else: ""
  end

  attr :score, :integer, required: true
  attr :category, :string, required: true
  attr :answers, :map, required: true

  defp live_score_bar(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-200/50 p-4 space-y-3">
      <div class="flex items-center justify-between text-sm">
        <div class="flex items-center gap-2">
          <span class="font-medium">Live Score:</span>
          <span class="text-lg font-bold">{@score}</span>
          <span class="text-sm text-base-content/60">/ 100</span>
        </div>
        <span class={["badge badge-sm", RiskAppetite.category_color(@category)]}>
          {@category}
        </span>
      </div>
      <div class="relative h-3 rounded-full bg-gradient-to-r from-info via-warning to-error overflow-hidden">
        <div
          class="absolute top-0 h-full w-1.5 bg-base-content rounded-full -translate-x-1/2 transition-[left] duration-200"
          style={"left: #{@score}%"}
        >
        </div>
      </div>
    </div>
    """
  end
end
