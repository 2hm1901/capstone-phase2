# Telemetry Contract - Task force 4

<!-- Owner: AIO-03
     Signed by: AI Lead + CDO Leads × 2-3 + Reviewer panel
     Date signed: 2026-06-25 (W11 T5)
     🔒 FREEZE - no change without formal change request -->

## Mục đích

Định nghĩa **signals nào CDO emit từ infra** → AI engine consume để dự đoán Capacity Exhaustion. Là handshake giữa platform layer (CDO) và intelligence layer (AI).

## Versioning

- **Current version**: `v1.0`
- **Evolution**: backward-compatible additions only. Breaking change → new contract version + migration window
- **Change request process**: raise trong nhóm task force → họp bàn → bump version + notify all

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "fraud-detection",
  "metric_type": "cache_hit_rate_pct",
  "value": 45.5,
  "labels": {"cache_type": "redis", "region": "ap-southeast-1"}
}
```

---

## Signals required

> List signals AI engine cần để analyze. Hệ thống Foresight Lens sử dụng mảng dữ liệu (Rolling Window) để phát hiện bất thường dựa trên thuật toán thống kê (EWMA & STL Decomposition).

> **Ý nghĩa "Volume SLA = 50.000 events/sec peak"** (1 event = 1 datapoint `{ts, tenant_id, service_id, metric_type, value}`):
> - Đây là **trần throughput ingest đỉnh mà đường ống telemetry (phía CDO) được thiết kế để chịu**, KHÔNG phải tần suất gọi `/v1/predict` của AI engine (engine chỉ nhận window đã gom, ~vài request/phút).
> - **Cardinality model cho 50k/s peak** (Black Friday): 50k/s đạt được khi cardinality cao — mỗi metric tách theo chiều phụ `instance_id × endpoint × AZ`. Ví dụ ~3M time-series ở 1 phút/lần, hoặc sub-second sampling trên tier-1 hot path. Đây là **design ceiling** để CDO chọn hạ tầng ingest (TSDB/streaming Kinesis-MSK) không vỡ khi traffic 9k RPS Black Friday.
> - **Demo scope thực tế** (capstone, 3 tier-1 service × signal chính, 1 phút/lần): chỉ ~**tens of events/sec**. 50k/s là trần năng lực, không phải tải demo. Engine + eval chạy trên window đã gom nên không phụ thuộc con số này.

### Signal 1: `cpu_usage_percent`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, region, tenant_id (mandatory) |
| **Unit** | percentage (0-100) |
| **Frequency** | 1 phút |
| **Emit point** | CloudWatch Metrics → CDO Ingestion → AI API |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Phát hiện xu hướng tăng đột biến CPU |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example** (concrete JSON payload AI nhận được):

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "payment-gateway",
  "metric_type": "cpu_usage_percent",
  "value": 85.5,
  "labels": {"region": "ap-southeast-1"}
}
```

### Signal 2: `memory_usage_percent`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, region, tenant_id (mandatory) |
| **Unit** | percentage (0-100) |
| **Frequency** | 1 phút |
| **Emit point** | CloudWatch Metrics → CDO Ingestion → AI API |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Dự đoán Memory Leak dẫn tới OOM (Out Of Memory) |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "payment-gateway",
  "metric_type": "memory_usage_percent",
  "value": 72.1,
  "labels": {"region": "ap-southeast-1"}
}
```

### Signal 3: `active_connections`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, region, tenant_id (mandatory) |
| **Unit** | count |
| **Frequency** | 1 phút |
| **Emit point** | ALB (Application Load Balancer) metrics |
| **Used for** | Correlate giữa traffic spike và resource exhaustion |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "payment-gateway",
  "metric_type": "active_connections",
  "value": 4500.0,
  "labels": {"region": "ap-southeast-1"}
}
```

