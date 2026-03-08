// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/store"
import topbar from "../vendor/topbar"

let stripeLoaderPromise = null

const ensureStripeJs = () => {
  if (window.Stripe) {
    return Promise.resolve(window.Stripe)
  }

  if (stripeLoaderPromise) {
    return stripeLoaderPromise
  }

  stripeLoaderPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector("script[data-stripe-js]")

    if (existing) {
      existing.addEventListener("load", () => resolve(window.Stripe), {once: true})
      existing.addEventListener("error", () => reject(new Error("Unable to load Stripe.js")), {once: true})
      return
    }

    const script = document.createElement("script")
    script.src = "https://js.stripe.com/v3"
    script.async = true
    script.dataset.stripeJs = "true"
    script.addEventListener("load", () => resolve(window.Stripe), {once: true})
    script.addEventListener("error", () => reject(new Error("Unable to load Stripe.js")), {once: true})
    document.head.appendChild(script)
  })

  return stripeLoaderPromise
}

const StripeElements = {
  mounted() {
    this.handleConfirmClick = this.handleConfirmClick.bind(this)
    this.renderElements()
  },

  updated() {
    this.renderElements()
  },

  destroyed() {
    this.teardown()
  },

  async renderElements() {
    const clientSecret = this.el.dataset.clientSecret
    const publishableKey = this.el.dataset.publishableKey

    if (!clientSecret || !publishableKey) {
      this.teardown()
      return
    }

    if (this.currentClientSecret === clientSecret && this.cardElement && this.confirmButton) {
      return
    }

    this.teardown()

    try {
      const Stripe = await ensureStripeJs()
      if (!Stripe) {
        throw new Error("Stripe.js is unavailable")
      }

      this.stripe = Stripe(publishableKey)
      this.elements = this.stripe.elements()
      this.cardElement = this.elements.create("card")
      this.cardContainer = this.el.querySelector("[data-stripe-element]")
      this.confirmButton = this.el.querySelector("[data-stripe-confirm]")

      if (!this.cardContainer || !this.confirmButton) {
        throw new Error("Stripe payment update UI is incomplete")
      }

      this.cardElement.mount(this.cardContainer)
      this.confirmButton.addEventListener("click", this.handleConfirmClick)
      this.currentClientSecret = clientSecret
    } catch (error) {
      this.pushEvent("stripe_setup_failed", {message: error.message || "Unable to load Stripe"})
    }
  },

  teardown() {
    if (this.confirmButton && this.handleConfirmClick) {
      this.confirmButton.removeEventListener("click", this.handleConfirmClick)
    }

    if (this.cardElement) {
      this.cardElement.destroy()
    }

    this.cardElement = null
    this.cardContainer = null
    this.confirmButton = null
    this.elements = null
    this.stripe = null
    this.currentClientSecret = null
  },

  async handleConfirmClick(event) {
    event.preventDefault()

    if (!this.stripe || !this.cardElement) {
      this.pushEvent("stripe_setup_failed", {message: "Card form is not ready yet"})
      return
    }

    if (this.confirmButton) {
      this.confirmButton.disabled = true
    }

    try {
      const result = await this.stripe.confirmCardSetup(this.currentClientSecret, {
        payment_method: {
          card: this.cardElement,
        },
      })

      if (result.error) {
        this.pushEvent("stripe_setup_failed", {
          message: result.error.message || "Unable to confirm card update",
        })
        return
      }

      this.pushEvent("stripe_setup_succeeded", {
        setup_intent_id: result.setupIntent && result.setupIntent.id,
      })
    } catch (error) {
      this.pushEvent("stripe_setup_failed", {message: error.message || "Unable to confirm card update"})
    } finally {
      if (this.confirmButton) {
        this.confirmButton.disabled = false
      }
    }
  },
}

const membershipToast = (() => {
  let root = null
  let timeoutId = null

  const ensureRoot = () => {
    if (root) {
      return root
    }

    root = document.createElement("div")
    root.id = "membership-status-toast"
    root.setAttribute("role", "status")
    root.setAttribute("aria-live", "polite")
    root.style.position = "fixed"
    root.style.right = "1rem"
    root.style.bottom = "1rem"
    root.style.zIndex = "1000"
    root.style.maxWidth = "24rem"
    document.body.appendChild(root)
    return root
  }

  return {
    show(message) {
      const container = ensureRoot()

      container.innerHTML = `
        <div style="
          border: 1px solid oklch(0.356 0.018 268.2 / 0.7);
          background: linear-gradient(180deg, oklch(0.356 0.018 268.2), oklch(0.251 0.016 264.2));
          color: oklch(0.967 0.003 264.5);
          border-radius: 10px;
          padding: 0.9rem 1rem;
          box-shadow:
            inset 0 1px 0 oklch(0.55 0.01 265 / 0.35),
            0 18px 40px oklch(0.12 0.01 265 / 0.45);
        ">
          <div style="font-size: 0.75rem; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.72;">
            Membership update
          </div>
          <div style="margin-top: 0.35rem; font-size: 0.95rem; line-height: 1.4;">
            ${message}
          </div>
        </div>
      `

      if (timeoutId) {
        window.clearTimeout(timeoutId)
      }

      timeoutId = window.setTimeout(() => {
        container.innerHTML = ""
      }, 5000)
    },
  }
})()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, StripeElements},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

window.addEventListener("phx:membership_expired", event => {
  const reason = event.detail && event.detail.reason
  const message =
    reason === "grace_expired"
      ? "Your membership access has ended."
      : "Your membership access changed. Refreshing access now."

  membershipToast.show(message)
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
