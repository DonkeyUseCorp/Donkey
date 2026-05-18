# Site

Next.js site and API project for Vercel, backed by Supabase Postgres through Prisma.

## Getting Started

Install dependencies and generate the Prisma client:

```bash
npm install
npm run db:generate
```

Create a Supabase project, copy `.env.example` to `.env`, and set:

```bash
DATABASE_URL="postgresql://postgres:[PASSWORD]@[PROJECT-REF].pooler.supabase.com:6543/postgres?pgbouncer=true&connection_limit=1"
DIRECT_URL="postgresql://postgres:[PASSWORD]@db.[PROJECT-REF].supabase.co:5432/postgres"
```

Run the development server:

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). The public health route is available at [http://localhost:3000/api/health](http://localhost:3000/api/health).

## Stack

- Next.js App Router with TypeScript and Tailwind CSS.
- shadcn/ui initialized with the `base-nova` style and `@/components` aliases.
- Prisma 7 configured for Supabase Postgres.
- Vercel-compatible `build`, `start`, and `postinstall` scripts.

## Guidelines

Read [Frontend and Next.js Guidelines](docs/frontend-nextjs-guidelines.md) before changing the site UI, routes, API handlers, or data access patterns.

## Database

Prisma is configured in `prisma/schema.prisma` and `prisma.config.ts`. The starter schema includes a `WaitlistEntry` model as a first writable table.

Do not commit `.env`. Set `DATABASE_URL` and `DIRECT_URL` in Vercel before deploying. Database access must go through API/server code; do not expose database configuration with `NEXT_PUBLIC_`.

Use Supabase's pooled connection string for `DATABASE_URL` in serverless runtime code. Use the direct, non-pooled connection string for `DIRECT_URL`; Prisma CLI commands use it through `prisma.config.ts` for migrations and schema pushes.

For local Supabase, run CLI commands from this `site` directory. The local Supabase project id is `donkey`, and the database listens on port `54332` so it can run alongside another local Supabase project using the default ports.

```bash
supabase start
supabase status
```

Use the local database URL for both Prisma variables during development:

```bash
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres"
DIRECT_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres"
```

## Scripts

- `npm run dev`: run the app locally.
- `npm run build`: build for production.
- `npm run start`: serve a production build.
- `npm run lint`: run ESLint.
- `npm run db:generate`: generate the Prisma client.
- `npm run db:pull`: introspect an existing Supabase database.

No migrations have been run. When you are ready to create tables, choose the migration workflow deliberately for the Supabase project.
