# [TF4][W11] Nam - Telemetry Writer + Primary Telemetry Store + AMP Security

**Người phụ trách:** Nam Hoang
**Ngày:** `2026-06-25`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Nam phụ trách ba phần liên quan trực tiếp đến telemetry platform của CDO08:

- **Primary Telemetry Store:** chọn nơi lưu metric chính cho hệ thống.
- **Telemetry Writer:** chọn cách đọc telemetry event từ buffer và ghi metric vào store.
- **AMP Security Input:** bổ sung security guardrail cho AMP và Writer Lambda.

Nói đơn giản, **AMP là nơi lưu metric để AI/Grafana query lại theo thời gian**. **Lambda Writer là bước chuyển telemetry event trong SQS thành metric** để ghi vào AMP. Phần security đảm bảo chỉ đúng component được ghi/đọc metric và dữ liệu nhạy cảm không bị đưa vào label hoặc log.

Timestream LiveAnalytics ban đầu phù hợp về mặt concept vì là time-series database của AWS. Tuy nhiên, account capstone hiện tại không access được Timestream LiveAnalytics cho new customer, nên option này bị loại khỏi implementation path. AMP được chọn thay thế vì là managed Prometheus, phù hợp với infra metrics, PromQL sliding window query, Grafana integration và retention đáp ứng yêu cầu ≥90 ngày.

Telemetry Writer dùng Lambda vì workload hiện tại là event-driven: event hợp lệ đi vào SQS, Writer đọc theo batch, transform JSON telemetry thành Prometheus-compatible metric, rồi remote-write vào AMP. Rủi ro chính là Lambda phải xử lý remote-write format, compression và AWS SigV4 signing, nên cần POC trước khi lock implementation. Nếu POC direct Lambda → AMP không ổn định hoặc mất nhiều thời gian, fallback là dùng ECS/Fargate + ADOT Collector làm adapter remote-write.

Security input tập trung vào least privilege, label/cardinality guardrail, encryption, SigV4, secret-free logs và negative tests. Writer Lambda chỉ được đọc telemetry SQS queue và `aps:RemoteWrite` vào đúng AMP workspace. Prediction Lambda và Grafana chỉ được query AMP, không có quyền ghi metric. `correlation_id`, `request_id`, `event_id` không được dùng làm AMP label vì sẽ tạo high-cardinality series, tăng cost và làm query chậm.

Recommendation cuối:

```text
Primary path:
API Gateway → Ingest Lambda → SQS → Lambda Writer → AMP → Prediction Lambda/Grafana

Fallback path nếu remote-write POC fail:
API Gateway → Ingest Lambda → SQS → Lambda Writer → ADOT Collector → AMP
```

---

## 2. Requirement từ đề bài / contract

Nói thực tế, hệ thống cần lưu metric đủ lâu, query nhanh theo service và lấy được dữ liệu gần nhất cho AI. Vì vậy chỉ lưu file raw trên S3 là chưa đủ cho đường realtime; cần một telemetry store có thể query time-series trực tiếp.

| Nguồn yêu cầu         | Nội dung liên quan                                                   | Ý nghĩa thực tế                                                                                                        |
| --------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| TF4 learner brief     | Telemetry retention ≥90 ngày, query time-series theo service/metric  | Cần primary telemetry store thật, query được metric theo thời gian; raw S3 không đủ làm primary store                  |
| TF4 learner brief     | Raw S3 không là primary store                                        | S3 có thể dùng cho archive/offline analysis, nhưng không phù hợp làm store chính cho realtime/sliding-window detection |
| Telemetry Contract    | Metric có `tenant_id`, `service_id`, `metric_type`, timestamp, value | Store/query phải hỗ trợ filter theo tenant/service/metric type                                                         |
| Telemetry Contract    | Frequency khoảng 1 phút cho metric                                   | Writer/store phải xử lý sample định kỳ ổn định, không cần per-request ingestion quá dày                                |
| AI API Contract       | Prediction cần metric lookback window ≥120 phút                      | AMP phải query được range window bằng PromQL, ví dụ 120 phút gần nhất theo service                                     |
| CDO08 infra design    | AMP thay Timestream; Writer Lambda remote-write                      | Cần validate technical feasibility bằng POC remote-write, PromQL query và Grafana datasource                           |
| CDO08 security design | IAM remote-write/query AMP, cardinality guardrail                    | Cần tách quyền Writer/Prediction/Grafana, tránh label high-cardinality và secret leak                                  |
| Budget constraint     | Platform forecast < $200/tháng                                       | Tránh option có fixed cost cao như managed InfluxDB instance lớn hoặc self-managed stack phức tạp                      |

