# Frontend and Next.js Guidelines

This guide explains how to work in the `site` app. Keep changes aligned with the existing route structure, Tailwind styling, and server/client boundaries.

## Project Shape

- Keep routes, layouts, pages, loading states, and route handlers in `src/app`.
- Keep shared UI primitives in `src/components`.
- Keep route-specific UI near the route, such as `src/app/_components/landing` for the home page.
- Split large route experiences into focused component files.
- Keep server-only helpers in `src/lib`.
- Use absolute imports through the `@/*` alias.
- Avoid barrel `index.ts` files unless a package-level public API truly needs one.

## Components

- Treat components as Server Components by default.
- Add `"use client"` only for state, effects, refs, event handlers, browser APIs, or client-only hooks.
- Keep client boundaries small and close to the interactive control.
- Keep secrets and direct database access out of Client Components.
- Pass plain serializable props from Server Components into Client Components.

## Navigation

- Use the `next/link` `<Link>` component for internal routes (anything starting with `/`) so navigation stays client-side and prefetches.
- Use a plain `<a>` only for external URLs, `mailto:`, and other non-route links.
- When a shared control accepts an arbitrary `href` (such as the landing `PillButton`), let the control pick `<Link>` vs `<a>` from the href instead of duplicating that choice at every call site.

## Styling

- Tailwind utility classes are the default for all UI, with no exceptions by area. This includes the landing components under `src/app/_components/landing`, which were historically inline-styled and are now Tailwind-first. Do not reintroduce React inline `style` objects for layout, spacing, typography, colors, borders, or responsive behavior.
- Tailwind is configured via CSS (`@theme` in `src/app/globals.css`), not a `tailwind.config.*` file; its absence is not a reason to use inline styles.
- Use the brand tokens defined in `globals.css` rather than repeating raw hex: `text-ink`/`bg-ink`/`border-ink` (near-black), `bg-coral`/`text-coral`, `bg-cream`, `bg-background` (page sand), and `font-system`/`font-code`. Reach for a Tailwind arbitrary value (`text-[#454545]`, `text-[clamp(45px,9.6vw,134px)]`) only for genuinely one-off values not worth a token.
- Use Tailwind responsive variants for breakpoints (`md:*`, and arbitrary variants like `min-[900px]:*` when a design uses a non-standard breakpoint). Do not add client-only media-query hooks to choose styling; express responsive styling in classes and, when an element only differs by visibility, toggle it with `hidden`/`md:block` rather than conditional rendering.
- Reserve inline `style` strictly for genuinely runtime values, such as a dimension computed from props or state, CSS custom properties derived from data, or a third-party style API.
- Compose conditional classes with the `cn` helper from `@/lib/utils`.
- Prefer existing icon components for buttons and compact actions when an icon fits the control.
- Keep controls at stable dimensions so hover states, icons, labels, and loading states do not shift layout.
- Keep cards for repeated items, modals, and genuinely framed content. Avoid nesting cards inside cards.

## Data and APIs

- Put Route Handlers in `src/app/api/**/route.ts`.
- Protect Donkey APIs unless an endpoint is intentionally public.
- Validate request bodies, search params, and route params before using them.
- Keep API responses explicit and consistently shaped.
- Do not call `fetch(...)` directly from React components. Client-side data
  access goes through TanStack Query hooks, and every query/mutation hook lives
  in `src/queries/` so the cache surface is auditable in one place. Components
  import the hooks; they do not fetch inline. The shared fetch wrapper and error
  type are `src/queries/apiClient.ts`. Define each query's key as a constant
  alongside its hook in the same module (export it if another module needs to
  invalidate it). Mount `QueryProvider` once at the root layout.
- Dashboard-style, per-user data views are client-rendered and read their data
  through these hooks. The route handlers still enforce auth server-side, so a
  client guard is for UX, not security.
- Use database clients only from server-side code.
- Do not run database migrations or schema pushes casually; choose the migration workflow deliberately for the target database.

## TypeScript

- Use `type` for props and local data shapes.
- Prefer a short `Props` name when there is only one props type in the file.
- Do not use `any`; define the narrowest useful type or stop and clarify.
- Prefer optional chaining (`a?.b`) over `a && a.b` or `!a || !a.b` when reading
  a possibly-absent member.
- Keep imports direct and explicit.
- Include real dependencies in hooks.
- Store callbacks in refs when they should not trigger re-renders.

## Checks

- Do not commit `.env` or secrets.
- Run `npm run lint` and `npm run build` before shipping frontend changes.
