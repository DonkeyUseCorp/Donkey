export type BillingPlanKey = "pro";

export type BillingCheckoutResponse = {
  url: string;
};

export type BillingPortalResponse = {
  url: string;
};

export type BillingSubscription = {
  cancelAtPeriodEnd: boolean;
  currentPeriodEnd: string | null;
  planKey: BillingPlanKey;
  status: string;
};

export type BillingSubscriptionResponse = {
  subscription: BillingSubscription | null;
};

type BillingApiErrorCode =
  | "bad-request"
  | "not-found"
  | "server-error"
  | "unauthorized"
  | "unknown";

export class BillingApiError extends Error {
  code: BillingApiErrorCode;
  status: number;

  constructor(message: string, status: number, code: BillingApiErrorCode) {
    super(message);
    this.name = "BillingApiError";
    this.code = code;
    this.status = status;
  }
}

function errorCodeForStatus(status: number): BillingApiErrorCode {
  if (status === 400) {
    return "bad-request";
  }

  if (status === 401) {
    return "unauthorized";
  }

  if (status === 404) {
    return "not-found";
  }

  if (status >= 500) {
    return "server-error";
  }

  return "unknown";
}

async function readJson<T>(response: Response): Promise<T> {
  return (await response.json()) as T;
}

async function requireOk(response: Response, fallbackMessage: string) {
  if (response.ok) {
    return;
  }

  throw new BillingApiError(
    fallbackMessage,
    response.status,
    errorCodeForStatus(response.status),
  );
}

export async function createCheckoutSession(planKey: BillingPlanKey) {
  const response = await fetch("/api/billing/checkout/", {
    body: JSON.stringify({ planKey }),
    headers: {
      "Content-Type": "application/json",
    },
    method: "POST",
  });

  await requireOk(response, "Unable to start checkout.");

  return readJson<BillingCheckoutResponse>(response);
}

export async function createBillingPortalSession() {
  const response = await fetch("/api/billing/portal/", {
    method: "POST",
  });

  await requireOk(response, "Unable to open billing portal.");

  return readJson<BillingPortalResponse>(response);
}

export async function getBillingSubscription() {
  const response = await fetch("/api/billing/subscription/", {
    method: "GET",
  });

  await requireOk(response, "Unable to load subscription.");

  return readJson<BillingSubscriptionResponse>(response);
}