Tóm tắt requirement theo ngôn ngữ implementation:

```text
Need:
- Lưu metric tối thiểu 90 ngày
- Query theo tenant_id/service_id/metric_type
- AI query được window 120 phút
- Grafana đọc được metric
- Writer có retry/DLQ/partial failure
- Security có IAM least privilege, no secret in logs, no high-cardinality labels
- Cost nằm trong capstone budget
```

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

Flow tổng thể liên quan đến phần Nam:

```text
Synthetic generator / demo services
        ↓
API Gateway
        ↓
Ingest Lambda
        ↓
SQS Queue
        ↓
Lambda Writer
        ↓
Amazon Managed Service for Prometheus (AMP)
        ↓
Prediction Lambda / Grafana
```

Trong flow này, phần Nam tập trung vào đoạn:

```text
SQS Queue
        ↓
Lambda Writer
        ↓
AMP
        ↓
Prediction Lambda / Grafana
```

### 3.2 Nó chịu trách nhiệm gì?

**Primary Telemetry Store / AMP** chịu trách nhiệm:

- Lưu metric theo time-series model.
- Cho phép query bằng PromQL theo `tenant_id`, `service_id`, `metric_type` và time window.
- Cung cấp dữ liệu cho Prediction Lambda và Grafana.
- Duy trì retention đáp ứng yêu cầu ≥90 ngày.

**Telemetry Writer Lambda** chịu trách nhiệm:

- Đọc event hợp lệ từ SQS theo batch.
- Parse JSON telemetry event.
- Validate các field/label quan trọng trước khi ghi metric.
- Transform JSON telemetry thành Prometheus metric sample logic.
- Remote-write metric vào AMP.
- Xử lý retry, partial failure, duplicate/idempotency và DLQ.
- Ghi metric/log vận hành như success/error/duration/batch result.

Giải thích nhanh các từ kỹ thuật trong Writer:

| Thuật ngữ       | Nghĩa trong task này                                                         |
| --------------- | ---------------------------------------------------------------------------- |
| Parse           | Đọc message JSON từ SQS                                                      |
| Validate        | Kiểm tra field bắt buộc và label có nằm trong whitelist không                |
| Transform       | Đổi JSON thành metric name + labels + value + timestamp                      |
| Remote-write    | Gửi metric vào AMP theo chuẩn Prometheus                                     |
| Partial failure | Một batch có vài message lỗi thì chỉ retry message lỗi, không retry cả batch |
| Idempotency     | Retry không làm dữ liệu bị duplicate mất kiểm soát                           |

Flow Writer dễ hiểu:

```text
SQS telemetry event JSON
        ↓
Lambda Writer read batch
        ↓
Validate required fields and allowed labels
        ↓
Map JSON → metric name + labels + value + timestamp
        ↓
Remote-write to AMP
        ↓
Delete success messages / retry failed messages
```

**AMP Security Input** chịu trách nhiệm đưa ra guardrail cho:

- IAM least privilege.
- Remote-write/query boundary.
- Stable labels và cardinality guardrail.
- Encryption decision.
- SigV4 và secret-free logs.
- W12 negative/evidence tests.

### 3.3 Nó không chịu trách nhiệm gì?

Phần Nam không chịu trách nhiệm:

- Không làm schema validation chính ở entry layer, vì Ingest Lambda đã validate payload đầu vào.
- Không build AI model, baseline training hoặc detection algorithm.
- Không lưu prediction audit chính, vì audit thuộc Prediction Integration/Audit Store flow.
- Không tạo Grafana dashboard mới từ đầu, chỉ đảm bảo AMP có thể làm datasource/query source.
- Không làm auto-remediation.
- Không dùng `correlation_id`, `request_id`, `event_id` làm AMP label.
- Không thay đổi toàn bộ ingestion architecture sang ADOT sidecar nếu team đã chốt API Gateway/Ingest/SQS/Writer path.

