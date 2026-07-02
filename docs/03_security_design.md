# Thiết kế bảo mật - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Final draft for W12 Evidence Pack #2

**Last updated:** 2026-07-01

> **Phạm vi:** Tài liệu này mô tả các control bảo mật mà CDO08 thực sự cấu hình/deploy trong capstone: network boundary, IAM, secrets, encryption, audit và telemetry isolation. Đây không phải security audit enterprise hoàn chỉnh, không bao gồm threat model STRIDE, SIEM hay application authorization chi tiết.

> **W12 evidence target:** document này phản ánh design đã deploy bằng Terraform. Screenshot/log cụ thể cần được attach trong [`W12_EVIDENCE_PACK.md`](W12_EVIDENCE_PACK.md).

## 1. Network security

### 1.1 Network boundary

CDO08 có hai luồng mạng cần tách rõ:

```text
Synthetic generator → API Gateway → Ingest Lambda → SQS → Writer Lambda → AMP
EventBridge Scheduler → Prediction Lambda → AMP + AI Engine Runtime do CDO08 host → DynamoDB + Grafana
```

API Gateway là public entry point duy nhất cho synthetic generator gửi telemetry. Nó không cho phép anonymous caller: generator dùng IAM authorization hoặc cơ chế auth được freeze trong Telemetry Contract. API Gateway chỉ nhận HTTPS; request body bị giới hạn kích thước và bị throttling để một generator lỗi không làm cạn tài nguyên platform.

Fargate generator không cần public inbound port. Lambda ingest, writer, prediction và fallback không expose HTTP endpoint công khai. Prediction Lambda chỉ gọi AWS managed services và **AI Engine Runtime do CDO08 host**. Deployment Contract hiện xác định AI Engine runtime là ECS Fargate FastAPI, AI API Gateway `AWS_IAM` edge, VPC Link tới internal ALB, ECS task trong private subnet và auth IAM SigV4 tại edge layer. CDO08 host model serving trong platform của mình theo artifact/spec AI bàn giao. Implementation hiện tại giữ Serving Adapter Lambda ngoài VPC và gọi AI API Gateway bằng SigV4; workload VPC chỉ có bounded outbound path cho ECS k6 trong test window, còn AI VPC dùng VPC endpoints cho S3/ECR/CloudWatch Logs.

Security group chỉ áp dụng cho Fargate/VPC resources thực sự dùng security group. AMP, SQS, DynamoDB, EventBridge Scheduler, API Gateway và Lambda được kiểm soát chủ yếu bằng IAM/resource policy thay vì security group. Đây là lý do không dùng mẫu ALB/RDS security group của template cho kiến trúc serverless này.

### 1.2 Network controls

| Control | CDO08 design | Evidence W12 |
|---|---|---|
| Telemetry ingress | API Gateway HTTPS, IAM auth, request size limit, throttling | API config/Terraform và reject test |
| Generator access | Fargate task role chỉ có `execute-api:Invoke` cho ingest endpoint | IAM policy và denied-call test |
| Engine access | Serving Adapter Lambda gọi AI Engine Runtime qua AI API Gateway `AWS_IAM` bằng SigV4; API Gateway dùng VPC Link tới internal ALB; ECS task không public IP | Network/IAM config, SG review và denied-auth test |
| Service egress | Chỉ HTTPS tới AWS services/AI Engine path được phép | Lambda config, IAM policy, endpoint decision |
| Public exposure | Public HTTPS entry chỉ là API Gateway ingest và AI API Gateway `AWS_IAM`; AI ALB là internal, Fargate/Lambda/AMP/DynamoDB/SQS không public inbound, ECS task không public IP | Architecture/terraform review |
| Dependency failure | Telemetry SQS DLQ và Lambda/Scheduler CloudWatch alarm tách riêng | DLQ config và injected-failure test |

## 2. IAM và access control

CDO08 dùng một IAM role cho một nhiệm vụ. Không dùng shared administrator role trong runtime; CI/CD deploy role cũng không được dùng để chạy workload. IAM action/resource ARN sẽ bị giới hạn theo resource CDO08 thực tế sau khi Terraform tạo ARN.

