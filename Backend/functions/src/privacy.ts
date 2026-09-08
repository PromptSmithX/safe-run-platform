const allowedKeys = new Set([
  "event_name", "timestamp", "app_version", "request_id", "session_id", "packet_id",
  "event_id", "incident_id", "queue_depth", "latency_bucket", "retry_count", "error_code",
]);

export type SafeLogRecord = Record<string, unknown>;

export function assertSafeLogRecord(record: SafeLogRecord): void {
  const forbidden = Object.keys(record).filter(key => !allowedKeys.has(key));
  if (forbidden.length) throw new Error(`Sensitive or unknown log keys rejected: ${forbidden.join(",")}`);
}

export function safeLog(record: SafeLogRecord): void {
  assertSafeLogRecord(record);
  console.info(JSON.stringify(record));
}

export const retention = {
  telemetryMillis: 72 * 60 * 60 * 1000,
  incidentMillis: 90 * 24 * 60 * 60 * 1000,
  operationalMillis: 30 * 24 * 60 * 60 * 1000,
  debugOutboxMillis: 24 * 60 * 60 * 1000,
};
