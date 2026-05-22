import { type NextRequest, NextResponse } from "next/server";

export type DonkeyAuthContext = {
  platform: "api";
  app: "donkey";
  clientId: string | null;
};

export type DonkeyAuthenticatedRequest = NextRequest & {
  donkey: DonkeyAuthContext;
};

export type DonkeyAuthHandler<
  TReq extends DonkeyAuthenticatedRequest = DonkeyAuthenticatedRequest,
  TArgs extends unknown[] = [],
> = (request: TReq, ...args: TArgs) => Promise<NextResponse> | NextResponse;

const apiTokenEnvName = "DONKEY_API_TOKEN";
const apiKeyHeader = "x-donkey-api-key";
const clientIdHeader = "x-donkey-client-id";

function getConfiguredApiToken() {
  const token = process.env[apiTokenEnvName]?.trim();

  return token ? token : null;
}

function getRequestApiToken(headers: Headers) {
  const authorizationHeader = headers.get("authorization")?.trim();

  if (authorizationHeader) {
    const bearerMatch = authorizationHeader.match(/^Bearer\s+(.+)$/i);

    if (bearerMatch?.[1]) {
      return bearerMatch[1].trim();
    }
  }

  const apiKey = headers.get(apiKeyHeader)?.trim();

  return apiKey ? apiKey : null;
}

export function getDonkeyAuthContext(headers: Headers): DonkeyAuthContext | null {
  const configuredToken = getConfiguredApiToken();
  const requestToken = getRequestApiToken(headers);

  if (!configuredToken || requestToken !== configuredToken) {
    return null;
  }

  const clientId = headers.get(clientIdHeader)?.trim();

  return {
    platform: "api",
    app: "donkey",
    clientId: clientId ? clientId : null,
  };
}

export function withDonkeyAuth<
  TReq extends DonkeyAuthenticatedRequest = DonkeyAuthenticatedRequest,
  TArgs extends unknown[] = [],
>(handler: DonkeyAuthHandler<TReq, TArgs>) {
  return (request: NextRequest, ...args: TArgs) => {
    const authContext = getDonkeyAuthContext(request.headers);

    if (!authContext) {
      return NextResponse.json(
        {
          error: "Unauthorized",
          message: "Authentication required",
        },
        {
          status: 401,
          headers: {
            "WWW-Authenticate": "Bearer",
          },
        },
      );
    }

    const authenticatedRequest = Object.assign(request, {
      donkey: authContext,
    }) as TReq;

    return handler(authenticatedRequest, ...args);
  };
}