---

## 4. Current CDO08 design

| Item                          | Current design                                                                                             |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------- |
| AWS service/pattern đang chọn | Lambda Writer + Amazon Managed Service for Prometheus                                                      |
| Primary telemetry store       | AMP workspace                                                                                              |
| Writer pattern                | Lambda đọc SQS theo batch và remote-write vào AMP                                                          |
| Lý do chọn AMP                | Account dùng được, managed Prometheus, PromQL/Grafana tốt, retention đáp ứng ≥90 ngày                      |
| Vì sao không dùng Timestream  | Timestream LiveAnalytics không khả dụng cho account mới/capstone account hiện tại                          |
| Input                         | Validated telemetry event JSON từ SQS                                                                      |
| Output                        | Prometheus time series trong AMP                                                                           |
| Owner/runtime                 | Lambda, SQS, AMP                                                                                           |
| Security boundary             | Writer role chỉ SQS read/delete + AMP remote-write; Prediction/Grafana chỉ query AMP                       |
| Observability                 | Writer success/error/duration, SQS queue age/backlog, DLQ, AMP query/cardinality                           |
| Cost driver                   | AMP ingested samples, queried samples, active series/cardinality, Lambda duration/invocation, SQS requests |
| Main POC risk                 | Direct Lambda phải xử lý remote_write format, compression, SigV4 signing                                   |
| Fallback                      | ECS/Fargate + ADOT Collector nếu Lambda direct remote-write không ổn định                                  |

### 4.1 AMP retention model

Timestream LiveAnalytics dùng mô hình **Memory Store + Magnetic Store**, nên trước đây có thể nghĩ theo hướng:

```text
7 ngày hot + 83 ngày cold = 90 ngày minimum
```

AMP không dùng mô hình Memory/Magnetic. AMP là managed Prometheus workspace. Retention được cấu hình ở workspace level hoặc dùng default retention theo service. Với CDO08, chỉ cần đảm bảo:

```text
AMP workspace retention ≥90 ngày
```

Ý chính: với AMP không cần chia hot/cold storage. Chỉ cần đảm bảo workspace giữ metric tối thiểu 90 ngày và query đúng window cần dùng.

Realtime detection không nên query toàn bộ 90 ngày liên tục. Cách dùng phù hợp:

| Use case                     |                      Query window đề xuất | Lý do                                                                |
| ---------------------------- | ----------------------------------------: | -------------------------------------------------------------------- |
| AI realtime detection        | 15–30 phút hoặc 120 phút theo AI contract | Cần nhanh, ít sample, đúng sliding-window use case                   |
| Baseline review              |                                 7–30 ngày | Dùng ít thường xuyên hơn, phục vụ review/baseline                    |
| Post-mortem/offline analysis |                                30–90 ngày | Chạy theo nhu cầu điều tra, không nên để dashboard/AI query liên tục |

Query dài trong AMP vẫn được, nhưng tốc độ phụ thuộc vào query range, số series bị quét, label filter, resolution/step và aggregation. Vì vậy cost/performance guardrail không nằm ở hot/cold tier mà nằm ở query window, label cardinality và metric volume.

---

## 5. Options considered