| Role | Dùng bởi | Quyền tối thiểu dự kiến |
|---|---|---|
| `cdo08-generator-role` | Fargate synthetic generator | `execute-api:Invoke` chỉ cho telemetry endpoint; CloudWatch Logs write |
| `cdo08-ingest-role` | Telemetry Entry Lambda | `sqs:SendMessage` chỉ telemetry queue; CloudWatch Logs write |
| `cdo08-writer-role` | Telemetry Writer Lambda | `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes`; AMP `RemoteWrite` chỉ workspace; CloudWatch Logs write |
| `cdo08-prediction-role` | Prediction Integration Lambda | AMP query actions chỉ workspace; gọi **AI Engine Runtime nội bộ** bằng IAM SigV4 theo contract; `dynamodb:PutItem` và `dynamodb:Query` cho audit/cooldown trên audit table; đọc Grafana secret nếu cần; CloudWatch Logs write |
| `cdo08-ai-engine-role` | AI Engine ECS Fargate task | Chỉ đọc baseline S3/KMS theo contract, ghi CloudWatch Logs/metrics; không có quyền AMP write, audit delete hay administrator |
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
| AI Engine runtime config: endpoint, baseline bucket, AWS_REGION, OTel endpoint nếu dùng | SSM Parameter Store hoặc Terraform variable | Prediction Lambda và/hoặc AI Engine task | Không phải secret; auth dùng IAM SigV4, không dùng API key |
| Grafana service-account token | AWS Secrets Manager `cdo08/grafana` | Prediction/Fallback Lambda | Tech Lead owner; rotate khi lộ token hoặc trước demo nếu cần |
| SNS email subscriber | Terraform variable `alert_email_subscribers` | SNS subscription only | Không phải secret; người nhận phải confirm email từ AWS SNS trước khi nhận alert |
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
| AI Engine audit logs | CloudWatch Logs log group riêng | KMS encryption, retention 1 năm theo AI API Contract | Audit fields tối thiểu: `audit_id`, timestamp, `tenant_id`, `principal_id`, `input_hash`, `recommendation_snapshot` |
| Queue messages/DLQ | SQS telemetry queue + telemetry DLQ | Server-side encryption enabled; key choice đo cost trước khi dùng CMK | Retention đủ cho retry/triage demo, chốt trong IaC |
| Secrets | AWS Secrets Manager | Service encryption at rest; access bằng IAM role | Retain until rotated/deleted by owner |
| Operational logs | CloudWatch Logs | Encryption at rest mặc định; log group retention cấu hình rõ | 14–30 ngày cho capstone, không log raw secret/PII |

AMP customer-managed KMS key không là default của CDO08. Nếu bật CMK, Grafana role phải được cấp key access và team cần xác nhận compatibility với ingestion path; đổi này chỉ làm khi security requirement hoặc mentor yêu cầu.

### 4.2 Encryption in transit

- Generator gọi API Gateway qua HTTPS; API Gateway từ chối HTTP.
- Lambda gọi AMP, Secrets Manager, DynamoDB, Grafana và AI Engine Runtime nội bộ qua TLS/HTTPS hoặc AWS private path theo contract.
- Không truyền secret qua query string, annotation text hoặc audit log.
- AI Engine auth/TLS/network rule theo Deployment Contract: AI API Gateway `AWS_IAM`, VPC Link tới internal ALB, ECS task private, no API key.

## 5. Audit logging và PII handling

Mỗi prediction call, bao gồm success, AI error và fallback, phải có một DynamoDB audit record phía CDO08. Field tối thiểu: `prediction_id`, timestamp, `tenant_id`, `service_id`, PromQL query/window hash, outcome/status, confidence, recommendation reference, `fallback`, error code, Grafana annotation ID nếu có và AI `audit_id` trả về từ `/v1/predict`. `correlation_id`, request ID hoặc event ID chỉ nằm trong audit/log; không làm AMP label vì sẽ tạo cardinality cao.

AI Engine cũng có audit log nội bộ theo AI API Contract: `audit_id`, timestamp, `tenant_id`, `principal_id`, `input_hash` và `recommendation_snapshot`, encrypted at rest và retention 1 năm. CDO08 không ghi thay audit nội bộ của AI; CDO08 lưu `audit_id` để cross-reference khi điều tra.

CloudTrail management events ghi nhận Terraform/deploy/IAM/KMS thay đổi. CloudWatch giữ operational log cho ingest, writer, scheduler, prediction và fallback. Không dùng DLQ riêng cho EventBridge Scheduler trong scope hiện tại; Scheduler invoke failure, Lambda error/timeout và fallback rate được phát hiện bằng CloudWatch alarm. Telemetry DLQ chỉ dùng cho SQS ingestion/writer path.

