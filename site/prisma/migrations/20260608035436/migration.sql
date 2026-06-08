/*
  Warnings:

  - A unique constraint covering the columns `[userId,unit,source,sourceId]` on the table `user_credit_grant` will be added. If there are existing duplicate values, this will fail.

*/
-- DropIndex
DROP INDEX "user_credit_grant_userId_expiresAt_idx";

-- DropIndex
DROP INDEX "user_credit_grant_userId_source_sourceId_key";

-- DropIndex
DROP INDEX "user_credit_grant_userId_status_idx";

-- AlterTable
ALTER TABLE "user_credit_grant" ADD COLUMN     "unit" TEXT NOT NULL DEFAULT 'credit';

-- CreateIndex
CREATE INDEX "user_credit_grant_userId_unit_status_idx" ON "user_credit_grant"("userId", "unit", "status");

-- CreateIndex
CREATE UNIQUE INDEX "user_credit_grant_userId_unit_source_sourceId_key" ON "user_credit_grant"("userId", "unit", "source", "sourceId");