| Option                           | Điểm mạnh                                                                                                 | Điểm yếu / rủi ro                                                                                                    | Khi nào option này hợp lý                                                            | Fit với CDO08                     |
| -------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------- |
| Current: Lambda Writer + AMP     | Serverless, pay-per-use, giữ được SQS buffer/DLQ, PromQL, Grafana integration                             | Direct remote-write cần POC: encoding, compression, SigV4, error handling                                            | Scope hiện tại nếu remote-write POC pass                                             | High                              |
| ECS/Fargate + ADOT Writer        | ADOT Collector xử lý remote_write/SigV4 theo pattern chuẩn, giảm code kỹ thuật trong Lambda               | Thêm ECS task/service, chi phí chạy cố định theo giờ, cần networking Lambda → ADOT, phải monitor ADOT                | Hợp lý nếu Lambda direct remote-write fail hoặc team muốn dùng collector chuẩn       | Medium                            |
| ADOT sidecar bên cạnh app        | App gửi metric trực tiếp sang ADOT, flow metrics ngắn hơn, đúng kiểu app tự phát metric cho collector hơn | Có thể bỏ qua API Gateway/Ingest/SQS/Writer, ảnh hưởng nhiều task/diagram đã làm, giảm evidence retry/DLQ theo event | Hợp nếu team thiết kế observability-native từ đầu và không cần custom ingestion path | Low/Out of current scope          |
| Timestream LiveAnalytics         | Managed time-series database, lifecycle Memory/Magnetic rõ, SQL-like query                                | Account mới/capstone account không access được; không triển khai được hiện tại                                       | Hợp nếu account đã có quyền dùng LiveAnalytics                                       | Rejected                          |
| Timestream for InfluxDB          | Managed InfluxDB, query time-series tốt, cách lưu/query time-series đầy đủ                                | Có fixed DB instance cost, ví dụ medium/large có thể chiếm phần đáng kể budget; vẫn cần vận hành config              | Hợp nếu team cần InfluxQL/Flux/Influx ecosystem và chấp nhận fixed cost              | Medium-Low                        |
| Self-managed Prometheus/InfluxDB | Full control retention/plugin/config                                                                      | Phải tự lo HA, backup, persistent storage, upgrade, monitoring; overhead cao W11–W12                                 | Hợp nếu team đã có platform vận hành sẵn                                             | Low                               |
| S3 + Athena                      | Rẻ cho archive/offline analytics, hợp batch/post-mortem nếu dùng Parquet/partition tốt                    | S3 không phải query engine; query phải qua Athena/Glue; không hợp realtime sliding-window primary store              | Hợp làm archive/history ngoài primary path                                           | Low as primary, Medium as archive |
| Raw S3 only                      | Rẻ, dễ lưu file                                                                                           | Không đáp ứng primary time-series query requirement; dashboard/AI realtime sẽ chậm và phức tạp                       | Chỉ hợp lưu raw backup/archive                                                       | Rejected as primary               |

### 5.1 Direct Lambda → AMP vs Lambda → ADOT → AMP

| Criteria               | Direct Lambda → AMP                                      | Lambda → ADOT → AMP                                                        |
| ---------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------- |
| Component count        | Ít hơn: SQS → Lambda → AMP                               | Nhiều hơn: SQS → Lambda → ADOT → AMP                                       |
| Lambda code            | Phức tạp hơn vì tự xử lý remote_write/SigV4              | Nhẹ hơn, Lambda chủ yếu validate/map/forward                               |
| Retry/DLQ theo message | Rõ hơn vì Lambda trực tiếp biết success/fail khi ghi AMP | Phức tạp hơn vì Lambda đã forward sang ADOT, cần xác định success boundary |
| Operational overhead   | Ít service vận hành hơn                                  | Cần ECS/Fargate task/service cho ADOT                                      |
| Build risk             | Risk ở remote_write implementation                       | Risk ở deploy/config/networking ADOT                                       |
| Recommendation         | Primary nếu POC pass                                     | Fallback nếu direct path tốn thời gian/rủi ro                              |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [x] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên giữ **Lambda Writer + AMP** làm current design, nhưng phải có remote-write POC trước khi lock. Lý do chính là AMP fit với infra metrics/PromQL/Grafana, Lambda Writer giữ được SQS retry/DLQ/partial failure evidence, và chi phí phù hợp hơn với capstone so với các option có fixed runtime/ops overhead cao.

### 6.2 Lý do quyết định

