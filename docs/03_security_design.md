# Thiết kế bảo mật - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Draft (W11)

**Last updated:** 2026-06-24

> **Phạm vi:** Tài liệu này mô tả các control bảo mật mà CDO08 thực sự cấu hình/deploy trong capstone: network boundary, IAM, secrets, encryption, audit và telemetry isolation. Đây không phải security audit enterprise hoàn chỉnh, không bao gồm threat model STRIDE, SIEM hay application authorization chi tiết.

> **W11 target:** Chốt design và policy boundary để build IaC. **W12 target:** Bổ sung evidence thực tế như Terraform, IAM policy ARN, KMS config, audit sample, negative test và scan result.

## 1. Network security

### 1.1 Network boundary

CDO08 có hai luồng mạng cần tách rõ:

```text
Synthetic generator → API Gateway → Ingest Lambda → SQS → Writer Lambda → AMP
EventBridge Scheduler → Prediction Lambda → AMP + AI endpoint + DynamoDB + Grafana
```

API Gateway là public entry point duy nhất cho synthetic generator gửi telemetry. Nó không cho phép anonymous caller: generator dùng IAM authorization hoặc cơ chế auth được freeze trong Telemetry Contract. API Gateway chỉ nhận HTTPS; request body bị giới hạn kích thước và bị throttling để một generator lỗi không làm cạn tài nguyên platform.

Fargate generator không cần public inbound port. Lambda ingest, writer, prediction và fallback không expose HTTP endpoint công khai. Các function chỉ gọi AWS managed services/AI endpoint bằng HTTPS và IAM role riêng. Nếu Lambda được đặt trong VPC, CDO08 chỉ thêm VPC endpoint/NAT khi cần sau khi kiểm tra service connectivity và cost; không tạo NAT Gateway chỉ để “trông production” vì có thể vượt budget capstone.

Security group chỉ áp dụng cho Fargate/VPC resources thực sự dùng security group. AMP, SQS, DynamoDB, EventBridge Scheduler, API Gateway và Lambda được kiểm soát chủ yếu bằng IAM/resource policy thay vì security group. Đây là lý do không dùng mẫu ALB/RDS security group của template cho kiến trúc serverless này.

### 1.2 Network controls

| Control | CDO08 design | Evidence W12 |
|---|---|---|
| Telemetry ingress | API Gateway HTTPS, IAM auth, request size limit, throttling | API config/Terraform và reject test |
| Generator access | Fargate task role chỉ có `execute-api:Invoke` cho ingest endpoint | IAM policy và denied-call test |
| Service egress | Chỉ HTTPS tới AWS services/AI endpoint được phép | Lambda config, IAM policy, endpoint decision |
| Public exposure | Không public inbound cho Fargate/Lambda/AMP/DynamoDB/SQS | Architecture/terraform review |
| Dependency failure | SQS DLQ, Scheduler DLQ và Lambda failure alarm tách riêng | DLQ config và injected-failure test |

## 2. IAM và access control

CDO08 dùng một IAM role cho một nhiệm vụ. Không dùng shared administrator role trong runtime; CI/CD deploy role cũng không được dùng để chạy workload. IAM action/resource ARN sẽ bị giới hạn theo resource CDO08 thực tế sau khi Terraform tạo ARN.

| Role | Dùng bởi | Quyền tối thiểu dự kiến |
|---|---|---|
| `cdo08-generator-role` | Fargate synthetic generator | `execute-api:Invoke` chỉ cho telemetry endpoint; CloudWatch Logs write |
| `cdo08-ingest-role` | Telemetry Entry Lambda | `sqs:SendMessage` chỉ telemetry queue; CloudWatch Logs write |
| `cdo08-writer-role` | Telemetry Writer Lambda | `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes`; AMP `RemoteWrite` chỉ workspace; CloudWatch Logs write |
| `cdo08-prediction-role` | Prediction Integration Lambda | AMP query actions chỉ workspace; invoke/call AI endpoint; `dynamodb:PutItem` chỉ audit table; đọc Grafana/AI secret; CloudWatch Logs write |
| `cdo08-fallback-role` | Fallback Lambda | AMP query actions, write audit record, tạo Grafana annotation theo secret; không có quyền remote-write telemetry |
| `cdo08-scheduler-role` | EventBridge Scheduler | Chỉ `lambda:InvokeFunction` cho Prediction Lambda |
| `cdo08-grafana-role` | Amazon Managed Grafana workspace | Read/query AMP workspace; nếu AMP dùng CMK thì được phép dùng key theo policy |
| `cdo08-deploy-role` | CI/CD/Terraform | Chỉ create/update resource CDO08; không có wildcard `iam:*` hoặc quyền đọc secret value |
| `cdo08-reviewer-role` | Mentor/debug | Read-only CloudWatch, AMP query, DynamoDB audit query; không có write/delete |

