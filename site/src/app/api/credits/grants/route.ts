import { NextResponse } from "next/server";
import { z } from "zod";

import { creditMicrosToString, creditStringToMicros } from "@/lib/credits/amounts";
import { getCreditBalance, grantCredits } from "@/lib/credits/inference";
import { isDonkeySuperUser, withDonkeyAuth } from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

const creditGrantRequestSchema = z.object({
  amountDollars: z.coerce.number().int().positive().max(100),
  description: z.string().trim().min(1).max(500).optional(),
  sourceId: z.string().trim().min(1).max(160).optional(),
  userId: z.string().trim().min(1),
}).strict();

export const POST = withDonkeyAuth(async (request) => {
  if (!(await isDonkeySuperUser(request.donkey.userId))) {
    return NextResponse.json(
      {
        error: "Forbidden",
        message: "Only super users can grant credits.",
      },
      { status: 403 },
    );
  }

  const parsed = creditGrantRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json(
      {
        error: "Invalid request",
        issues: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
      { status: 400 },
    );
  }

  const targetUser = await prisma.user.findUnique({
    select: {
      email: true,
      id: true,
    },
    where: {
      id: parsed.data.userId,
    },
  });

  if (!targetUser) {
    return NextResponse.json(
      {
        error: "Not found",
        message: "No user exists with that id.",
      },
      { status: 404 },
    );
  }

  const amountMicros = creditStringToMicros(String(parsed.data.amountDollars));
  const sourceId =
    parsed.data.sourceId ?? `manual-dollar:${targetUser.id}:${crypto.randomUUID()}`;
  const description =
    parsed.data.description ?? `Manual $${parsed.data.amountDollars} credit grant`;

  const grant = await grantCredits({
    amountMicros,
    description,
    metadata: {
      amountDollars: String(parsed.data.amountDollars),
      grantedByUserId: request.donkey.userId,
      targetUserId: targetUser.id,
    },
    source: "manual_dollar",
    sourceId,
    userId: targetUser.id,
  });
  const balance = await getCreditBalance(targetUser.id);

  return NextResponse.json({
    amountDollars: parsed.data.amountDollars,
    creditMicrosGranted: amountMicros.toString(),
    creditsGranted: creditMicrosToString(amountMicros),
    grant: {
      id: grant.id,
      source: grant.source,
      sourceId: grant.sourceId,
    },
    targetUser: {
      email: targetUser.email,
      id: targetUser.id,
    },
    balance,
  });
});