- **Reliability:** SQS giữ event khi writer/storage lỗi; Lambda xử lý batch, retry, partial failure và DLQ. Queue age/backlog giúp phát hiện writer lag.
- **Security:** Writer chỉ có `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes/ChangeMessageVisibility` và `aps:RemoteWrite`; Prediction/Grafana chỉ có query permissions. AMP request dùng IAM + SigV4, không hardcode credential.
- **Cost:** AMP mostly usage-based theo samples/query/active series; Lambda/SQS tính theo invocation/request. Cost guardrail tập trung vào batch size, concurrency, query window và label cardinality.
- **Delivery timeline:** Lambda + SQS là pattern đơn giản để build nhanh. Remote-write là risk chính nên đặt POC làm gate. ADOT giữ làm fallback adapter nếu direct implementation mất thời gian.
- **Evidence:** Có thể tạo evidence rõ: remote-write POC result, PromQL query 120 phút, Grafana datasource screenshot, IAM denied test và DLQ/partial failure test.

### 6.3 Điều kiện / assumption

- Lambda remote-write AMP POC phải pass trước khi base-infra lock.
- POC cần chứng minh: metric ghi được vào AMP, SigV4 đúng, log không lộ secret, label cardinality được chặn.
- Nếu POC fail hoặc mất quá nhiều thời gian, fallback là ECS/Fargate + ADOT Collector.
- AMP workspace retention phải đáp ứng ≥90 ngày.
- Query AI realtime chỉ nên dùng window theo contract, ví dụ 120 phút, không query raw 90 ngày liên tục.
- `tenant_id`, `service_id`, `metric_type` phải là labels ổn định; `correlation_id`, `request_id`, `event_id` không được đưa vào AMP label.

---

## 7. Security considerations

Phần security không nhằm làm hệ thống phức tạp hơn, mà để trả lời rõ: ai được ghi metric, ai được đọc metric, dữ liệu nào được phép làm label và log nào không được chứa secret.

| Security area         | Decision / requirement                                                                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| IAM least privilege   | Writer: SQS read/delete/change visibility + AMP remote-write only; Prediction: AMP query only; Grafana: AMP read/query only                |
| Network exposure      | AMP là managed endpoint; Lambda không public inbound; nếu ADOT dùng ECS/Fargate thì chỉ expose nội bộ cho Writer                           |
| Secrets               | Không hardcode access key/secret key; không log credential/header/signature; dùng IAM role và temporary credentials                        |
| Encryption at rest    | AMP default encryption cho capstone; CMK optional nếu mentor/compliance yêu cầu. Secrets/audit/log có thể dùng CMK theo security ADR riêng |
| Encryption in transit | HTTPS + SigV4 cho AMP remote-write/query                                                                                                   |
| PII/log redaction     | Không log raw payload nếu chứa field nhạy cảm; log summary đã sanitize                                                                     |
| Tenant isolation      | `tenant_id`, `service_id` dùng để lọc metric, nhưng không phải lớp phân quyền thật; quyền truy cập vẫn phải enforce bằng IAM/query builder |
| Cardinality guardrail | Block `correlation_id`, `request_id`, `event_id`, `user_id`, `session_id`, `trace_id` làm AMP label                                        |
| Collector path        | Nếu dùng ADOT, ADOT task role chỉ có `aps:RemoteWrite` vào đúng workspace                                                                  |

### 7.1 IAM action explanation

| Role              | Permission                                  | Tác dụng                                                                              |
| ----------------- | ------------------------------------------- | ------------------------------------------------------------------------------------- |
| Writer Lambda     | `sqs:ReceiveMessage`                        | Cho phép Writer đọc message từ telemetry SQS queue                                    |
| Writer Lambda     | `sqs:DeleteMessage`                         | Cho phép xóa message khỏi queue sau khi xử lý và ghi metric thành công                |
| Writer Lambda     | `sqs:GetQueueAttributes`                    | Cho phép đọc metadata queue, ví dụ queue ARN, visibility timeout, approximate backlog |
| Writer Lambda     | `sqs:ChangeMessageVisibility`               | Cho phép điều chỉnh thời gian ẩn message khi cần xử lý lâu hơn, tránh retry quá sớm   |
| Writer Lambda     | `aps:RemoteWrite`                           | Cho phép ghi metric vào đúng AMP workspace qua remote-write endpoint                  |
| Writer Lambda     | `logs:CreateLogStream`, `logs:PutLogEvents` | Cho phép ghi execution/error/batch log vào CloudWatch Logs                            |
| Prediction Lambda | `aps:QueryMetrics`                          | Cho phép query metric bằng PromQL từ AMP                                              |
| Prediction Lambda | `aps:GetSeries`                             | Cho phép lấy danh sách series theo label/filter để hỗ trợ query/debug                 |
| Prediction Lambda | `aps:GetLabels`                             | Cho phép đọc label names hiện có, hỗ trợ Grafana/query builder                        |
| Prediction Lambda | `aps:GetMetricMetadata`                     | Cho phép đọc metadata metric để validate/query                                        |
| Grafana role      | AMP query permissions                       | Cho phép Grafana render dashboard từ AMP datasource                                   |

