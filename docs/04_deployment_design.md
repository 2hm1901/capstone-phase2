# Thiết kế triển khai & CI/CD - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Draft (W11)

**Last updated:** 2026-06-25

## 1. Mục tiêu triển khai

Tài liệu này mô tả cách CDO08 triển khai platform Foresight Lens trên AWS theo các contract đã freeze: Telemetry Contract, AI API Contract và Deployment Contract. Phạm vi triển khai của CDO08 gồm telemetry ingestion, time-series store, prediction scheduler, AI Engine Runtime do CDO08 host, Grafana overlay, audit store, fallback path, observability và cost guard.

Nguyên tắc chính:

- CDO08 **tự host AI Engine Runtime** trên platform của mình. AI team bàn giao image/artifact và spec; CDO08 deploy, vận hành, rollback và quan sát runtime.
- W11 có thể dùng mock/skeleton đúng API shape để unblock integration. W12 phải deploy artifact AI thật lên ECS Fargate của CDO08.
- Mọi thay đổi sau contract freeze phải đi qua ADR hoặc change note; không tự đổi schema `metric_type`, `/v1/predict`, auth hoặc error mapping.
- Deployment phải tạo evidence được: Terraform plan/apply, image tag/digest, health check, smoke test, CloudWatch/Grafana screenshot, audit sample và rollback proof.

Luồng triển khai mục tiêu:

```text
Git PR
-> lint/test/scan
-> build Lambda package + AI Engine container
-> Terraform plan
-> review
-> Terraform apply
-> ECS/CodeDeploy rollout AI Engine
-> smoke test E2E
-> attach evidence vào Jira/Docs
```

## 2. IaC strategy

### 2.1 Tool choice

CDO08 dùng **Terraform** cho hạ tầng AWS. Lý do: dễ review bằng plan, dễ tái lập demo, phù hợp AWS resources hỗn hợp gồm API Gateway, Lambda, SQS, AMP, DynamoDB, ECS Fargate, ALB, IAM, CloudWatch và Grafana config.

State khuyến nghị:

| Item | Quyết định CDO08 | Lý do |
|---|---|---|
| IaC tool | Terraform | Plan/apply rõ ràng, reviewer dễ đọc diff |
| State backend | S3 remote state + native S3 lockfile `use_lockfile=true` | Tránh state local thất lạc và concurrent apply; không dùng DynamoDB lock |
| Environment | Chỉ một môi trường shared `sandbox` | Cả nhóm dùng chung một AWS account/region như môi trường dev |
| Naming | prefix `cdo08-*` | Tránh đụng resource team khác |
| Tagging | `Project=TF4`, `Team=CDO08`, `Env=sandbox`, `Owner=<name>` | Cost tracking và cleanup |

Remote state đã được bootstrap một lần trong AWS account shared. Không chạy lại bootstrap trừ khi Tech Lead chủ động thay đổi state backend.

### 2.2 Terraform module structure

Cấu trúc repo đề xuất:

```text
infra/
├── modules/
│   ├── network/              # VPC, private subnets, SG, internal ALB nếu cần
│   ├── telemetry_ingest/     # API Gateway, Lambda Ingest, SQS, telemetry DLQ
│   ├── telemetry_store/      # AMP workspace, remote-write/query config
│   ├── prediction/           # EventBridge Scheduler, Prediction Lambda, Fallback Lambda
│   ├── ai_engine/            # ECS Fargate service, task definition, internal ALB, CodeDeploy
│   ├── audit/                # DynamoDB audit table, KMS, TTL
│   ├── observability/        # CloudWatch alarms/log groups, Grafana datasource/dashboard hooks
│   └── security/             # IAM roles, KMS keys, Secrets/SSM parameters
├── environments/
│   └── sandbox/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
└── README.md
```

Mapping component:

| Component | Terraform module | Deploy evidence |
|---|---|---|
| Synthetic generator | `ai_engine` hoặc app module riêng nếu generator chạy ECS task | ECS task run log, k6 profile |
| API Gateway + Ingest Lambda | `telemetry_ingest` | Invoke test, invalid payload reject |
| SQS + DLQ | `telemetry_ingest` | Queue ARN, DLQ alarm |
| Writer Lambda → AMP | `telemetry_store` + writer package | Remote-write sample, PromQL query |
| EventBridge Scheduler | `prediction` | Schedule ARN, invocation metric |
| Prediction/Fallback Lambda | `prediction` | AI success/fallback smoke test |
| AI Engine Runtime | `ai_engine` | ECS service, task health, `/health` 200 |
| DynamoDB audit | `audit` | Audit item sample |
| Grafana overlay | `observability` | Annotation screenshot |

