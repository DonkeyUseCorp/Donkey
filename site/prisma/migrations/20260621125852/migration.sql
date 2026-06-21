-- CreateTable
CREATE TABLE "credit_auto_reload" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT false,
    "thresholdMicros" BIGINT NOT NULL DEFAULT 0,
    "amountMicros" BIGINT NOT NULL DEFAULT 0,
    "stripeCustomerId" TEXT,
    "stripePaymentMethodId" TEXT,
    "status" TEXT NOT NULL DEFAULT 'idle',
    "lastChargeAt" TIMESTAMP(3),
    "lastError" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "credit_auto_reload_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "credit_auto_reload_userId_key" ON "credit_auto_reload"("userId");

-- AddForeignKey
ALTER TABLE "credit_auto_reload" ADD CONSTRAINT "credit_auto_reload_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;
