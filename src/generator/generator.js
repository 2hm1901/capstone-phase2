import crypto from "k6/crypto";
import http from "k6/http";
import { sleep } from "k6";

const VALID_SCENARIOS = ["gradual_drift", "sudden_spike", "slow_leak", "noisy_baseline"];
const DEFAULT_SERVICES = "payment-gw,ledger,fraud-detector";
const DEFAULT_SCENARIO_LIST = VALID_SCENARIOS.join(",");
const DEFAULT_RUN_DURATION_SECONDS = "600";

const tenantId = __ENV.TENANT_ID || "tenant-cdo08-demo";
const awsRegion = __ENV.AWS_REGION || "us-east-1";
const emitIntervalSeconds = parsePositiveInt(__ENV.EMIT_INTERVAL_SECONDS, 60);
const ingestEndpoint = __ENV.INGEST_API_ENDPOINT || "";
const runDurationSeconds = parsePositiveInt(
  __ENV.RUN_DURATION_SECONDS,
  Number(DEFAULT_RUN_DURATION_SECONDS),
);
const anomalyStartSeconds = parseNonNegativeInt(__ENV.ANOMALY_START_SECONDS, 7200);
const backfillMode = parseBoolean(__ENV.BACKFILL_MODE, false);
const backfillMinutes = parsePositiveInt(__ENV.BACKFILL_MINUTES, 120);
const backfillStepSeconds = parsePositiveInt(__ENV.BACKFILL_STEP_SECONDS, emitIntervalSeconds);
const services = parseCsv(__ENV.SERVICE_LIST || DEFAULT_SERVICES);
const scenarios = selectScenarios(__ENV.SCENARIO, __ENV.SCENARIO_LIST || DEFAULT_SCENARIO_LIST);

let backfillCompleted = false;

export const options = {
  scenarios: {
    telemetry_generator: {
      executor: "constant-vus",
      vus: 1,
      duration: `${runDurationSeconds}s`,
      gracefulStop: "5s",
    },
  },
};

const metricTypes = [
  "cpu_usage_percent",
  "memory_usage_percent",
  "active_connections",
  "db_connection_pool_pct",
  "queue_depth",
  "cache_hit_rate_pct",
  "api_latency_ms",
];

const percentageMetricTypes = ["cpu_usage_percent", "memory_usage_percent", "db_connection_pool_pct", "cache_hit_rate_pct"];

// The four metrics consumed by the AI Engine are aligned to the average values
// from external/ai-team-foresight-lens/engine-skeleton/baselines/*.json.
// The remaining synthetic signals do not exist in the AI baseline files and are
// kept as CDO-side observability/fallback signals.
const baselines = {
  "payment-gw": {
    cpu_usage_percent: 40.01,
    memory_usage_percent: 40.03,
    active_connections: 780.0,
    db_connection_pool_pct: 18.0,
    queue_depth: 525.70,
    cache_hit_rate_pct: 92.0,
    api_latency_ms: 75.14,
  },
  ledger: {
    cpu_usage_percent: 21.24,
    memory_usage_percent: 59.97,
    active_connections: 190.0,
    db_connection_pool_pct: 46.0,
    queue_depth: 1880.15,
    cache_hit_rate_pct: 86.0,
    api_latency_ms: 15.56,
  },
  "fraud-detector": {
    cpu_usage_percent: 27.54,
    memory_usage_percent: 49.97,
    active_connections: 260.0,
    db_connection_pool_pct: 35.0,
    queue_depth: 138.68,
    cache_hit_rate_pct: 81.0,
    api_latency_ms: 250.23,
  },
};

export function setup() {
  if (!ingestEndpoint) {
    throw new Error("INGEST_API_ENDPOINT is required.");
  }

  const credentials = loadAwsCredentials();
  if (!credentials.accessKeyId || !credentials.secretAccessKey) {
    throw new Error("AWS credentials were not available from env or ECS task role metadata.");
  }

  log("generator_started", {
    services,
    scenarios,
    emit_interval_seconds: emitIntervalSeconds,
    run_duration_seconds: runDurationSeconds,
    anomaly_start_seconds: anomalyStartSeconds,
    backfill_mode: backfillMode,
    backfill_minutes: backfillMode ? backfillMinutes : undefined,
    backfill_step_seconds: backfillMode ? backfillStepSeconds : undefined,
    auth: "iam_sigv4",
  });

  return {
    credentials,
    startedAt: Date.now(),
  };
}

