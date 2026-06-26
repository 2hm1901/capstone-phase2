# Thiết kế kiến trúc - CDO08 Task Force 4

**Status:** Draft W11  
**Last updated:** 2026-06-25

---

## 1. Luồng dữ liệu tổng quan

```
[Payment / Gateway / Queue-worker]
        │ (push metrics)
        ▼
   VPC Endpoint
        │
        ▼
  API Gateway ──► Lambda Ingest ──► SQS ──► Lambda Writer ──► AMP
                       │                        │
                    (reject)                  (fail)
                       ▼                        ▼
                      DLQ                      DLQ


EventBridge (schedule mỗi 5 phút)
        │
        ▼
Lambda Prediction ──► query AMP (PromQL window ≥120 phút)
        │
        ▼
Lambda Serving Adapter ──► AI Service (ECS Fargate, qua ALB)
        │                        │
        │◄────────────────────── (kết quả)
        │
        ├── [AI OK]  ──► tạo Grafana annotation + audit DynamoDB
        │
        └── [AI lỗi] ──► Lambda Fallback
                              │
                              ├── static threshold evaluation
                              ├── Grafana annotation (label: fallback=true)
                              └── audit DynamoDB (fallback=true)
```

---

## 2. Chi tiết từng thành phần

### 2.1 Ingest Layer

**Services → VPC Endpoint → API Gateway → Lambda Ingest**

Ba service (Payment, Gateway, Queue-worker) chạy trên ECS Fargate trong private subnet. Metrics được push ra ngoài qua VPC Endpoint, vào API Gateway, rồi Lambda Ingest xử lý.

Lambda Ingest validate các field bắt buộc:

| Field            | Mô tả                              |
| ---------------- | ---------------------------------- |
| `tenant_id`      | Phải khớp với `X-Tenant-Id` header |
| `service_id`     | Phải nằm trong whitelist           |
| `metric_type`    | Phải nằm trong whitelist 7 metrics |
| `ts`             | Timestamp hợp lệ                   |
| `value`          | Numeric, trong range hợp lệ        |
| `schema_version` | Phải đúng version hiện tại         |
| `correlation_id` | Bắt buộc để trace E2E              |

Event hợp lệ → SQS. Event sai schema → DLQ để điều tra và replay.

**Lý do có validation layer:** OTEL Collector push thẳng AMP không chặn được unknown labels. Một developer vô tình thêm `user_id` hoặc `request_id` vào metric sẽ gây cardinality explosion — số time series tăng theo cấp số nhân, làm AMP bill tăng đột biến và AI engine query ra noise thay vì signal sạch. Lambda Ingest với metric whitelist là lớp bảo vệ allowlist, chặn từ đầu trước khi data vào storage.

**7 metric_type được phép:**

- `cpu_usage_percent`
- `memory_usage_percent`
- `active_connections`
- `db_connection_pool_pct`
- `queue_depth`
- `cache_hit_rate_pct`
- `api_latency_ms`

---

### 2.2 Buffer Layer

**SQS Standard + DLQ**

Tách producer (Lambda Ingest) khỏi consumer (Lambda Writer). Khi Lambda Writer hoặc AMP lỗi tạm thời, event được giữ trong SQS, không bị mất âm thầm.

- **SQS Standard:** at-least-once delivery, Lambda Writer phải idempotent
- **DLQ:** nhận event sau N lần retry thất bại — alarm bắt buộc khi DLQ depth tăng
- **Queue age alarm:** phát hiện writer bị stuck

---

### 2.3 Writer Layer

**Lambda Writer → AMP (remote-write)**

Lambda Writer đọc batch từ SQS, chuyển JSON telemetry thành Prometheus remote-write payload (protobuf + snappy compression), ký request bằng AWS SigV4, ghi vào AMP.

Mỗi record được xử lý độc lập — partial batch response để một record lỗi không block cả batch.

---

### 2.4 Prediction Layer

**EventBridge → Lambda Prediction → Lambda Serving Adapter → AI Service**

EventBridge Scheduler chạy 3 schedule mỗi 5 phút, lệch nhau 1-2 phút, mỗi schedule mang payload `tenant_id`, `service_id`, `lookback_minutes`.

Lambda Prediction:

1. Query AMP bằng PromQL lấy window ≥120 phút cho service tương ứng
2. Map metric thành `signal_window` theo AI contract
3. Forward tới Lambda Serving Adapter

Lambda Serving Adapter:

1. Check circuit breaker state trong DynamoDB
2. Nếu circuit CLOSED → gọi AI Service qua ALB (SigV4, header `X-Tenant-Id`)
3. Nhận kết quả, trả về Lambda Prediction

Lambda Prediction nhận kết quả cuối cùng:

- Tạo Grafana annotation (service, drift, confidence, action, evidence link)
- Ghi audit record vào DynamoDB

---

### 2.5 AI Service

**ECS Fargate FastAPI, private subnet, qua internal ALB**

- Đọc baseline từ S3 (upload tay hàng tuần)
- Nhận `POST /v1/predict` với `signal_window`
- Chạy thuật toán anomaly detection
- Trả về drift detection + capacity recommendation

ECR lưu image AI Service. Baseline được load từ S3 lúc runtime.

---

### 2.6 Circuit Breaker