### Signal 4: `db_connection_pool_pct`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, db_type (e.g. postgres, mysql), region, tenant_id |
| **Unit** | percentage (0-100) |
| **Frequency** | 1 phút |
| **Emit point** | RDS CloudWatch Metrics → CDO Ingestion → AI API |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Phát hiện cạn kiệt Connection Pool của Database do slow queries hoặc Cache Stampede |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "payment-gateway",
  "metric_type": "db_connection_pool_pct",
  "value": 95.0,
  "labels": {"db_type": "postgres", "region": "ap-southeast-1"}
}
```

### Signal 5: `queue_depth`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, queue_name, region, tenant_id |
| **Unit** | count |
| **Frequency** | 1 phút |
| **Emit point** | SQS CloudWatch Metrics → CDO Ingestion → AI API |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Đo lường mức độ nghẽn cổ chai (backlog) của worker consuming message (ví dụ Ledger worker) |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "ledger-service",
  "metric_type": "queue_depth",
  "value": 15000.0,
  "labels": {"queue_name": "ledger-events-sqs", "region": "ap-southeast-1"}
}
```

### Signal 6: `cache_hit_rate_pct`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, cache_type (e.g. redis), region, tenant_id |
| **Unit** | percentage (0-100) |
| **Frequency** | 1 phút |
| **Emit point** | ElastiCache CloudWatch Metrics → CDO Ingestion → AI API |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Phát hiện Cache Miss Spike dẫn đến quá tải trực tiếp xuống RDS |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "fraud-detection",
  "metric_type": "cache_hit_rate_pct",
  "value": 45.5,
  "labels": {"cache_type": "redis", "region": "ap-southeast-1"}
}
```


---

### Signal 7: `api_latency_ms`

| Attribute | Value |
|---|---|
| **Type** | gauge |
| **Labels** | service_id, region, tenant_id (mandatory) |
| **Unit** | milliseconds |
| **Frequency** | 1 phút |
| **Emit point** | ALB (Application Load Balancer) metrics |
| **Retention** | 7 ngày hot + 83 ngày cold (tổng 90 ngày minimum) |
| **Used for** | Leading indicator cho connection pool exhaustion hoặc memory leak (latency thường tăng dần 15-30 phút trước khi SLO breach) |
| **Emit SLA** | p99 latency < 60s từ lúc phát sinh metric |
| **Volume SLA** | 50,000 events/sec peak (đáp ứng requirement TF4 Learner) |
| **Cost estimate** | ~$3.5/tháng (Lưu trữ nén trên Amazon Timestream hoặc Managed Prometheus) |

**Schema example**:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tnt-abc123",
  "service_id": "payment-gateway",
  "metric_type": "api_latency_ms",
  "value": 450.5,
  "labels": {"region": "ap-southeast-1"}
}
```

## Cross-cutting requirements

Mọi signal phải comply:
- **Tenant scoping**: mọi signal payload **bắt buộc** có `tenant_id` field - AI engine không accept signal thiếu tenant_id.
- **Time precision**: timestamp RFC3339 UTC, millisecond precision.
- **Schema validation**: AI ingestion layer (Pydantic) validate schema; reject malformed.
- **Data Alignment & Imputation**: Time buckets gửi vào API phải liền mạch. Nếu hạ tầng bị đứt gãy (Network jitter hoặc Drop metric), CDO **bắt buộc** phải tiền xử lý (Forward-fill hoặc Zero-fill). AI Engine sẽ văng lỗi `400` nếu phát hiện time-series bị thủng.
- **PII**: KHÔNG được chứa PII (email, phone, name) trong signal value hoặc labels.

> **Baseline coverage (Pack #1)**: AI engine train per-service STL baseline cho 4 signal chính
> (`cpu_usage_percent`, `memory_usage_percent`, `api_latency_ms`, `queue_depth`). Các signal còn
> lại (`active_connections`, `db_connection_pool_pct`, `cache_hit_rate_pct`) dùng fallback z-score
> in-window khi chưa có baseline; bổ sung baseline trong W12 nếu cần.
