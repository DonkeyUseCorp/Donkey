import { type NextRequest, NextResponse } from "next/server";

import { auth } from "@/lib/auth";
import { prisma } from "@/lib/prisma";

export type DonkeyAuthContext = {
  platform: "api";
  app: "donkey";
  method: "session-cookie";
  clientId: string | null;
  userId: string;
};

export type DonkeyAuthenticatedRequest = NextRequest & {
  donkey: DonkeyAuthContext;
};

export type DonkeyAuthHandler<
  TReq extends DonkeyAuthenticatedRequest = DonkeyAuthenticatedRequest,
  TArgs extends unknown[] = [],
> = (request: TReq, ...args: TArgs) => Promise<Response> | Response;

const clientIdHeader = "x-donkey-client-id";

export async function getDonkeyAuthContext(
  headers: Headers,
): Promise<DonkeyAuthContext | null> {
  const session = await auth.api.getSession({
    headers,
  });
  if (!session) {
    return null;
  }

  const clientId = headers.get(clientIdHeader)?.trim();

  return {
    platform: "api",
    app: "donkey",
    method: "session-cookie",
    clientId: clientId ? clientId : null,
    userId: session.user.id,
  };
}

export function withDonkeyAuth<
  TReq extends DonkeyAuthenticatedRequest = DonkeyAuthenticatedRequest,
  TArgs extends unknown[] = [],
>(handler: DonkeyAuthHandler<TReq, TArgs>) {
  return async (request: NextRequest, ...args: TArgs) => {
    const authContext = await getDonkeyAuthContext(request.headers);

    if (!authContext) {
      return NextResponse.json(
        {
          error: "Unauthorized",
          message: "Authentication required",
        },
        {
          status: 401,
        },
      );
    }

    const authenticatedRequest = Object.assign(request, {
      donkey: authContext,
    }) as TReq;

    return handler(authenticatedRequest, ...args);
  };
}

export async function isDonkeySuperUser(userId: string) {
  const user = await prisma.user.findUnique({
    select: {
      superUser: true,
    },
    where: {
      id: userId,
    },
  });

  return user?.superUser === true;
}