Prediction Lambda dùng idempotency key `service_id + scheduled_at` để retry Scheduler/Lambda không tạo audit hoặc Grafana annotation trùng. Least privilege phải được test bằng hai hành vi: generator không thể ghi AMP trực tiếp và reviewer không thể đọc secret hoặc xóa audit data.

## 3. Secrets management

### 3.1 Secrets inventory

| Secret/config nhạy cảm | Storage | Được đọc bởi | Rotation/ownership |
|---|---|---|---|
| AI endpoint credential hoặc signing token, nếu AI contract yêu cầu | AWS Secrets Manager `cdo08/ai-api` | Prediction Lambda | AI/Tech Lead owner; manual rotation trong capstone |
| Grafana service-account token | AWS Secrets Manager `cdo08/grafana` | Prediction/Fallback Lambda | Tech Lead owner; rotate khi lộ token hoặc trước demo nếu cần |
| HMAC/API key ingest, nếu IAM auth không được dùng | AWS Secrets Manager `cdo08/telemetry-ingest` | Generator task | PM/Tech Lead owner; prefer IAM auth để tránh secret này |
| AMP workspace ID, API URL, schedule interval | SSM Parameter Store hoặc Terraform variable | Relevant functions | Không phải secret; versioned config |

Không lưu secret trong Git, Terraform variable file commit, container image, Lambda environment value plaintext hoặc Jira comment. Lambda/Fargate nhận secret qua runtime reference từ Secrets Manager; log chỉ ghi secret name/ARN, không ghi value.

### 3.2 Anti-leak controls

- CI có secret scan trước merge; `.gitignore` loại `.tfvars`, `.env`, state file và artifact có credential.
- Container generator dùng image tag/digest cố định, không bake access key/token vào Dockerfile.
- Structured logs redact `Authorization`, `Bearer`, API key và request body; telemetry body chỉ log metadata cần debug.
- Secret retrieval failure tạo metric/alarm nhưng không trả secret/error detail cho caller.

## 4. Encryption

### 4.1 Encryption at rest

| Data | Storage | Encryption design | Retention/lifecycle |
|---|---|---|---|
| Telemetry metrics | AMP workspace | AMP encryption at rest mặc định bằng AWS-owned key | AMP retention mặc định 150 ngày, vượt yêu cầu ≥90 ngày |
| Prediction audit | DynamoDB audit table | SSE-KMS với CDO08 customer-managed KMS key | TTL 90 ngày; TTL là lifecycle cleanup, không cam kết xóa đúng thời điểm |
| Queue messages/DLQ | SQS telemetry + prediction schedule DLQ | Server-side encryption enabled; key choice đo cost trước khi dùng CMK | Retention đủ cho retry/triage demo, chốt trong IaC |
| Secrets | AWS Secrets Manager | Service encryption at rest; access bằng IAM role | Retain until rotated/deleted by owner |
| Operational logs | CloudWatch Logs | Encryption at rest mặc định; log group retention cấu hình rõ | 14–30 ngày cho capstone, không log raw secret/PII |

AMP customer-managed KMS key không là default của CDO08. Nếu bật CMK, Grafana role phải được cấp key access và team cần xác nhận compatibility với ingestion path; đổi này chỉ làm khi security requirement hoặc mentor yêu cầu.

### 4.2 Encryption in transit