export default function (data) {
  if (backfillMode) {
    if (!backfillCompleted) {
      emitBackfill(data.credentials);
      backfillCompleted = true;
    }
    sleep(1);
    return;
  }

  const elapsedMinutes = (Date.now() - data.startedAt) / 60000.0;
  const scenario = scenarios[Math.floor(elapsedMinutes / Math.max(emitIntervalSeconds / 60.0, 1 / 60)) % scenarios.length];

  for (const serviceId of services) {
    const correlationId = uuidv4();

    for (const metricType of metricTypes) {
      const payload = {
        ts: new Date().toISOString(),
        tenant_id: tenantId,
        service_id: serviceId,
        metric_type: metricType,
        value: calculateMetricValue(scenario, serviceId, metricType, elapsedMinutes),
        labels: metricLabels(serviceId, metricType, scenario),
        schema_version: "v1.0",
        correlation_id: correlationId,
      };

      const response = postSignedJson(ingestEndpoint, payload, data.credentials);
      const level = response.status >= 200 && response.status < 300 ? "info" : "warn";
      log("metric_emit_result", {
        level,
        status: response.status,
        service_id: serviceId,
        metric_type: metricType,
        scenario,
        correlation_id: correlationId,
        response_body: response.status >= 200 && response.status < 300 ? undefined : response.body,
      });
    }
  }

  sleep(emitIntervalSeconds);
}

function emitBackfill(credentials) {
  const endTime = new Date();
  const stepMs = backfillStepSeconds * 1000;
  const startTime = new Date(endTime.getTime() - backfillMinutes * 60 * 1000 + stepMs);
  let emitted = 0;
  let failed = 0;

  log("backfill_started", {
    start_ts: startTime.toISOString(),
    end_ts: endTime.toISOString(),
    services,
    scenarios,
    backfill_minutes: backfillMinutes,
    backfill_step_seconds: backfillStepSeconds,
  });

  for (let ts = startTime.getTime(); ts <= endTime.getTime(); ts += stepMs) {
    const pointTime = new Date(ts);
    const elapsedMinutes = Math.max(0, (ts - startTime.getTime()) / 60000.0);
    const scenario = scenarios[Math.floor(elapsedMinutes / Math.max(backfillStepSeconds / 60.0, 1 / 60)) % scenarios.length];

    for (const serviceId of services) {
      const correlationId = uuidv4();

      for (const metricType of metricTypes) {
        const payload = {
          ts: pointTime.toISOString(),
          tenant_id: tenantId,
          service_id: serviceId,
          metric_type: metricType,
          value: calculateMetricValue(scenario, serviceId, metricType, elapsedMinutes),
          labels: metricLabels(serviceId, metricType, scenario),
          schema_version: "v1.0",
          correlation_id: correlationId,
        };

        const response = postSignedJson(ingestEndpoint, payload, credentials);
        emitted += response.status >= 200 && response.status < 300 ? 1 : 0;
        failed += response.status >= 200 && response.status < 300 ? 0 : 1;

        if (failed > 0 || emitted % 250 === 0) {
          log("backfill_emit_progress", {
            status: response.status,
            emitted,
            failed,
            service_id: serviceId,
            metric_type: metricType,
            scenario,
            point_ts: payload.ts,
            response_body: response.status >= 200 && response.status < 300 ? undefined : response.body,
          });
        }
      }
    }
  }

  log("backfill_completed", {
    emitted,
    failed,
    services,
    scenarios,
    backfill_minutes: backfillMinutes,
    backfill_step_seconds: backfillStepSeconds,
  });
}

function postSignedJson(url, payload, credentials) {
  const body = JSON.stringify(payload);
  const signedHeaders = sigV4Headers("POST", url, body, {
    "content-type": "application/json",
    "x-tenant-id": payload.tenant_id,
    "x-correlation-id": payload.correlation_id,
  }, credentials);

  return http.post(url, body, {
    headers: signedHeaders,
    timeout: "10s",
  });
}