## 3. CI/CD pipeline

### 3.1 Branch and review policy

CDO08 dùng branch strategy đơn giản:

```text
main        = demo-ready branch
feature/*  = task branch
```

Rule:

- Mọi thay đổi IaC, Lambda code, Dockerfile, contract adapter đều qua PR.
- PR phải có Terraform plan hoặc ghi rõ “docs-only”.
- Không merge nếu secret scan fail hoặc Terraform plan có thay đổi destructive chưa được Tech Lead xác nhận.
- Contract change không sửa trực tiếp trong implementation PR; phải có ADR/change note.

### 3.2 Pipeline stages

| Stage | Tool đề xuất | Mục đích | Gate |
|---|---|---|---|
| Format/lint | `terraform fmt`, markdownlint nếu có | Giữ format ổn định | Không có diff format |
| Unit test | pytest/node test tùy runtime Lambda | Test transform telemetry, PromQL builder, AI request mapper | Test pass |
| Contract test | JSON schema fixture | Đảm bảo request `/v1/predict` dùng `metric_type`, `tenant_id`, window ≥120 phút | Fixture pass |
| Secret scan | Gitleaks/TruffleHog | Chặn token, AWS key, `.tfvars` commit | No secret |
| Image build | Docker build AI Engine/generator | Tạo image reproducible | Build pass |
| Image scan | Trivy | Chặn CVE nghiêm trọng | No Critical; High có owner/waiver |
| Terraform validate/plan | Terraform | Preview resource change | Plan reviewed |
| Apply | Terraform apply thủ công hoặc protected job | Deploy infra | Apply success |
| Smoke test | script/curl/aws cli | Kiểm tra ingest, query, prediction, fallback, audit | Smoke pass |

Pipeline không cần GitOps/ArgoCD trong scope hiện tại vì CDO08 deploy AWS serverless + ECS trực tiếp bằng Terraform/CodeDeploy. Nếu sau này dùng EKS mới cần ArgoCD/Flux.

## 4. AI Engine deployment

### 4.1 Runtime target

Theo Deployment Contract, AI Engine Runtime của CDO08:

| Field | Value |
|---|---|
| Compute | ECS Fargate task, stateless FastAPI |
| Service | `foresight-lens-engine` hoặc `cdo08-foresight-lens-engine` |
| CPU/memory | 512 CPU units, 1024 MB |
| Port | 8080 |
| Health check | `/health`, 30s interval, healthy threshold 2, unhealthy threshold 3 |
| API | `POST /v1/predict` |
| Auth | IAM SigV4; W11 mock có thể optional theo AI API Contract |
| Network | private subnet + internal ALB, không public-facing |
| Baseline storage | S3 bucket mã hóa KMS; engine fetch baseline hoặc cache 5 phút |
| Logs | CloudWatch application logs 14 ngày; audit logs 3 năm, KMS encrypted |

CDO08 không sửa model logic. Nếu image AI không chạy, CDO08 report bằng evidence: image tag/digest, task log, health check response, env/config hiện tại.

### 4.2 Rollout strategy

Rollout AI Engine dùng canary theo Deployment Contract:

| Step | Traffic | Thời gian quan sát |
|---|---:|---:|
| 1 | 10% | 5 phút |
| 2 | 50% | 5 phút |
| 3 | 100% | giữ |

Primary deployment method:

```text
AWS CodeDeploy blue/green hoặc canary cho ECS service
```

Fallback nếu chưa kịp CodeDeploy trong W11:

```text
ECS service update task definition thủ công + giữ previous task definition để rollback
```

Abort criteria:

- Error rate > 1%.
- P99 latency > 800 ms.
- Health check `/health` fail.
- Prediction response `5xx/429` tăng bất thường.
- Capacity Exhaustion alert sai lệch >15% trong canary test.

Rollback:

| Method | Khi dùng | Target |
|---|---|---|
| CodeDeploy rollback to previous task definition | Normal path | <60 giây theo contract |
| ECS service revert manual | Nếu CodeDeploy chưa sẵn | Best effort W11, ghi rõ limitation |
| Scale desired count = 0 | Cost circuit breaker hoặc runaway cost | Dừng cost, platform chuyển fallback |

### 4.3 W11/W12 delivery mode

