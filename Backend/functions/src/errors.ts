import type { Response } from "express";
import { randomUUID } from "node:crypto";

export class APIError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly retryable = false,
  ) { super(message); }
}

export function sendError(response: Response, error: unknown, requestID: string = randomUUID()): void {
  const known = error instanceof APIError
    ? error
    : new APIError(500, "INTERNAL", "Internal server error", true);
  response.status(known.status).json({
    error: { code: known.code, message: known.message, retryable: known.retryable, request_id: requestID },
  });
}
