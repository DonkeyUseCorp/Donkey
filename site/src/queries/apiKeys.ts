"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { apiFetch } from "@/queries/apiClient";

export const apiKeysQueryKey = ["api-keys"] as const;

export type ApiKey = {
  id: string;
  name: string | null;
  start: string | null;
  prefix: string | null;
  enabled: boolean;
  createdAt: string;
  lastRequest: string | null;
  expiresAt: string | null;
};

export type CreatedApiKey = {
  apiKey: ApiKey;
  // The plaintext secret, returned exactly once at creation.
  secret: string;
};

export function useApiKeys() {
  return useQuery({
    queryFn: () =>
      apiFetch<{ apiKeys: ApiKey[] }>("/api/api-keys").then(
        (response) => response.apiKeys,
      ),
    queryKey: apiKeysQueryKey,
  });
}

export function useCreateApiKey() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (name: string) =>
      apiFetch<CreatedApiKey>("/api/api-keys", {
        body: JSON.stringify({ name }),
        method: "POST",
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: apiKeysQueryKey });
    },
  });
}

export function useDeleteApiKey() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<{ deleted: boolean }>(`/api/api-keys/${id}`, {
        method: "DELETE",
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: apiKeysQueryKey });
    },
  });
}
