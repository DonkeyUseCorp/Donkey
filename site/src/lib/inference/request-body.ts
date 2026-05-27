import { NextResponse } from "next/server";

type LimitedJsonResult =
  | {
    ok: true;
    json: unknown;
  }
  | {
    ok: false;
    response: Response;
  };

export async function readLimitedJsonBody(
  request: Request,
  maxBytes: number,
): Promise<LimitedJsonResult> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return {
      ok: false,
      response: NextResponse.json(
        {
          error: "Unsupported media type",
          message: "Request body must be application/json.",
        },
        { status: 415 },
      ),
    };
  }

  const contentLength = contentLengthBytes(request.headers);
  if (contentLength !== null && contentLength > maxBytes) {
    return {
      ok: false,
      response: payloadTooLargeResponse(maxBytes),
    };
  }

  const body = await readTextBody(request, maxBytes);
  if (!body.ok) {
    return body;
  }

  try {
    return {
      ok: true,
      json: JSON.parse(body.text),
    };
  } catch {
    return {
      ok: false,
      response: NextResponse.json(
        {
          error: "Invalid JSON",
          message: "Request body must be valid JSON.",
        },
        { status: 400 },
      ),
    };
  }
}

function contentLengthBytes(headers: Headers) {
  const raw = headers.get("content-length");
  if (!raw) {
    return null;
  }

  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

async function readTextBody(
  request: Request,
  maxBytes: number,
): Promise<
  | {
    ok: true;
    text: string;
  }
  | {
    ok: false;
    response: Response;
  }
> {
  const reader = request.body?.getReader();
  if (!reader) {
    return {
      ok: false,
      response: NextResponse.json(
        {
          error: "Invalid request",
          message: "Request body is required.",
        },
        { status: 400 },
      ),
    };
  }

  const decoder = new TextDecoder();
  const chunks: string[] = [];
  let byteCount = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    byteCount += value.byteLength;
    if (byteCount > maxBytes) {
      return {
        ok: false,
        response: payloadTooLargeResponse(maxBytes),
      };
    }
    chunks.push(decoder.decode(value, { stream: true }));
  }

  chunks.push(decoder.decode());
  return {
    ok: true,
    text: chunks.join(""),
  };
}

function payloadTooLargeResponse(maxBytes: number) {
  return NextResponse.json(
    {
      error: "Payload too large",
      message: `Request body must be ${maxBytes} bytes or smaller.`,
    },
    { status: 413 },
  );
}
