-- CreateTable
CREATE TABLE "pro_subscription" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "stripeCustomerId" TEXT,
    "stripeSubscriptionId" TEXT,
    "status" TEXT NOT NULL DEFAULT 'incomplete',
    "planKey" TEXT NOT NULL DEFAULT 'pro',
    "monthlyAllowanceMicros" BIGINT NOT NULL DEFAULT 0,
    "currentPeriodStart" TIMESTAMP(3),
    "currentPeriodEnd" TIMESTAMP(3),
    "cancelAtPeriodEnd" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "pro_subscription_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "pro_subscription_userId_key" ON "pro_subscription"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "pro_subscription_stripeSubscriptionId_key" ON "pro_subscription"("stripeSubscriptionId");

-- AddForeignKey
ALTER TABLE "pro_subscription" ADD CONSTRAINT "pro_subscription_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;
