import { JWT } from "google-auth-library";

import { InferenceProviderError } from "@/lib/inference/providers";

const vertexAIScope = "https://www.googleapis.com/auth/cloud-platform";
const defaultVertexLocation = "global";
// The backend owns the Live model id (the client never selects it). Override
// with GEMINI_LIVE_MODEL. `gemini-live-2.5-flash` is the model that resolves on
// Vertex AI in the `global` location and accepts the BidiGenerateContent setup
// (verified end-to-end via GeminiLiveCommandSessionLiveSmokeTests).
const defaultLiveModel = "gemini-live-2.5-flash";

type AdapterEnvironment = Record<string, string | undefined>;

/**
 * Connection details a Donkey client needs to open a Gemini Live (Vertex AI)
 * websocket directly: a short-lived OAuth access token plus the endpoint and
 * fully-qualified model path. The long-lived service-account credential never
 * leaves the backend.
 */
export type VertexLiveConnection = {
  token: string;
  expiresAt: string | null;
  websocketUrl: string;
  model: string;
  project: string;
  location: string;
};

export function vertexLiveConfigured(
  environment: AdapterEnvironment = process.env,
): boolean {
  return Boolean(environment.GOOGLE_APPLICATION_CREDENTIALS_JSON?.trim());
}

/** Mint a short-lived Vertex AI access token + Live connection details. */
export async function mintVertexLiveConnection(
  environment: AdapterEnvironment = process.env,
): Promise<VertexLiveConnection> {
  const raw = environment.GOOGLE_APPLICATION_CREDENTIALS_JSON?.trim();
  if (!raw) {
    throw new InferenceProviderError(
      "Vertex AI service account credentials are not configured.",
      { statusCode: 503, code: "vertex_live_not_configured" },
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new InferenceProviderError("Google service account JSON is invalid.", {
      statusCode: 500,
      code: "invalid_google_service_account_json",
    });
  }

  const credentials = parsed as {
    client_email?: string;
    private_key?: string;
    private_key_id?: string;
    project_id?: string;
  };
  const clientEmail = credentials.client_email?.trim();
  const privateKey = credentials.private_key;
  const project = credentials.project_id?.trim();
  if (!clientEmail || !privateKey || !project) {
    throw new InferenceProviderError(
      "Google service account JSON must include client_email, private_key, and project_id.",
      { statusCode: 500, code: "invalid_google_service_account_json" },
    );
  }

  const jwt = new JWT({
    email: clientEmail,
    key: privateKey,
    keyId: credentials.private_key_id,
    scopes: [vertexAIScope],
  });

  let token: string | null | undefined;
  try {
    ({ token } = await jwt.getAccessToken());
  } catch (error) {
    throw new InferenceProviderError("Failed to mint a Vertex AI access token.", {
      statusCode: 502,
      code: "vertex_live_token_failed",
      details: { message: error instanceof Error ? error.message : String(error) },
    });
  }
  if (!token) {
    throw new InferenceProviderError("Failed to mint a Vertex AI access token.", {
      statusCode: 502,
      code: "vertex_live_token_failed",
    });
  }

  const location =
    environment.GEMINI_VERTEX_LOCATION?.trim()
    || environment.GOOGLE_VERTEX_LOCATION?.trim()
    || defaultVertexLocation;
  const model = environment.GEMINI_LIVE_MODEL?.trim() || defaultLiveModel;
  const host =
    location === "global"
      ? "aiplatform.googleapis.com"
      : `${location}-aiplatform.googleapis.com`;
  const websocketUrl =
    `wss://${host}/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`;
  const expiry = jwt.credentials.expiry_date;

  return {
    token,
    expiresAt: typeof expiry === "number" ? new Date(expiry).toISOString() : null,
    websocketUrl,
    model: `projects/${project}/locations/${location}/publishers/google/models/${model}`,
    project,
    location,
  };
}
