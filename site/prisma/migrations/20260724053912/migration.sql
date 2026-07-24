-- CreateTable
CREATE TABLE "CutProject" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "doc" JSONB NOT NULL,
    "folderId" TEXT,
    "version" INTEGER NOT NULL DEFAULT 1,
    "previewKey" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutProject_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CutFolder" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "scope" TEXT NOT NULL DEFAULT 'project',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutFolder_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CutMediaObject" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "projectId" TEXT,
    "r2Key" TEXT NOT NULL,
    "fileName" TEXT NOT NULL,
    "mime" TEXT NOT NULL DEFAULT '',
    "bytes" BIGINT NOT NULL DEFAULT 0,
    "kind" TEXT NOT NULL DEFAULT 'media',
    "uploadState" TEXT NOT NULL DEFAULT 'pending',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutMediaObject_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CutLibraryAsset" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "mediaObjectId" TEXT NOT NULL,
    "folderId" TEXT,
    "meta" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutLibraryAsset_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CutTemplate" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "doc" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutTemplate_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CutStorageUsage" (
    "userId" TEXT NOT NULL,
    "bytes" BIGINT NOT NULL DEFAULT 0,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutStorageUsage_pkey" PRIMARY KEY ("userId")
);

-- CreateTable
CREATE TABLE "CutRenderJob" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "projectId" TEXT,
    "kind" TEXT NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'queued',
    "progress" DOUBLE PRECISION NOT NULL DEFAULT 0,
    "spec" JSONB NOT NULL,
    "outputKey" TEXT,
    "outName" TEXT,
    "result" JSONB,
    "error" TEXT,
    "claimedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CutRenderJob_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "UserFeatureFlag" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "flag" TEXT NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "UserFeatureFlag_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "CutProject_userId_updatedAt_idx" ON "CutProject"("userId", "updatedAt");

-- CreateIndex
CREATE INDEX "CutFolder_userId_scope_idx" ON "CutFolder"("userId", "scope");

-- CreateIndex
CREATE UNIQUE INDEX "CutMediaObject_r2Key_key" ON "CutMediaObject"("r2Key");

-- CreateIndex
CREATE INDEX "CutMediaObject_userId_kind_idx" ON "CutMediaObject"("userId", "kind");

-- CreateIndex
CREATE INDEX "CutMediaObject_projectId_kind_idx" ON "CutMediaObject"("projectId", "kind");

-- CreateIndex
CREATE INDEX "CutLibraryAsset_userId_createdAt_idx" ON "CutLibraryAsset"("userId", "createdAt");

-- CreateIndex
CREATE INDEX "CutTemplate_userId_createdAt_idx" ON "CutTemplate"("userId", "createdAt");

-- CreateIndex
CREATE INDEX "CutRenderJob_userId_createdAt_idx" ON "CutRenderJob"("userId", "createdAt");

-- CreateIndex
CREATE INDEX "CutRenderJob_state_createdAt_idx" ON "CutRenderJob"("state", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "UserFeatureFlag_userId_flag_key" ON "UserFeatureFlag"("userId", "flag");