- Generator gọi API Gateway qua HTTPS; API Gateway từ chối HTTP.
- Lambda gọi AMP, Secrets Manager, DynamoDB, Grafana và AI endpoint qua TLS/HTTPS.
- Không truyền secret qua query string, annotation text hoặc audit log.
- AI endpoint auth/TLS/network rule cuối cùng phải theo Deployment Contract freeze T5 W11.

## 5. Audit logging và PII handling

Mỗi prediction call, bao gồm success, AI error và fallback, phải có một DynamoDB audit record. Field tối thiểu: `prediction_id`, timestamp, `tenant_id`, `service_id`, PromQL query/window hash, outcome/status, confidence, recommendation reference, `fallback`, error code và Grafana annotation ID nếu có. `correlation_id`, request ID hoặc event ID chỉ nằm trong audit/log; không làm AMP label vì sẽ tạo cardinality cao.

CloudTrail management events ghi nhận Terraform/deploy/IAM/KMS thay đổi. CloudWatch giữ operational log cho ingest, writer, scheduler, prediction và fallback. Scheduler DLQ dùng cho lỗi Scheduler không invoke được Lambda; Lambda on-failure destination/alarm dùng cho lỗi thực thi bên trong function. Hai loại lỗi không dùng chung DLQ.

Telemetry contract dùng schema whitelist. Event có field không được phép, `tenant_id` mismatch, timestamp sai hoặc có dấu hiệu PII phải bị **reject tại ingest**, ghi metadata reject đã redact, không ghi raw PII vào AMP/SQS/audit. Đây phù hợp brief TF4: không ingest real customer PII.

## 6. Container security

CDO08 không dùng EKS, nên Kubernetes RBAC, NetworkPolicy và Pod Security Standard không áp dụng. Fargate generator là container workload duy nhất cần control riêng:

- Image lưu trong ECR private repository; không dùng image không rõ provenance ở runtime.
- CI scan image bằng Trivy; không deploy finding Critical, High phải có owner/mitigation.
- Task role thay static access key; task chạy non-root nếu image/tool hỗ trợ.
- Task definition không chứa secret plaintext; CPU/memory/task count có limit để tránh cost abuse.

## 7. Compliance touchpoints

| Control area | CDO08 control | Evidence capstone |
|---|---|---|
| Logical access | IAM role separation, least privilege, reviewer read-only | IAM policy/resource boundaries + denied-action test |
| Change management | Git history, PR/CI, Terraform plan/apply | Commit/PR, pipeline output, CloudTrail event |
| Data protection | AMP/DynamoDB/SQS encryption at rest, TLS in transit, Secrets Manager | Config/IaC and KMS reference |
| Monitoring | CloudWatch alarms, DLQs, audit records, fallback test | Dashboard/log/alarm screenshots |
| PII minimization | Schema whitelist and reject at ingest | Invalid payload test + redacted log |

SOC2/GDPR/PCI certification không nằm trong scope. PCI card data đặc biệt out of scope vì telemetry chỉ chứa infrastructure metrics.

## 8. Open questions

- [ ] AI API dùng IAM, API key hay một auth mechanism khác? AI endpoint có private network requirement không? — *Resolve in Deployment/AI API Contract before T5 W11.*
- [ ] API Gateway ingest dùng IAM auth hay API key/HMAC cho generator? — *Tech Lead resolve before Terraform apply.*
- [ ] AMP cần customer-managed KMS key hay encryption mặc định đủ cho capstone? — *Resolve with mentor/Client security expectation before W12.*
- [ ] Retention cụ thể cho audit record ngoài telemetry 90 ngày là bao lâu? — *Resolve with Client/mentor; current proposal is DynamoDB TTL 90 days.*
- [ ] Lambda on-failure destination dùng SQS hay EventBridge, và retention/replay owner là ai? — *Resolve in Deployment Design before integration test.*

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) - NFR, security requirement và open questions
- [`02_infra_design.md`](02_infra_design.md) - architecture, AMP, EventBridge Scheduler và failure flow
- [`04_deployment_design.md`](04_deployment_design.md) - IaC, CI/CD, rollout/rollback và security gates
- [`08_adrs.md`](08_adrs.md) - ADR cho AMP, ingestion path, encryption và isolation decisions
