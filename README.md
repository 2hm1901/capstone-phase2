# CDO08 - Foresight Lens Platform

CDO08 là platform Cloud/DevOps cho **Task Force 4 - Foresight Lens**. Platform nhận telemetry hạ tầng, lưu/query time-series metrics, gọi AI engine để dự báo capacity drift, hiển thị recommendation trên Grafana, lưu audit log và vẫn cảnh báo bằng static threshold khi AI endpoint không sẵn sàng.

> **Trạng thái:** Capstone W11-W12 · Design đang được hoàn thiện · Không commit secret, Terraform state hoặc PII vào repository.

## Mục tiêu

Client đang phát hiện capacity exhaustion sau khi user đã complain. CDO08 xây platform để AI có thể nhận metric window theo từng service và tạo cảnh báo sớm có recommendation cụ thể.

Platform phải hỗ trợ:

- Tối thiểu 3 service: `payment-gw`, `ledger`, `fraud-detector`.
- Per-service telemetry/baseline identity qua `tenant_id`, `service_id`, `metric_type`.
- Synthetic workload cho gradual drift, sudden spike, slow leak và noisy baseline.
- Lead time mục tiêu ≥15 phút trong ít nhất một test window ≥2 giờ.
- Audit log mỗi prediction call, encryption at rest, retention được chỉ rõ.
- Fail-open static threshold khi AI serving endpoint timeout/429/503.
- Cost guardrail theo rough cap $200/tháng.

## Kiến trúc hiện tại

```text
Fargate Synthetic Generator
        ↓
API Gateway → Ingest Lambda → SQS telemetry queue → Writer Lambda
                                                        ↓ remote-write
                                            Amazon Managed Prometheus (AMP)
                                                        ↓ PromQL
EventBridge Scheduler → Prediction Lambda → AI POST /v1/predict
                                      ├── Grafana annotation
                                      └── DynamoDB audit record

AI error/timeout/429/503
        ↓
Fallback Lambda → static threshold → Grafana fallback annotation + audit
```

Terraform hiện tại đã tạo phần nền tảng network trong `sandbox`: 2 VPC tách biệt cho workload generator và AI Engine, không peering. AI Engine VPC có public subnet cho Application Load Balancer và private subnet cho AI service.

### Thành phần chính

| Component | Lựa chọn hiện tại | Trách nhiệm |
|---|---|---|
| Synthetic workload | ECS Fargate + generator/k6 | Tạo 3 service profiles và 4 scenario test |
| Telemetry entry | API Gateway + Lambda | Validate schema/identity/PII policy trước storage |
| Buffer | SQS Standard + DLQ | Retry/replay telemetry khi writer/store lỗi |
| Telemetry store | Amazon Managed Service for Prometheus | Lưu/query metric bằng PromQL, retention ≥90 ngày |
| Prediction trigger | EventBridge Scheduler | Trigger prediction theo cadence per service |
| AI integration | Prediction Lambda | Query AMP, gọi AI, tạo audit/annotation |
| Dashboard | Amazon Managed Grafana | Hiển thị metric, prediction và fallback annotation |
| Audit | DynamoDB SSE-KMS + TTL | Trace prediction, recommendation, error và fallback |
| Security/observability | IAM, Secrets Manager, KMS, CloudWatch | Least privilege, secret protection, logs/alarms/evidence |

Amazon Timestream for LiveAnalytics không được dùng vì AWS account capstone không có quyền truy cập khách hàng mới. AMP là primary telemetry store; trước khi lock implementation, team phải chứng minh đường Writer → AMP remote-write → PromQL → Grafana bằng POC.

## Repository layout

```text
.
├── docs/                               # Evidence Pack Markdown
│   ├── 01_requirements_analysis.md
│   ├── 02_infra_design.md
│   ├── 03_security_design.md
│   ├── 04_deployment_design.md
│   ├── 05_cost_analysis.md
│   ├── 07_test_eval_report.md
│   ├── 08_adrs.md
│   └── assets/
├── contracts/                          # AI-CDO contracts sau khi review/freeze
├── infra/                              # Terraform/IaC
│   ├── bootstrap/                      # Tạo shared S3 state bucket một lần
│   ├── modules/
│   │   └── networking/                 # Module hiện có; module mới thêm qua PR
│   └── environments/
│       └── sandbox/                    # Môi trường deployable duy nhất
├── src/
│   ├── generator/
│   ├── ingest/
│   ├── writer/
│   ├── prediction/
│   └── fallback/
├── config/
│   ├── services/
│   ├── scenarios/
│   ├── thresholds/
│   ├── dashboards/
│   └── schedules/
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── load/
│   ├── security/
│   └── fixtures/
├── scripts/
├── evidence/
│   ├── poc/
│   ├── load-tests/
│   ├── security-tests/
│   └── cost/
├── standup-notes.md
├── curveball-responses.md              # W12
├── individual-pitches.md               # W12
├── retrospective.md                    # W12
└── final-build/                        # W12
```