**State lưu trong DynamoDB, Lambda Serving Adapter quản lý**

Ba state:

```
CLOSED ──(N lần fail liên tiếp)──► OPEN ──(sau X phút)──► HALF-OPEN
  ▲                                                              │
  └──────────────(1 request thành công)────────────────────────┘
```

Schema DynamoDB:

```json
{
  "service_id": "payment-api",
  "state": "OPEN",
  "fail_count": 5,
  "last_failed_at": "2026-06-25T10:00:00Z",
  "retry_after": "2026-06-25T10:05:00Z"
}
```

Khi circuit OPEN → Lambda Serving Adapter không gọi AI, route thẳng sang Lambda Fallback.

Khi HALF-OPEN → cho 1 request qua AI thử:

- Thành công → về CLOSED, reset `fail_count`
- Fail → về OPEN, cập nhật `retry_after`

---

### 2.7 Fallback Layer

**Lambda Fallback → static threshold → Grafana annotation + DynamoDB audit**

Chạy khi AI Service trả 429/503, timeout, hoặc circuit breaker OPEN.

- Đọc metric gần nhất từ AMP
- So sánh với static threshold per service
- Tạo Grafana annotation có label `fallback=true`
- Ghi audit record với `fallback=true` để phân biệt với prediction thật

Đây là hard requirement fail-open: khi AI down, alert vẫn hoạt động.

---

### 2.8 Audit & Storage

**DynamoDB SSE-KMS, TTL**

Mỗi prediction call (AI hoặc fallback) ghi một audit record:

| Field            | Mô tả                              |
| ---------------- | ---------------------------------- |
| `correlation_id` | Trace E2E từ ingest đến annotation |
| `tenant_id`      | Tenant context                     |
| `service_id`     | Service được predict               |
| `ts`             | Timestamp của prediction           |
| `result`         | Kết quả AI hoặc fallback           |
| `fallback`       | `true` nếu dùng fallback           |
| `circuit_state`  | State của circuit breaker lúc gọi  |

Partition key: `tenant_id#service_id`. `correlation_id` là indexed attribute để lookup E2E.

---

### 2.9 Security

| Component        | Cơ chế                                                    |
| ---------------- | --------------------------------------------------------- |
| AI Service auth  | IAM SigV4, header `X-Tenant-Id` bắt buộc                  |
| Secrets          | Secrets Manager + KMS                                     |
| Audit encryption | DynamoDB SSE-KMS                                          |
| AMP encryption   | At rest mặc định                                          |
| Cross-tenant     | Lambda Ingest reject khi `X-Tenant-Id` không khớp payload |
| CloudTrail       | Audit API calls                                           |

---

### 2.10 Observability

- **CloudWatch Logs/Metrics/Alarms:** ingest error, DLQ depth, queue age, Lambda error, fallback rate, circuit breaker state
- **AMP:** telemetry time series, query bằng PromQL
- **Amazon Managed Grafana:** dashboard metric + annotation prediction/fallback

---

## 3. Failure modes

| Failure                          | Detection                           | Recovery                               |
| -------------------------------- | ----------------------------------- | -------------------------------------- |
| Event sai schema                 | Lambda Ingest validation metric     | Reject → DLQ → replay sau khi fix      |
| Lambda Writer / AMP lỗi tạm thời | Queue age alarm, remote-write error | SQS retry tự động                      |
| AI Service 429/503/timeout       | HTTP error metric, circuit breaker  | Fallback static threshold              |
| Circuit OPEN kéo dài             | CloudWatch alarm fallback rate      | CDO08 rollback ECS, báo AI owner       |
| DLQ tăng                         | DLQ depth alarm                     | Điều tra poison event, replay thủ công |
| Grafana annotation API lỗi       | Integration error log               | Retry bounded, audit record giữ lại    |
| Audit write lỗi                  | DynamoDB error alarm                | Retry, đánh dấu E2E incomplete         |

---

## 4. Luồng deploy AI Service

```
AI team bàn giao artifact/spec
        │
        ▼
CDO08 build Docker image → push lên ECR
        │
        ▼
Upload baseline lên S3 (tay, hàng tuần)
        │
        ▼
ECS Fargate deploy image từ ECR
AI Service load baseline từ S3 lúc startup
        │
        ▼
Smoke test: POST /v1/predict với fixture data
Verify: annotation + audit record tạo thành công
```

---

## 5. Điểm differentiate so với CDO khác

**Validation trước storage:** unknown labels bị chặn tại Lambda Ingest trước khi vào AMP. OTEL push thẳng AMP không có lớp bảo vệ này — một label sai như `user_id` hay `request_id` gây cardinality explosion, AMP bill tăng không kiểm soát và AI engine nhận noise thay vì signal sạch.

**Circuit breaker có state:** không chỉ retry đơn giản — có CLOSED/OPEN/HALF-OPEN với TTL, tránh retry storm khi AI down kéo dài.

**Correlation ID xuyên suốt:** từ ingest event đến AMP đến prediction đến Grafana annotation đến audit record — một `correlation_id` trace được toàn bộ E2E.

**Fail-open có label:** fallback annotation có label `fallback=true` rõ ràng, phân biệt với prediction thật trên dashboard, không claim AI predict khi thực ra dùng static threshold.