Telemetry contract dùng schema whitelist với `metric_type`, `tenant_id`, `service_id`, `ts`, `value` và `labels`. Event có field không được phép, `tenant_id` mismatch, timestamp sai hoặc có dấu hiệu PII phải bị **reject tại ingest**, ghi metadata reject đã redact, không ghi raw PII vào AMP/SQS/audit. Trước khi gọi AI, Prediction Lambda phải đảm bảo window ≥120 phút và xử lý bucket thiếu bằng forward-fill/zero-fill theo contract. AI có thể trả `400` cho input well-formed nhưng không hợp lệ hoặc `422` cho lỗi schema/type; CDO08 không được retry mù hai nhóm lỗi này.

## 6. Container security

CDO08 không dùng EKS, nên Kubernetes RBAC, NetworkPolicy và Pod Security Standard không áp dụng. Fargate generator là container workload cần control ngay:

- Image lưu trong ECR private repository; không dùng image không rõ provenance ở runtime.
- CI scan image bằng Trivy; không deploy finding Critical, High phải có owner/mitigation.
- Task role thay static access key; task chạy non-root nếu image/tool hỗ trợ.
- Task definition không chứa secret plaintext; CPU/memory/task count có limit để tránh cost abuse.

AI Engine Runtime nằm trong phần CDO08 deploy. Khi AI bàn giao image/artifact, CDO08 phải áp dụng container control tương tự generator: ECR private repository, image digest immutable, image scan trước deploy, task role riêng, không static AWS credential, ECS task trong private subnet, inbound chỉ từ ALB security group, health check `/health`, CPU/memory limit và log redaction. CDO08 không sửa model logic, nhưng chịu trách nhiệm runtime hardening, network exposure, rollout/rollback và cost guard cho ECS service.

## 7. Compliance touchpoints

| Control area | CDO08 control | Evidence capstone |
|---|---|---|
| Logical access | IAM role separation, least privilege, reviewer read-only | IAM policy/resource boundaries + denied-action test |
| Change management | Git history, PR/CI, Terraform plan/apply | Commit/PR, pipeline output, CloudTrail event |
| Data protection | AMP/DynamoDB/SQS encryption at rest, TLS in transit, Secrets Manager | Config/IaC and KMS reference |
| Monitoring | CloudWatch alarms, telemetry DLQ, audit records, fallback test | Dashboard/log/alarm screenshots |
| PII minimization | Schema whitelist and reject at ingest | Invalid payload test + redacted log |

SOC2/GDPR/PCI certification không nằm trong scope. PCI card data đặc biệt out of scope vì telemetry chỉ chứa infrastructure metrics.

## 8. Resolved W12 security decisions

| Topic | Decision |
|---|---|
| AI Engine compute/runtime ownership | CDO08 hosts AI Engine on ECS Fargate from AI-provided artifact/spec |
| Engine auth/path/health | AI API Gateway `AWS_IAM`, `/health`, `/v1/predict`, VPC Link to internal ALB, ECS private subnets |
| AI image/artifact | Image is stored in ECR `foresight-lens-engine` with immutable tag, currently configured from Terraform instead of mutable `latest` |
| Baseline storage | S3 bucket `cdo08-sandbox-ai-baselines-894597652722`, prefix `baselines/`, encrypted and private |
| OTel endpoint | Not deployed for W12; CloudWatch Logs/Metrics are the capstone operational evidence path |
| Ingest auth | API Gateway `AWS_IAM`; k6 generator signs requests with SigV4 via ECS task role |
| AMP encryption | AMP managed encryption is accepted for capstone; KMS CMK is used for DynamoDB audit/S3 baseline/log groups where configured |
| CDO audit retention | DynamoDB audit TTL uses `audit_retention_days`; current Terraform variable is 90 days for prediction/fallback evidence |
| AI audit retention | AI Engine audit CloudWatch log group retention is 365 days per AI contract |
| Failure notification | CloudWatch alarms are used for W12; no separate Lambda on-failure destination is required for demo |

Remaining evidence to capture: IAM denied tests, API Gateway unauthorized test, KMS/DynamoDB/S3 screenshots, and proof that logs do not contain Grafana token or SigV4 Authorization values.

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) - NFR, security requirement và open questions
- [`02_infra_design.md`](02_infra_design.md) - architecture, AMP, EventBridge Scheduler và failure flow
- [`04_deployment_design.md`](04_deployment_design.md) - IaC, CI/CD, rollout/rollback và security gates
- [`08_adrs.md`](08_adrs.md) - ADR cho AMP, ingestion path, encryption và isolation decisions
