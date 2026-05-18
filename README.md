# Donkey

Donkey is a low-latency desktop agent for macOS that sees the screen, understands local context, and controls apps quickly.

## More Info

- `docs/README.md`: supported product behavior and engineering guidance.
- `docs/guides/`: focused guides for maintained capabilities and project conventions.
- `plans/master-plan.md`: active implementation driver when present.
- `plans/`: exploratory, active, and historical planning context.

## Build

Build and run the macOS app:

```sh
cd apps/Donkey
swift build
swift run Donkey
```

Build and run the site:

```sh
cd site
npm install
npm run db:generate
npm run build
npm run dev
```

The site uses Supabase Postgres through Prisma. Keep local credentials in `.env` and do not commit them.