### 7.2 Label and cardinality guardrail

Trong AMP/Prometheus, label giống như tag để phân nhóm metric:

```text
metric_name{label_key="label_value"} value timestamp
```

Label tốt là label có giá trị ổn định, lặp lại nhiều lần và giúp query trend theo nhóm. Ví dụ:

```text
http_request_duration_ms{service_id="payment-gateway"}
```

Query này có thể dùng lại nhiều lần để xem latency của `payment-gateway` theo thời gian:

```text
10:00 → 300ms
10:05 → 350ms
10:10 → 420ms
10:15 → 500ms
```

Label không tốt là label gần như unique cho từng request/event. Ví dụ nếu dùng `request_id`:

```text
http_request_duration_ms{request_id="req-000001"} 420
http_request_duration_ms{request_id="req-000002"} 390
http_request_duration_ms{request_id="req-000003"} 510
```

AMP sẽ xem đây là ba time series khác nhau. Mỗi request sinh ra một ID mới, mỗi ID mới tạo thêm một series nhỏ, thường chỉ dùng một lần để debug rồi không tái sử dụng cho monitoring trend. Điều này không làm query lỗi, nhưng làm cardinality tăng nhanh, tốn storage, tăng cost, query chậm và dễ chạm quota.

Tóm lại, **label tốt là label được dùng lại nhiều lần**. **Label xấu là label cứ mỗi request/event lại sinh giá trị mới**.

Recommended labels:

| Label         | Lý do nên dùng                                         |
| ------------- | ------------------------------------------------------ |
| `tenant_id`   | Cần query theo tenant; số lượng tenant demo giới hạn   |
| `service_id`  | Cần query theo service; lặp lại qua nhiều metric event |
| `metric_type` | Cần phân loại latency, CPU, queue depth, error rate    |
| `environment` | Tách demo/staging/prod nếu cần                         |
| `instance_id` | Có thể dùng nếu số lượng task/instance được kiểm soát  |

Blocked labels:

```text
correlation_id
request_id
event_id
user_id
session_id
trace_id
```

Các ID này vẫn cần cho debug/tracing, nhưng nên lưu ở CloudWatch Logs, SQS message body, DLQ payload hoặc DynamoDB audit record, không đưa vào AMP label.

### 7.3 Encryption decision

AMP default encryption vẫn cần thiết dù dữ liệu là infra metrics, vì infra metrics vẫn là operational data. Metric có thể tiết lộ service nào đang chịu tải cao, thời điểm traffic tăng, queue backlog, RDS pressure hoặc bottleneck hệ thống. Không phải PII không có nghĩa là public data.

Với capstone, AMP default encryption là đủ vì:

- Dữ liệu là infra metrics, không chứa PII.
- Không cần tự quản lý KMS key policy.
- Không phát sinh thêm KMS cost.
- Ít rủi ro làm hỏng ingestion/query path.
- Phù hợp scope demo và budget giới hạn.

CMK phù hợp hơn cho production/compliance nếu cần kiểm soát key rotation, key usage audit hoặc revoke access theo key policy. Trade-off là tăng cost, tăng complexity và có thể ảnh hưởng collector/Grafana path nếu key policy sai.

### 7.4 SigV4 and secret-free remote-write

Remote-write request vào AMP phải được ký bằng AWS SigV4. Ký ở đây nghĩa là request có chữ ký AWS để AMP xác định:

```text
Ai đang gọi?
Role này có thật không?
Request có bị sửa không?
Role này có quyền aps:RemoteWrite không?
```

Flow:

```text
Writer Lambda muốn ghi metric vào AMP
        ↓
Lambda dùng IAM execution role để tạo SigV4 signature
        ↓
Gửi request remote-write kèm chữ ký tới AMP
        ↓
AMP kiểm tra chữ ký + IAM permission
        ↓
Đúng quyền → cho ghi metric
Sai/thiếu chữ ký → reject
```

Không dùng hardcoded access key/secret key vì nếu credential nằm trong code, `.env`, Terraform variable hoặc log thì có nguy cơ bị leak. Cách đúng là Lambda/ADOT dùng IAM role và temporary credentials do AWS runtime cấp.

Negative test đề xuất:

- [ ] `correlation_id` không xuất hiện trong AMP label.
- [ ] Writer role không query AMP nếu không được cấp query action.
- [ ] Writer role không đọc/xóa audit data.
- [ ] Prediction role không remote-write AMP.
- [ ] Request thiếu hoặc sai SigV4 bị reject.
- [ ] CloudWatch Logs không chứa Authorization header, signature, access key hoặc raw payload nhạy cảm.

---

## 8. Observability and evidence

Observability của phần này cần trả lời ba câu hỏi: **Writer còn chạy không? Queue có bị kẹt không? AMP có bị tăng cost/cardinality bất thường không?**

### 8.1 Logs cần có

- Batch receive count.
- Batch write success count.
- Batch write failure count.
- Failed message ID hoặc failed reason đã sanitize.
- Remote-write error type, ví dụ 4xx/5xx/throttle/timeout.
- Partial failure retry result.
- DLQ movement reason nếu có.

Log không nên chứa:

- AWS access key / secret access key / session token.
- Authorization header.
- SigV4 signature.
- Raw remote-write payload quá lớn.
- PII hoặc field ngoài schema.

Ví dụ log tốt:

```json
{
    "component": "telemetry-writer",
    "batch_size": 50,
    "success_count": 49,
    "failure_count": 1,
    "failed_reason": "remote_write_5xx",
    "tenant_id": "tenant-a",
    "service_id": "payment-gateway"
}
```

### 8.2 Metrics cần có

| Metric                           | Vì sao cần                             | Alert threshold đề xuất                |
| -------------------------------- | -------------------------------------- | -------------------------------------- |
| `writer_success_count`           | Biết Writer vẫn ghi metric thành công  | Sudden drop hoặc bằng 0 trong nhiều kỳ |
| `writer_error_count`             | Phát hiện AMP/write lỗi                | >0 sustained trong vài phút            |
| `writer_duration`                | Phát hiện timeout risk                 | p95 gần Lambda timeout                 |
| `writer_remote_write_latency_ms` | Biết remote-write chậm hay không       | tăng bất thường so với baseline        |
| `batch_processed_count`          | Theo dõi throughput theo batch         | drop bất thường                        |
| `queue_age`                      | Writer lag/backlog                     | tăng liên tục, đe dọa lead time        |
| `SQS visible messages`           | Biết backlog còn nhiều không           | vượt ngưỡng theo test volume           |
| `DLQ depth`                      | Biết có poison event hoặc lỗi lặp lại  | >0 cần điều tra                        |
| `AMP active series/cardinality`  | Cost/query risk                        | spike bất thường                       |
| `AMP query error/latency`        | Phục vụ Prediction/Grafana reliability | lỗi hoặc latency cao sustained         |

### 8.3 W12 evidence cần attach

- [ ] Remote-write POC result: Writer ghi được ít nhất một metric hợp lệ vào AMP.
- [ ] PromQL query lấy được 120 phút data theo `tenant_id`, `service_id`, `metric_type`.
- [ ] AMP/Grafana datasource screenshot.
- [ ] Grafana panel/annotation đọc được metric từ AMP.
- [ ] IAM denied test: Prediction role không `aps:RemoteWrite` được.
- [ ] IAM denied test: Writer role không đọc audit/secret ngoài quyền.
- [ ] Cardinality negative test: payload có `request_id` label bị reject/drop/DLQ.
- [ ] Secret-free log sample: không có access key, Authorization header, signature hoặc raw secret.
- [ ] DLQ/partial batch failure evidence.
- [ ] Cost guardrail evidence: batch size, reserved concurrency, retention và label whitelist.