function sigV4Headers(method, requestUrl, body, headers, credentials) {
  const parsed = parseUrl(requestUrl);
  const amzDate = toAmzDate(new Date());
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = crypto.sha256(body, "hex");

  const canonicalHeaders = {};
  for (const headerName of Object.keys(headers)) {
    canonicalHeaders[headerName] = headers[headerName];
  }
  canonicalHeaders.host = parsed.host;
  canonicalHeaders["x-amz-content-sha256"] = payloadHash;
  canonicalHeaders["x-amz-date"] = amzDate;

  if (credentials.sessionToken) {
    canonicalHeaders["x-amz-security-token"] = credentials.sessionToken;
  }

  const sortedHeaderNames = Object.keys(canonicalHeaders).map((h) => h.toLowerCase()).sort();
  const canonicalHeaderString = sortedHeaderNames
    .map((name) => `${name}:${String(canonicalHeaders[name]).trim().replace(/\s+/g, " ")}`)
    .join("\n") + "\n";
  const signedHeaders = sortedHeaderNames.join(";");
  const credentialScope = `${dateStamp}/${awsRegion}/execute-api/aws4_request`;
  const canonicalRequest = [
    method,
    parsed.path,
    parsed.query,
    canonicalHeaderString,
    signedHeaders,
    payloadHash,
  ].join("\n");
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    crypto.sha256(canonicalRequest, "hex"),
  ].join("\n");
  const signingKey = getSignatureKey(credentials.secretAccessKey, dateStamp, awsRegion, "execute-api");
  const signature = crypto.hmac("sha256", signingKey, stringToSign, "hex");

  const signedRequestHeaders = {};
  for (const headerName of Object.keys(canonicalHeaders)) {
    signedRequestHeaders[headerName] = canonicalHeaders[headerName];
  }
  signedRequestHeaders.Authorization = `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  return signedRequestHeaders;
}

function getSignatureKey(secretAccessKey, dateStamp, region, service) {
  const kDate = crypto.hmac("sha256", `AWS4${secretAccessKey}`, dateStamp, "binary");
  const kRegion = crypto.hmac("sha256", kDate, region, "binary");
  const kService = crypto.hmac("sha256", kRegion, service, "binary");
  return crypto.hmac("sha256", kService, "aws4_request", "binary");
}

function loadAwsCredentials() {
  if (__ENV.AWS_ACCESS_KEY_ID && __ENV.AWS_SECRET_ACCESS_KEY) {
    return {
      accessKeyId: __ENV.AWS_ACCESS_KEY_ID,
      secretAccessKey: __ENV.AWS_SECRET_ACCESS_KEY,
      sessionToken: __ENV.AWS_SESSION_TOKEN || "",
    };
  }

  const relativeUri = __ENV.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
  const fullUri = __ENV.AWS_CONTAINER_CREDENTIALS_FULL_URI;
  const credentialsUrl = fullUri || (relativeUri ? `http://169.254.170.2${relativeUri}` : "");
  if (!credentialsUrl) {
    return {};
  }

  const headers = {};
  if (__ENV.AWS_CONTAINER_AUTHORIZATION_TOKEN) {
    headers.Authorization = __ENV.AWS_CONTAINER_AUTHORIZATION_TOKEN;
  }

  const response = http.get(credentialsUrl, { headers, timeout: "2s" });
  if (response.status !== 200) {
    throw new Error(`Unable to load ECS task role credentials: HTTP ${response.status}`);
  }

  const body = response.json();
  return {
    accessKeyId: body.AccessKeyId,
    secretAccessKey: body.SecretAccessKey,
    sessionToken: body.Token || "",
  };
}

