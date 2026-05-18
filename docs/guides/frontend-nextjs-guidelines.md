# Frontend and Next.js Guidelines

This app is the `site` Next.js project. It is intended to run the public site and API on Vercel, with Supabase Postgres as the database and Prisma as the server-side ORM.

## Tech Stack

- Next.js `16.2.6` with the App Router in `src/app`.
- React `19.2.4` and TypeScript.
- Tailwind CSS `4` through `@tailwindcss/postcss`.
- shadcn/ui with the `base-nova` style, Base UI primitives, `class-variance-authority`, `tailwind-merge`, and `tw-animate-css`.
- `lucide-react` for icons.
- Prisma `7` with `@prisma/adapter-pg`, `pg`, and generated client output in `src/generated/prisma`.
- Zod for request and payload validation.
- ESLint `9` with `eslint-config-next`.
- Vercel for hosting the site and API.

## App Structure

- Keep route segments, layouts, pages, loading states, and route handlers in `src/app`.
- Keep shared UI primitives in `src/components`, with shadcn components under `src/components/ui`.
- Keep route-specific experiences in a dedicated component folder near the route, such as `src/app/_components/landing` for the home landing page.
- Split route-specific UI into focused component files rather than placing every section, primitive, hook, and data object into one large component file.
- Keep server-only helpers in `src/lib`, such as `src/lib/prisma.ts`.
- Keep generated Prisma files out of hand edits. Update `prisma/schema.prisma`, then run `npm run db:generate`.
- Use absolute imports through the `@/*` alias. Avoid barrel `index.ts` files unless a package-level public API truly needs one.

## Server and Client Components

- Treat components as Server Components by default.
- Add `"use client"` only when a component needs state, event handlers, effects, refs, browser APIs, or client-only hooks.
- Keep server secrets, Prisma, and direct database access out of Client Components.
- Pass plain serializable data from Server Components into Client Components.
- Prefer small client boundaries around interactive controls instead of making whole pages client-rendered.

## Data and API Access

- Route Handlers live in `src/app/api/**/route.ts`.
- Validate request bodies, search params, and dynamic route params with Zod before using them.
- Keep API responses explicit with `NextResponse.json(...)`.
- Do not call `fetch(...)` directly from React components. Put browser-facing API calls in a focused API client module, then import that client into components.
- Use Prisma only from server-side code. Import the singleton from `src/lib/prisma.ts`.
- Use `DATABASE_URL` for pooled serverless runtime database access and `DIRECT_URL` for Prisma CLI operations. `prisma.config.ts` should point CLI operations at the direct URL when it is available.

## Styling and UI

- Use Tailwind utilities and shadcn/ui components as the default UI language.
- Use `lucide-react` icons in buttons and compact actions when an icon exists.
- Keep cards for repeated items, modals, and genuinely framed content. Avoid nesting cards inside cards.
- Use restrained, product-grade layouts for operational surfaces: dense enough to scan, clear hierarchy, and no marketing-style filler when the user needs a tool.
- Keep text sizing tied to component context. Do not use hero-scale type inside compact panels.
- Ensure controls have stable dimensions so hover states, icons, and labels do not shift layout.
- Use `cn` from `src/lib/utils.ts` when composing conditional class names.

## TypeScript

- Use `type` for props and local data shapes. Prefer a short `Props` name when there is only one props type in the file.
- Do not use `any`. If a type is unclear, define the narrowest useful type or stop and clarify.
- Keep imports direct and explicit.
- Include real dependencies in hooks. Store callbacks in refs when they should not trigger re-renders.

## Environment and Deployment

- Do not commit `.env`. Keep safe placeholders in `.env.example`.
- Set `DATABASE_URL` and `DIRECT_URL` in Vercel.
- Use Supabase's pooled Postgres connection string for serverless deployments.
- Do not run Prisma migrations casually. Choose the migration workflow deliberately for the target Supabase project.
- Run `npm run lint` and `npm run build` before shipping changes.