---

## 9. Cost impact

Cost của hướng này không chỉ nằm ở việc lưu 90 ngày, mà chủ yếu đến từ số metric được ghi, số time series được tạo ra và số query chạy trên AMP. Vì vậy cần kiểm soát metric volume, label cardinality và query window.

| Cost driver           | Estimate / risk                                                                                      | Guardrail                                                                |
| --------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Compute/runtime       | Lambda tính theo invocation/duration; ADOT/ECS nếu dùng fallback sẽ có chi phí chạy cố định theo giờ | Batch size, timeout, reserved concurrency; chỉ dùng ADOT nếu cần         |
| Requests/messages     | SQS request + Lambda invocation tăng nếu batch nhỏ                                                   | Batch reads, starting point batch size 50                                |
| AMP ingestion         | Tính theo số samples ingested                                                                        | Sampling interval 60s, giới hạn số metric/service, tránh duplicate write |
| AMP storage/retention | Phụ thuộc samples + active series; retention ≥90 ngày                                                | Stable labels, không dùng request_id/event_id label                      |
| AMP query             | Query dài/nhiều series có thể tốn hơn và chậm hơn                                                    | AI dùng window 120 phút, dashboard filter theo tenant/service/metric     |
| Logs/observability    | Log volume tăng nếu log raw payload                                                                  | Log summary only, retention 14–30 ngày cho capstone                      |
| Fixed cost risk       | InfluxDB/ECS/ADOT/self-managed stack có fixed runtime/ops cost                                       | Ưu tiên AMP usage-based + Lambda serverless path                         |
| Cardinality risk      | High-cardinality labels tạo nhiều series nhỏ, tăng cost/query latency                                | Label whitelist ở Writer; block request_id/correlation_id/event_id       |

### 9.1 Cost reasoning

Với capstone có ít service và metric frequency khoảng 1 phút, AMP storage cost thường không phải rủi ro lớn nhất. Rủi ro lớn hơn là:

```text
Số samples ingested tăng quá nhanh
        ↓
High-cardinality labels tạo nhiều active series
        ↓
Query không filter hoặc query range quá dài
        ↓
Cost tăng và dashboard/AI query chậm
```

Vì vậy cost control nên tập trung vào:

- Metric whitelist.
- Stable labels.
- Sampling interval hợp lý, ví dụ 60s.
- Query window đúng use case, ví dụ 120 phút cho AI.
- Batch size và reserved concurrency cho Writer Lambda.
- Không dùng fixed-cost TSDB nếu không cần.

### 9.2 Recommended starting config

```text
Lambda Writer batch size: 50
Lambda timeout: 30s
SQS visibility timeout: 180s
maxReceiveCount: 5
Reserved concurrency: 3
DLQ: telemetry-writer-dlq
AMP retention: ≥90 days
Metric interval: 60s
```

---

## Quick glossary for reviewers

| Thuật ngữ       | Giải thích ngắn                                                               |
| --------------- | ----------------------------------------------------------------------------- |
| AMP             | Amazon Managed Service for Prometheus, nơi lưu và query infra metrics         |
| PromQL          | Ngôn ngữ query metric của Prometheus/AMP                                      |
| Remote-write    | Cách gửi metric vào AMP theo chuẩn Prometheus                                 |
| SigV4           | Chữ ký AWS giúp AMP xác thực caller là IAM role hợp lệ                        |
| Cardinality     | Số lượng time series khác nhau được tạo ra bởi metric name + label values     |
| ADOT            | AWS Distro for OpenTelemetry Collector, có thể làm adapter gửi metric vào AMP |
| Partial failure | Trong một batch, chỉ message lỗi bị retry thay vì retry toàn bộ batch         |
| Idempotency     | Cách xử lý retry để tránh duplicate không kiểm soát                           |
| DLQ             | Dead-letter queue, nơi giữ message lỗi nhiều lần để debug sau                 |
