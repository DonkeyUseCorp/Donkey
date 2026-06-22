import { NextResponse } from "next/server";

import { auth } from "@/lib/auth";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";

export const dynamic = "force-dynamic";

type RouteContext = { params: Promise<{ id: string }> };

// Revoke (delete) one of the signed-in user's API keys. Better Auth enforces
// ownership against the session, so a user can only delete their own keys.
export const DELETE = withDonkeyAuth(
  async (request, context: RouteContext) => {
    const { id } = await context.params;

    await auth.api.deleteApiKey({
      body: { keyId: id },
      headers: request.headers,
    });

    return NextResponse.json({ deleted: true });
  },
);