## Documentation and contracts

`docs/` là Evidence Pack chính thức. Research Google Docs có thể dùng tạm, nhưng nội dung quyết định phải được merge vào Markdown trong repository để có git history.

Các file cần có trong W11:

```text
docs/01_requirements_analysis.md
docs/02_infra_design.md
docs/03_security_design.md
docs/04_deployment_design.md
docs/05_cost_analysis.md                # skeleton
docs/08_adrs.md
contracts/telemetry-contract.md
contracts/ai-api-contract.md
contracts/deployment-contract.md
infra/
standup-notes.md
```

Sau T5 W11, Telemetry, AI API và Deployment contracts freeze. Nếu implementation nội bộ thay đổi, cập nhật ADR; không tự đổi interface contract.

W12 bổ sung `05_cost_analysis.md` với actual cost, `07_test_eval_report.md`, `curveball-responses.md`, `individual-pitches.md`, `retrospective.md`, final build, slides và demo video.

## Prerequisites

- AWS account capstone `894597652722`, region `us-east-1`.
- AWS CLI configured với quyền deploy sandbox.
- Terraform version theo `infra/bootstrap/versions.tf` và `infra/environments/sandbox/versions.tf`.
- Docker để build generator/Lambda image khi cần.
- Runtime theo source code đã chọn: Python hoặc Node.js.
- k6 hoặc tooling tương đương để chạy load scenario.

## Development workflow

Terraform dùng chung một remote state S3 cho `sandbox`. Các lệnh thường dùng đã được gom trong [`Makefile`](Makefile).

```bash
# 1. Kết nối shared Terraform state trên máy local
make tf-init

# 2. Validate IaC trước khi mở PR
make tf-fmt-check
make tf-validate
make tf-plan

# 3. Apply sandbox chỉ sau khi plan đã được review
make tf-apply

# 4. Smoke test platform
./scripts/smoke-test.sh

# 5. Run một scenario đã versioned
python scripts/run-scenario.py gradual_drift payment-gw 7200

# 6. Teardown resource demo khi không dùng
./scripts/teardown.sh
```

Không commit trực tiếp lên `main` cho Terraform implementation. Mỗi Jira task tạo branch riêng, mở PR, attach output `make tf-plan`, review xong mới merge/apply để tránh tạo trùng resources.

## Test and evidence expectations

Mọi claim quan trọng cần đi theo chuỗi:

```text
Requirement → code/IaC config → test command → raw artifact → document result
```

Evidence cần lưu trong `evidence/` hoặc `docs/assets/` gồm:

- AMP remote-write/PromQL/Grafana POC.
- Lead-time calculation cho scenario gradual drift.
- k6/load-test summary và dashboard screenshot.
- DLQ/replay, AI timeout/fail-open và audit correlation evidence.
- IAM/tenant isolation negative test.
- Cost forecast/actual và budget guardrail evidence.

## Security rules

Không commit các file/giá trị sau:

```text
AWS access keys
Grafana service-account token
AI API credential
Terraform state / .tfvars chứa secret
.env files
PEM/private keys
PII hoặc raw customer telemetry
```

`.gitignore` tối thiểu:

```gitignore
.env
.env.*
*.tfstate
*.tfstate.*
*.tfvars
*.tfplan
.terraform/
terraform.tfstate.d/
__pycache__/
.pytest_cache/
node_modules/
dist/
build/
*.pem
*.key
*.log
```

Runtime secrets phải đi qua AWS Secrets Manager hoặc mechanism đã được ghi trong `docs/03_security_design.md`. Không log raw request body chứa secret hoặc PII.

## Team workflow

- Mỗi Jira task có một owner, deadline và evidence link khi close.
- `standup-notes.md` là append-only: Done / Doing / Blocker / Owner / ETA.
- `08_adrs.md` là append-only; mọi quyết định có trade-off lớn phải có ADR.
- Không tạo service/module chỉ để “trông enterprise”; phải build/test được trong capstone và trace được về hard requirement TF4.
- Thay đổi kiến trúc phải đồng bộ `docs/02_infra_design.md`, ADR, Terraform, cost model và test plan.

## Useful links

- [Requirements analysis](docs/01_requirements_analysis.md)
- [Infrastructure design](docs/02_infra_design.md)
- [Security design](docs/03_security_design.md)
- [Deployment design](docs/04_deployment_design.md)
- [Architecture decisions](docs/08_adrs.md)
- [Contracts](contracts/)
