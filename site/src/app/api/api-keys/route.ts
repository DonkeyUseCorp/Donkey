import { NextResponse } from "next/server";
import { z } from "zod";

import { auth, visionApiKeyPrefix } from "@/lib/auth";
import {
  donkeySessionUserId,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
import { validationErrorResponse } from "@/lib/inference/responses";

export const dynamic = "force-dynamic";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

const createApiKeySchema = z.object({
  name: z.string().trim().min(1).max(120),
});

type ApiKeyRecord = {
  id: string;
  name: string | null;
  start: string | null;
  prefix: string | null;
  enabled: boolean | null;
  referenceId: string;
  createdAt: Date;
  lastRequest: Date | null;
  expiresAt: Date | null;
};

function toSafeApiKey(key: ApiKeyRecord) {
  return {
    createdAt: key.createdAt,
    enabled: key.enabled ?? true,
    expiresAt: key.expiresAt,
    id: key.id,
    lastRequest: key.lastRequest,
    name: key.name,
    // start + prefix let the UI show e.g. "dk_live_abc…" without the secret.
    prefix: key.prefix,
    start: key.start,
  };
}

// List the signed-in user's Vision API keys (secrets never returned). The
// referenceId filter is defense-in-depth: the plugin already scopes by session,
// but we never return a key the session user does not own.
export const GET = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorized();
  }

  const result = (await auth.api.listApiKeys({
    headers: request.headers,
  })) as { apiKeys: ApiKeyRecord[] } | ApiKeyRecord[];
  const keys = Array.isArray(result) ? result : result.apiKeys;
  const ownKeys = keys.filter((key) => key.referenceId === userId);

  return NextResponse.json({ apiKeys: ownKeys.map(toSafeApiKey) });
});

// Create a new key. Any signed-in user can mint one; the key only returns data
// when the user has capacity (an active subscription or remaining vision-call
// grants), which the Vision API route enforces per call. The full secret is
// returned exactly once here and never again.
export const POST = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorized();
  }

  const body = await request.json().catch(() => null);
  const parsed = createApiKeySchema.safeParse(body);
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }

  const created = await auth.api.createApiKey({
    body: {
      name: parsed.data.name,
      prefix: visionApiKeyPrefix,
    },
    headers: request.headers,
  });

  return NextResponse.json({
    apiKey: toSafeApiKey(created as ApiKeyRecord),
    // The plaintext secret — display once, store securely client-side, then drop.
    secret: created.key,
  });
});