| Giai đoạn | Engine dùng | Mục tiêu |
|---|---|---|
| W11 mock integration | Mock/skeleton trả hardcoded JSON đúng schema | Test Prediction Lambda, retry, fallback, annotation, audit |
| W12 final integration | Image/artifact thật từ AI | Chạy 4 scenario, đo lead time, confidence, recommendation |

Điều quan trọng: CDO08 code không được phụ thuộc vào mock-only field. Request/response phải bám `contracts/ai-api-contract.md`.

## 5. Telemetry and prediction deployment

### 5.1 Telemetry path

Deploy order:

```text
KMS/IAM/log groups
-> SQS + telemetry DLQ
-> Lambda Ingest
-> API Gateway
-> AMP workspace
-> Lambda Writer
-> CloudWatch alarms
```

Smoke test tối thiểu:

1. Gửi payload hợp lệ:

```json
{
  "ts": "2026-06-25T10:30:00Z",
  "tenant_id": "tenant-cdo08-demo",
  "service_id": "payment-api",
  "metric_type": "api_latency_ms",
  "value": 450.5,
  "labels": {"region": "ap-southeast-2"}
}
```

2. Kiểm tra message vào SQS.
3. Kiểm tra Writer ghi AMP thành công.
4. Query PromQL theo `tenant_id`, `service_id`, `metric_type`.
5. Gửi payload sai `tenant_id`/schema và xác nhận bị reject, không vào AMP.

### 5.2 Prediction path

Deploy order:

```text
AI Engine Runtime
-> DynamoDB audit table
-> Grafana token/config
-> Prediction Lambda
-> Fallback Lambda
-> EventBridge Scheduler
-> CloudWatch alarms
```

Config chuẩn:

| Config | Value |
|---|---|
| Telemetry emit interval | 60s |
| Prediction interval | 5 phút/service |
| Lookback window | ≥120 phút |
| Retry on `429` | exponential backoff 1s → 2s → 4s, tôn trọng `Retry-After` |
| Retry on `503`/timeout | bounded retry rồi fallback |
| Retry on `400` | không retry; fix client/request mapper |
| Scheduler DLQ | không dùng trong scope hiện tại; dùng CloudWatch alarm |

Smoke test:

- Prediction Lambda query đủ 120 phút data.
- Request body có `signal_window[].tenant_id`, `service_id`, `metric_type`, `ts`, `value`.
- Header có `X-Tenant-Id`; W12 có SigV4 enforced.
- AI success tạo DynamoDB audit + Grafana annotation.
- AI timeout/503 tạo fallback audit + fallback annotation.

## 6. Environment model

Capstone CDO08 chỉ dùng một AWS account shared và một môi trường Terraform duy nhất: `sandbox`.

| Environment | Mục đích | Auto deploy | Ghi chú |
|---|---|---|---|
| `local` | Unit test, contract fixture | Không | Không dùng AWS thật |
| `sandbox` | POC, integration và demo W12 | Manual approval | Tất cả member cùng tương tác trên account shared bằng IAM user riêng |

Phân tách ownership bằng prefix/resource tag:

```text
cdo08-*
Project=TF4
Team=CDO08
Env=sandbox
```

Không dùng production traffic hoặc production mirror trong `sandbox`.

## 7. Secrets and config in pipeline

Nguyên tắc:

- CI/CD dùng GitHub OIDC assume role, không dùng long-lived AWS access key.
- Không commit `.tfvars`, `.env`, Terraform state, Grafana token, AWS credential.
- Secret thật để trong Secrets Manager; config không nhạy cảm để trong SSM Parameter Store hoặc Terraform variable.
- Lambda/ECS chỉ đọc đúng secret/config cần dùng.

Secrets/config:

| Item | Storage | Consumer |
|---|---|---|
| Grafana service account token | Secrets Manager `cdo08/grafana` | Prediction/Fallback Lambda |
| Ingest HMAC/API key nếu không dùng IAM | Secrets Manager `cdo08/telemetry-ingest` | Generator |
| AI Engine endpoint/internal DNS | SSM/Terraform output | Prediction Lambda |
| Baseline bucket/path | SSM/Terraform var | AI Engine task |
| OTel collector endpoint nếu triển khai | SSM/Terraform var | AI Engine task |

## 8. Observability and evidence

### 8.1 CloudWatch logs

