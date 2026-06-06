// Thin fetch wrapper shared by every query/mutation hook in this folder. All
// settings UI data access goes through here so it can be audited in one place.

export class ApiError extends Error {
  public readonly status: number;
  public readonly code: string | null;

  public constructor(message: string, status: number, code: string | null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

type ApiErrorBody = { error?: string; message?: string };

export async function apiFetch<T>(
  path: string,
  init?: RequestInit,
): Promise<T> {
  const hasBody = init?.body !== undefined;
  const response = await fetch(path, {
    ...init,
    headers: {
      ...(hasBody ? { "Content-Type": "application/json" } : {}),
      ...init?.headers,
    },
  });

  if (!response.ok) {
    let body: ApiErrorBody = {};
    try {
      body = (await response.json()) as ApiErrorBody;
    } catch {
      // Non-JSON error body; fall back to status text.
    }
    throw new ApiError(
      body.message ?? response.statusText,
      response.status,
      body.error ?? null,
    );
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}
