---
name: frontend-design
description: Create distinctive, production-grade Phoenix LiveView UI for the Store blueprint (Tailwind + Alpine.js micro-interactions + Mishka Chelekom components). Dark-mode-first, OKLCH tokens, non-generic aesthetics.
license: See LICENSE.txt
---

# Store Frontend Design Skill (Phoenix LiveView + Tailwind + Alpine.js + Mishka Chelekom)

## Project Context (Truths you MUST NOT violate)
- Framework: Elixir + Phoenix + LiveView (server-rendered, websocket-driven).
- Ash: 3.x (web layer calls Ash actions; UI must not bypass domain rules).
- Styling: Tailwind (CSS-first mindset; do not invent new build systems).
- Color format: **OKLCH** everywhere (Tailwind v4 default). fileciteturn1file1
- Theme: **Dark mode first** (light mode optional later).
- JS: Alpine.js allowed **micro-interactions only** (no business logic; no client-side “mini-app”).
- UI kit: Mishka Chelekom components are the baseline (avoid ad-hoc component sprawl).
- Layout responsiveness:
  - **Full-width sections:** use `@media` queries.
  - **Reusable containers/cards:** use **container queries** with a parent `:has(> &)` selector pattern.
- Accessibility: semantic HTML + keyboard support + visible focus states are mandatory.

## Non-negotiable design tokens (Dark theme baseline)
Use these as the foundation tokens (OKLCH values shown; hex sources in comments):

- Background: `oklch(0.196 0.012 270.7)` /* #13151b */
- Card gradient: `oklch(0.356 0.018 268.2)` → `oklch(0.251 0.016 264.2)` /* #383c46 → #1e222a */
- Primary: `oklch(0.921 0.235 126.3)` /* #bdff00 */
- Text (light): `oklch(0.967 0.003 264.5)` /* #f3f4f6 */
- Text (dark): `oklch(0.196 0.012 270.7)` /* #13151b */
- Border radius: `10px`

### Depth tokens (MANDATORY)
Design relies on **layering + realistic shadows**:
- Use **3–4 neutral shades** (same hue, low chroma) to create “base / surface / raised” layers. fileciteturn1file0 fileciteturn1file1
- Shadows MUST be a **mix**:
  - a subtle **light inset highlight** (top)
  - plus a **darker outer** shadow (bottom)
  This combination reads more realistic than a single generic shadow. fileciteturn1file0 fileciteturn1file1

## Design Thinking (MANDATORY before coding)
Before writing code, decide (then execute):
- **Purpose:** what UI is being built + who uses it (admin vs storefront).
- **Tone:** pick ONE direction and commit (e.g., editorial, brutal minimal, warm boutique, utilitarian admin).
- **Signature moment:** one memorable detail (typography + composition + depth).
- **Stop rule:** don’t polish low-impact elements; prioritize what users interact with most. fileciteturn1file0

## Frontend Design Laws (Hard Rules)

### 1) “LiveView first” architecture
- Prefer LiveView assigns/events for state.
- Alpine.js only for: dropdowns, tabs, toggles, focus management, minor animations.
- No duplicate source-of-truth on the client.

### 2) OKLCH + tokens first (no random colors)
- Use OKLCH variables for neutrals and states. fileciteturn1file1
- Primary is for **CTAs + key highlights** only (do not neon-wash the whole UI).
- If a new token is needed: add it deliberately and document it in `docs/agent_rules/ui_guidelines.md`.

### 3) Depth is the default way to avoid “boring UI”
Use these moves first, in this order: fileciteturn1file0
- Layer a slightly lighter surface on top of the page background.
- Add a subtle top highlight (border/glow) and a darker bottom shadow.
- Use gradients on surfaces when appropriate (light-from-top illusion).
- On hover: increase depth (bigger shadow) **only** on interactive cards/buttons.

### 4) Chelekom baseline (component discipline)
- Use Mishka Chelekom components for primitives (buttons, inputs, modals, tables, alerts, badges).
- If a Chelekom component exists: use it; do not re-implement a parallel version.
- Custom components are allowed only when:
  - the design is clearly unique
  - the API is small and composable
  - accessibility is built in

### 5) Typography must be intentional
- No “default-looking” UI. Create a hierarchy:
  - headings (high contrast)
  - supporting copy (slightly muted)
  - labels/helper text (small, readable)
- Admin tables/forms must be dense-but-readable (consistent line height and spacing).

### 6) Motion: minimal, purposeful, respectful
- Prefer 1 orchestrated reveal over many random animations.
- Always respect `prefers-reduced-motion`.
- Avoid noisy effects.

### 7) Layout + responsiveness rules
- **Full-width sections:** media queries.
- **Reusable cards/containers:** container queries.
  - Pattern:
    - parent declares `container-type: inline-size`
    - parent selection uses `:has(> .your-component)` to scope container rules
    - component adapts with `@container (min-width: …)` rules
- Avoid “one layout fits all” components.

### 8) Accessibility is non-negotiable
- Semantic structure: `<main>`, `<nav>`, `<section>`, correct headings.
- Forms: labels, error states, required indicators, focus rings.
- Keyboard operable interactive elements. Color contrast must remain readable.

### 9) Performance discipline
- Keep JS minimal. Prefer CSS for visuals.
- Avoid large DOM trees and unnecessary re-renders.
- Images: responsive where applicable; lazy-load non-critical.

## Output Requirements (What you MUST produce)
When asked for UI work:
1) One-sentence **aesthetic direction**.
2) **Files to change** (exact paths).
3) Working code (HEEx/LiveView/component modules + Tailwind/CSS + minimal JS) — no pseudocode.
4) Must include: hover/focus/active states, responsive behavior, accessibility notes.
5) If adding Chelekom components:
   - include exact `mix` commands used
   - list generated/modified files

## Default UI principles (use unless overridden)
- Storefront: persuasion, clarity, strong CTAs, rich but controlled depth.
- Admin: clarity > decoration; tables/forms must scan fast; destructive actions must be safe.
- Always include: empty states, loading states, error states, success confirmation.

## Anti-Slop Checklist (FAIL if any are true)
- Looks like a generic template/“AI landing page”.
- Random colors or inconsistent OKLCH usage.
- Flat UI with no layering or depth where needed. fileciteturn1file0
- Missing focus states / poor keyboard navigation.
- Alpine.js used as the main state system.
- Duplicate primitives created instead of using Chelekom.
- Non-functional code with no LiveView integration.

---

Use this skill for any Store UI work: layouts, navigation, storefront pages, admin screens, forms, tables, modals, and micro-interactions.