| Log group | Retention | Nội dung |
|---|---:|---|
| `/aws/lambda/cdo08-ingest` | 14–30 ngày | validation reject/success metadata |
| `/aws/lambda/cdo08-writer` | 14–30 ngày | AMP remote-write success/error |
| `/aws/lambda/cdo08-prediction` | 14–30 ngày | PromQL query hash, AI status, latency |
| `/aws/lambda/cdo08-fallback` | 14–30 ngày | fallback threshold decision |
| `/ecs/cdo08-ai-engine/app` | 14 ngày | FastAPI app logs |
| `/ecs/cdo08-ai-engine/audit` | 3 năm | AI audit fields theo contract |

### 8.2 Alarms

| Alarm | Signal | Action |
|---|---|---|
| Ingest reject spike | validation error count | Review schema/generator |
| SQS queue age high | `ApproximateAgeOfOldestMessage` | Writer/AMP incident |
| Telemetry DLQ > 0 | DLQ visible messages | Triage poison event |
| Writer remote-write error | Lambda error/custom metric | Check AMP/quota/SigV4 |
| Scheduler invoke failure | EventBridge/Lambda error | Check permission/target |
| Prediction error/fallback rate high | Lambda custom metric | Check AI Engine |
| AI Engine unhealthy | ECS/ALB target health | Rollback/restart |
| Cost budget 80%/100% | AWS Budgets | Warn / circuit breaker |

### 8.3 Evidence pack

W12 evidence cần attach:

- Terraform plan/apply output.
- AI Engine image tag/digest và task definition revision.
- `/health` response.
- Ingest valid/invalid payload test.
- AMP query screenshot/result.
- AI success audit record.
- Fallback audit record.
- Grafana annotation screenshot.
- CloudWatch alarm config.
- Rollback hoặc simulated rollback evidence.
- Cost estimate/actual screenshot.

## 9. Cost guard and teardown

Cost cap mục tiêu là dưới $200/tháng. Deployment phải có guardrail:

- Resource tags đầy đủ.
- AWS Budget cảnh báo 80% và 100%.
- Generator không chạy 24/7 nếu không cần; chạy theo test window.
- Telemetry sampling mặc định 60s; không giảm xuống 10s/1s nếu không có test window time-bound.
- Prediction interval mặc định 5 phút; không gọi AI theo từng data point.
- Tránh NAT Gateway nếu không bắt buộc; ưu tiên VPC endpoints hoặc public AWS service endpoint khi security/cost cho phép.
- Có cleanup runbook cho sandbox resources không còn dùng.

Circuit breaker theo contract cho AI Engine:

```text
Nếu forecast/actual cost đạt ngưỡng nguy hiểm:
-> set ECS desired_count = 0
-> disable generator schedule/task
-> giữ telemetry store/audit để điều tra
-> platform dùng fallback nếu cần demo failure mode
```

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| AI image/artifact bàn giao muộn | Không test real engine kịp | W11 mock same contract; W12 smoke ngay khi có image |
| Lambda Writer remote-write AMP khó implement | Telemetry không vào primary store | POC sớm; fallback option ADOT/ECS writer nếu POC fail |
| Private networking làm phát sinh NAT cost | Vượt budget | Chỉ thêm NAT khi bắt buộc; review VPC endpoint/cost trước apply |
| `metric_type`/schema đổi sau freeze | Prediction mapper fail | Contract test fixture + change request |
| AI Engine 429/503 nhiều | Prediction không ổn định | Bounded retry, fallback, cap concurrency, rollback |
| Grafana token leak | Dashboard/audit risk | Secrets Manager, log redaction, rotate token |
| Manual deploy không tái lập | Evidence yếu | Terraform + PR + runbook bắt buộc |

## 11. Open questions

- [ ] AI image ECR URI/tag/digest cuối cùng là gì?
- [ ] Baseline S3 bucket/path do AI yêu cầu cụ thể thế nào?
- [ ] CDO08 có cần triển khai ADOT/OpenTelemetry collector endpoint cho AI Engine không, hay CloudWatch/X-Ray là đủ cho capstone?
- [ ] W12 có bắt buộc CodeDeploy canary thật không, hay ECS task definition rollback evidence đủ?
- [ ] Grafana annotation dùng service account token hay datasource/query-only approach?
- [ ] Lambda on-failure destination có cần riêng không, hay CloudWatch alarm đủ cho demo?

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) - scope, NFR và W11/W12 objective
- [`02_infra_design.md`](02_infra_design.md) - component selection và failure flow
- [`03_security_design.md`](03_security_design.md) - IAM, network, secrets, encryption và audit
- [`05_cost_analysis.md`](05_cost_analysis.md) - cost forecast và actual W12
- [`08_adrs.md`](08_adrs.md) - quyết định kiến trúc và trade-off
