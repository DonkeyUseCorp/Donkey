# Backend API Guide

Backend APIs live in `site/src/app/api/**/route.ts`.

## Rules

- APIs are authenticated by default.
- Always wrap route handlers with `withDonkeyAuth` from `@/lib/donkey-api-auth`.
- Treat public endpoints as exceptions that need an explicit product reason.
- Validate request bodies, search params, and route params with Zod before using them.
- Verify resource ownership before reading or mutating scoped data.
- Return explicit `NextResponse.json(...)` responses with the intended status code.
- Keep Prisma access server-only through `@/lib/prisma`.
- Do not run database migrations as part of normal API work.

## Pattern

```typescript
import { NextResponse } from "next/server";

import { withDonkeyAuth } from "@/lib/donkey-api-auth";

export const GET = withDonkeyAuth((request) => {
  return NextResponse.json({
    clientId: request.donkey.clientId,
  });
});
```
