# AI API Contract - Task force 4

<!-- Owner: AIO-03
     Signed by: AI Lead + CDO Leads × 2-3 + Reviewer panel
     Date signed: 2026-06-25 (W11 T5)
     🔒 FREEZE - no change without formal change request -->

## Mục đích

Định nghĩa **API endpoints** mà Nhóm AI expose, Nhóm CDO consume. Là service contract giữa AI engine và platform infra.

> **⚠️ CAPSTONE PHASED DELIVERY NOTE:**
> - **W11 (Mock Integration Phase):** AI team deploy một **Skeleton Endpoint** (dummy logic trả về hardcoded JSON).
> - **W12 (Final Build Phase):** AI team bàn giao artifact và deployment contract cho engine chứa thuật toán thực tế. API Schema ở hai giai đoạn là **như nhau**, CDO không cần sửa code khi chuyển từ W11 sang W12.

## Versioning

- **Current version**: `v1.0` (in path `/v1/`)
- **Breaking changes** → new version path `/v2/`, both versions support cùng lúc tối thiểu 30 ngày
- **Non-breaking** (add optional field, add new endpoint) → minor bump, no path change

## Authentication

- **Inter-service**: IAM SigV4 (no API keys). *Lưu ý Capstone: Trong giai đoạn W11 Mock Testing, `Authorization` header là **TÙY CHỌN (Optional)** để CDO dễ dàng test curl/Postman public. Từ W12 Final Build, IAM SigV4 sẽ bị **ENFORCE** nghiêm ngặt.*
- **Cross-account**: STS assume-role với session tag `tenant_id`
- **Audit**: every auth event logged

## Rate limiting

- **Per tenant**: 600 requests/minute (config trong API Gateway usage plan)
- **Global**: 6000 requests/minute (circuit breaker nếu vượt)
- **Response on hit**: `429` với header `Retry-After: <seconds>`

---

## Endpoint 1: `POST /v1/predict`

**Mục đích**: detect anomaly + suggest action từ telemetry signals.

### Request headers

| Header | Type | Required | Description |
|---|---|---|---|
| `X-Tenant-Id` | string | ✓ | Tenant identifier (e.g. tnt-abc123) |
| `Authorization` | IAM SigV4 | ✓ | Inter-service auth |
| `X-Correlation-Id` | UUID | optional | Trace correlation (auto-generated nếu thiếu) |

### Request body

| Field | Type | Required | Description |
|---|---|---|---|
| `signal_window` | array | ✓ | Time-series datapoints (BẮT BUỘC chứa dữ liệu của ≥ 120 phút gần nhất để AI có đủ context dự báo (Test window ≥ 2h). Thiếu -> 400 Bad Request) |
| `signal_window[].ts` | RFC3339 | ✓ | Event timestamp UTC |
| `signal_window[].tenant_id` | string | ✓ | Tenant identifier (Bắt buộc để đảm bảo multi-tenant isolation, phải match với header X-Tenant-Id) |
| `signal_window[].service_id` | string | ✓ | Service identifier (Bắt buộc để mapping với per-service baseline) |
| `signal_window[].metric_type` | string | ✓ | Tên loại metric (e.g. cpu_usage_percent) |
| `signal_window[].value` | float | ✓ | Measurement value |
| `signal_window[].labels` | object | optional | Additional context labels. |
| `context.deployment_version` | string | ✓ | Current deploy SHA hoặc version tag |
| `context.time_range.start_ts` | RFC3339 | ✓ | Analysis window start |
| `context.time_range.end_ts` | RFC3339 | ✓ | Analysis window end |

**Request example**:

```json
{
  "signal_window": [
    {"ts": "2026-06-25T10:00:00Z", "tenant_id": "tenant-cdo-demo", "service_id": "payment-gw", "metric_type": "api_latency_ms", "value": 1200},
    {"ts": "2026-06-25T10:01:00Z", "tenant_id": "tenant-cdo-demo", "service_id": "payment-gw", "metric_type": "api_latency_ms", "value": 1800}
  ],
  "context": {
    "deployment_version": "v2.3.1",
    "time_range": {
      "start_ts": "2026-06-25T09:55:00Z",
      "end_ts": "2026-06-25T10:01:00Z"
    }
  }
}
```

### Response body

| Field | Type | Description |
|---|---|---|
| `anomaly` | bool | True nếu detect anomaly |
| `severity` | float 0.0-1.0 | Severity score |
| `recommendation.action_verb` | enum | `["SCALE_UP", "INVESTIGATE"]` |
| `recommendation.target` | string | Target resource (e.g., "payment-gw ECS Service") |
| `recommendation.from_to` | string | State transition (e.g., "3 tasks -> 5 tasks") |
| `recommendation.confidence` | float 0.0-1.0 | Model confidence - CDO dùng cho gating |
| `recommendation.evidence_link` | string | URL tới dashboard hoặc log query chứng minh |
| `reasoning` | string (≤300 chars) | Human-readable rationale |
| `audit_id` | UUID | Reference cho audit trail lookup |

**Response example**:

```json
{
  "anomaly": true,
  "severity": 0.78,
  "recommendation": {
    "action_verb": "SCALE_UP",
    "target": "payment-gw ECS Service",
    "from_to": "Current -> +2 Tasks",
    "confidence": 0.82,
    "evidence_link": "https://dashboard.internal/metrics/payment-gw/cpu"
  },
  "reasoning": "CPU drift detected. Scale ECS Service cho payment-gw.",
  "audit_id": "audit-xyz789"
}
```

### Audit Log Schema (Internal AI Engine)

Mỗi request tới `POST /v1/predict` bắt buộc phải được ghi log (Audit) với tối thiểu 6 trường dữ liệu, lưu trữ **Encrypted at Rest** (KMS AWSManagedKey) với **Retention 1 năm** (365 ngày, theo sàn PCI-DSS/SOC2; archive dài hạn hơn → S3 + Glacier):
1. `audit_id`: UUID map với response trả về cho CDO.
2. `timestamp`: Thời điểm request đến.
3. `tenant_id`: ID của service yêu cầu.
4. `principal_id`: IAM Role ARN gọi API.
5. `input_hash`: Mã băm SHA-256 của `signal_window` để verify data integrity.
6. `recommendation_snapshot`: Bản copy chính xác quyết định scale (action_verb + from_to) do AI đưa ra.

### SLA

| Metric | Target |
|---|---|
| P99 latency | < 500 ms |
| Throughput | 100 RPS |
| Availability | 99.5% |

### Error codes

| Code | Meaning | CDO action |
|---|---|---|
| `400` | Invalid input schema | Fix client code, KHÔNG retry |
| `401` | Auth failed | Refresh credential, retry once |
| `429` | Rate-limited | Exponential backoff (1s → 2s → 4s ...) |
| `503` | AI engine unavailable | Fallback to rule-based alert (CDO **bắt buộc** có fallback path) |