function calculateMetricValue(scenario, serviceId, metricType, elapsedMinutes) {
  const base = (baselines[serviceId] || baselines["payment-gw"])[metricType];
  let value = base * (1.0 + randomBetween(-0.05, 0.05));
  const anomalyElapsedMinutes = elapsedMinutes - anomalyStartSeconds / 60.0;
  const isAnomalyPhase = anomalyElapsedMinutes >= 0.0;

  if (!isAnomalyPhase && scenario !== "noisy_baseline") {
    return Number(value.toFixed(2));
  }

  if (scenario === "gradual_drift") {
    value = metricType === "cache_hit_rate_pct"
      ? base * (1.0 - 0.0008 * anomalyElapsedMinutes)
      : base * (1.0 + 0.0025 * anomalyElapsedMinutes);
  } else if (scenario === "sudden_spike") {
    const cycleMinute = anomalyElapsedMinutes % 30.0;
    if (cycleMinute >= 15.0 && cycleMinute < 20.0) {
      if (metricType === "cache_hit_rate_pct") {
        value = base * 0.35;
      } else if (metricType === "queue_depth") {
        value = base * 8.0 + 450.0;
      } else {
        value = base * 3.8;
      }
    }
  } else if (scenario === "slow_leak" && metricType === "memory_usage_percent") {
    value = base + 0.12 * anomalyElapsedMinutes;
  }

  if (percentageMetricTypes.includes(metricType)) {
    value = Math.min(percentCapForScenario(scenario), Math.max(0.0, value));
  } else {
    value = Math.max(0.0, value);
  }

  return Number(value.toFixed(2));
}

function percentCapForScenario(scenario) {
  return scenario === "gradual_drift" ? 92.0 : 100.0;
}

function metricLabels(serviceId, metricType, scenario) {
  const labels = {
    region: awsRegion,
    environment: "sandbox",
    scenario,
  };

  if (metricType === "db_connection_pool_pct") {
    labels.db_type = "postgres";
  } else if (metricType === "queue_depth") {
    labels.queue_name = `${serviceId}-events`;
  } else if (metricType === "cache_hit_rate_pct") {
    labels.cache_type = "redis";
  }

  return labels;
}

function selectScenarios(scenario, scenarioList) {
  if (scenario && scenario !== "all") {
    if (!VALID_SCENARIOS.includes(scenario)) {
      throw new Error(`Unsupported SCENARIO '${scenario}'. Expected one of: ${VALID_SCENARIOS.join(", ")}`);
    }
    return [scenario];
  }

  const parsed = parseCsv(scenarioList).filter((s) => VALID_SCENARIOS.includes(s));
  if (parsed.length === 0) {
    return ["noisy_baseline"];
  }
  return scenario === "all" ? parsed : [parsed[0]];
}

function parseCsv(value) {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function parseNonNegativeInt(value, fallback) {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function parseBoolean(value, fallback) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  return ["1", "true", "yes", "y"].includes(String(value).trim().toLowerCase());
}

function parseUrl(value) {
  const match = value.match(/^https?:\/\/([^/]+)([^?]*)(?:\?(.*))?$/);
  if (!match) {
    throw new Error(`Invalid URL: ${value}`);
  }
  return {
    host: match[1],
    path: encodeCanonicalPath(match[2] || "/"),
    query: canonicalQuery(match[3] || ""),
  };
}

function encodeCanonicalPath(path) {
  return path.split("/").map((part) => encodeURIComponent(decodeURIComponent(part))).join("/");
}

function canonicalQuery(query) {
  if (!query) {
    return "";
  }
  return query
    .split("&")
    .map((part) => {
      const [key, value = ""] = part.split("=");
      return `${encodeURIComponent(decodeURIComponent(key))}=${encodeURIComponent(decodeURIComponent(value))}`;
    })
    .sort()
    .join("&");
}

function toAmzDate(date) {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

function randomBetween(min, max) {
  return min + Math.random() * (max - min);
}

function uuidv4() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
    const random = Math.floor(Math.random() * 16);
    const value = char === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

function log(event, fields) {
  const record = {
    ts: new Date().toISOString(),
    component: "k6-generator",
    event,
  };
  for (const fieldName of Object.keys(fields || {})) {
    if (fields[fieldName] !== undefined) {
      record[fieldName] = fields[fieldName];
    }
  }
  console.log(JSON.stringify(record));
}
