# CDO08 W12 Evidence Pack - Foresight Lens

**Document owner:** CDO08  
**Status:** Final draft for W12 Evidence Pack #2  
**Last updated:** 2026-07-01  
**Scope:** CDO platform evidence for TF4 Foresight Lens

> File này là evidence pack chính để reviewer đọc nhanh trạng thái W12. Các screenshot/log được liệt kê là attachment evidence cần bổ sung vào repo/slides/Jira khi chụp xong. Folder `context/` chỉ là tài liệu tham chiếu/local, không phải artifact submit chính.

---

## 1. Executive summary

CDO08 đã triển khai platform Foresight Lens theo hướng managed observability + serverless + ECS Fargate:

- Synthetic telemetry generator chạy bằng k6 trên ECS Fargate.
- Telemetry ingest qua API Gateway `AWS_IAM` + Lambda.
- Buffer bằng SQS + DLQ.
- Writer Lambda remote-write metrics vào Amazon Managed Service for Prometheus (AMP).
- Prediction Lambda query AMP theo window 120 phút, gọi Serving Adapter.
- Serving Adapter gọi AI Engine qua AI API Gateway `AWS_IAM` + VPC Link tới internal ALB.
- AI Engine do CDO08 host trên ECS Fargate private subnet.
- Prediction/fallback result được ghi audit vào DynamoDB và hiển thị Grafana annotation.
- Security baseline gồm IAM least privilege, KMS, Secrets Manager, S3 baseline bucket, private ALB, SigV4 edge, CloudWatch audit/logs.

Demo service scope hiện tại:

| Service | Vai trò demo | Status |
|---|---|---|
| `payment-gw` | Payment gateway synthetic service | Implemented |
| `ledger` | Ledger synthetic service | Implemented |
| `fraud-detector` | Fraud detection synthetic service | Implemented |

Scenario generator hiện tại:

| Scenario | Mục tiêu test | Status |
|---|---|---|
| `noisy_baseline` | Baseline có noise nhưng không nên alert quá mức | Implemented |
| `sudden_spike` | Capacity spike rõ để AI phát hiện anomaly/recommendation | Implemented, đã có Grafana annotation |
| `gradual_drift` | Drift chậm, dùng để đo lead time | Implemented, cần chụp evidence nếu dùng trong presentation |
| `slow_leak` | Leak tăng dần, dùng để test memory/queue/resource exhaustion | Implemented, cần chụp evidence nếu dùng trong presentation |
| `all` | Random/mixed scenario | Implemented, không phải lựa chọn tốt nhất để đo precision/recall sạch |

---

## 2. Required document set status

Theo `CAPSTONE_EVIDENCE_PACK_FORMAT.md`, CDO group cần đủ 7 docs. Các docs chính đã được cập nhật về W12 final draft; phần còn lại chủ yếu là attach screenshot/log evidence.

| Required file | Current status | Remaining action |
|---|---|---|
| `docs/01_requirements_analysis.md` | Updated for W12 final scope | Capture final evidence referenced by the doc |
| `docs/02_infra_design.md` | Updated for W12 final topology and diagram | Add/acknowledge `active_connections` dashboard panel |
| `docs/03_security_design.md` | Updated with resolved W12 security decisions | Capture IAM/KMS/API Gateway/Secrets screenshots |
| `docs/04_deployment_design.md` | Updated with actual module/source layout and deployment decisions | Capture final apply/smoke/rollback evidence |
| `docs/05_cost_analysis.md` | Updated with current monthly forecast and capture plan | Add Cost Explorer/Budget screenshots |
| `docs/07_test_eval_report.md` | Rewritten from template into W12 test/eval report | Attach final screenshots/logs |
| `docs/08_adrs.md` | Updated with W12 ADRs through ADR-019 | Keep append-only if new decisions happen |

Recommended: trước code freeze, attach các screenshot còn thiếu vào Jira/slides/repo. Các docs chính đã được đưa về W12 final draft.

---

## 3. Remaining W12 evidence/actions

### 3.1 High priority evidence

| File | W12 status | Evidence còn thiếu |
|---|---|---|
| `docs/01_requirements_analysis.md` | Updated | None beyond final review |
| `docs/02_infra_design.md` | Updated | Screenshot/caption of final diagram and active_connections panel decision |
| `docs/03_security_design.md` | Updated | IAM/KMS/API Gateway/Secrets evidence screenshots |
| `docs/04_deployment_design.md` | Updated | Terraform apply output, smoke test, ECS health evidence |
| `docs/05_cost_analysis.md` | Updated | Cost Explorer/Budget screenshots |
| `docs/07_test_eval_report.md` | Updated | Final test screenshots/logs |

### 3.2 Medium priority actions

| Area | Current note | Recommended action |
|---|---|---|
| Grafana dashboard | Dashboard chưa có panel `active_connections` dù contract/generator có metric này | Thêm panel hoặc ghi rõ gap trước demo. Best choice: thêm panel để đủ 7 metric theo contract |
| Cost explanation | NAT cost là driver lớn | Khi present, giải thích k6 ECS cần outbound public API Gateway/ECR/logs; AI VPC dùng endpoints/internal ALB nên không cần NAT |
| ADR narrative | ADR đã updated tới ADR-019 | Không sửa/xóa ADR cũ; nếu có quyết định mới thì append ADR-020 |
| README | README nên giữ high-level | Không đưa tình trạng Terraform chi tiết vào README tổng quát |
| `infra/README.md` | Runbook đã có nhiều lệnh vận hành | Nếu update thêm, chỉ thêm lệnh thực dụng: run k6 real/backfill, provision Grafana, apply với `enable_prediction=true`, không commit token |

### 3.3 Contract notes

Contracts đã freeze nên không nên sửa tùy tiện. Nếu có chỗ wording cũ/generic như `Timestream or Managed Prometheus`, evidence pack/docs nên giải thích implementation cuối cùng chọn AMP vì Timestream không khả dụng cho account capstone.

Retention cần ghi rõ:

- Telemetry retention: AMP đáp ứng ≥90 ngày.
- CDO audit store: DynamoDB audit TTL hiện tại theo security design/cost guardrail, cần ghi đúng số đang cấu hình.
- AI Engine audit contract có thể yêu cầu 1 năm; nếu AI engine tự log/audit riêng thì đó là responsibility phía AI. Không được viết mơ hồ “mọi audit đều 1 năm” nếu DynamoDB audit platform chỉ TTL ngắn hơn.

---

## 4. Final architecture evidence

### 4.1 Current architecture summary

End-to-end flow:

```text
k6 ECS Fargate
  -> API Gateway ingest (AWS_IAM)
  -> Lambda Ingest
  -> SQS telemetry queue + DLQ
  -> Lambda Writer
  -> AMP remote-write
  -> EventBridge Scheduler
  -> Prediction Lambda
  -> Serving Adapter Lambda
  -> AI API Gateway (AWS_IAM)
  -> VPC Link
  -> internal ALB
  -> AI Engine ECS Fargate
  -> response recommendation
  -> DynamoDB audit + Grafana annotation
```

### 4.2 Known deployed resource IDs / endpoints

Fill/update from latest `terraform output`:

| Resource | Value |
|---|---|
| AWS region | `us-east-1` |
| AWS account | `894597652722` |
| Ingest API endpoint | `https://vbs9nb95i8.execute-api.us-east-1.amazonaws.com/sandbox/v1/telemetry` |
| AI API endpoint | `https://quu5b0vqpc.execute-api.us-east-1.amazonaws.com/sandbox` |
| AI internal ALB endpoint | `http://internal-cdo08-sandbox-ai-engine-alb-2003992455.us-east-1.elb.amazonaws.com` |
| AMP workspace ID | `ws-eb0a1ab7-9c8d-4656-89b0-4f5a2e4cf507` |
| AMP alias | `cdo08-sandbox-amp` |
| Grafana workspace endpoint | `g-9411285a4b.grafana-workspace.us-east-1.amazonaws.com` |
| Grafana dashboard | `https://g-9411285a4b.grafana-workspace.us-east-1.amazonaws.com/d/cdo08-foresight-lens` |
| Audit table | `cdo08-sandbox-audit` |
| Baseline bucket | `cdo08-sandbox-ai-baselines-894597652722` |
| Generator ECS cluster | `cdo08-sandbox-generator-cluster` |
| Generator task definition | `cdo08-sandbox-generator` |
| AI ECR repo | `894597652722.dkr.ecr.us-east-1.amazonaws.com/foresight-lens-engine` |
| Generator ECR repo | `894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator` |

### 4.3 Screenshot evidence to capture

Save screenshots under `docs/assets/evidence/` if committing them, or keep local and reference in slides.

| Screenshot | Why it matters | Suggested filename |
|---|---|---|
| Updated architecture diagram from `docs/image.png` | Shows final system topology | `w12_architecture_diagram.png` |
| Terraform apply output with `Resources: ...` and outputs | Proves infra deployed reproducibly | `terraform_apply_outputs.png` |
| ECS AI Engine service desired/running = 2, target group healthy | Proves AI runtime is hosted by CDO08 | `ecs_ai_engine_healthy.png` |
| AI Target Group health = healthy on port 8080 | Proves internal ALB path works | `ai_target_group_healthy.png` |
| API Gateway AI route with `AWS_IAM` auth / integration | Proves SigV4 edge and VPC Link | `ai_api_gateway_iam_vpc_link.png` |
| Workload VPC NAT Gateway | Proves k6 ECS has outbound path while still in private subnet | `workload_nat_gateway.png` |
| VPC endpoints in AI VPC | Proves AI VPC avoids NAT for AWS service access | `ai_vpc_endpoints.png` |

---

## 5. Telemetry pipeline evidence

### 5.1 Evidence already observed

Observed k6 ECS run:

- k6 task ran on ECS Fargate.
- It emitted telemetry to ingest API using IAM SigV4.
- Logs showed `metric_emit_result` with `status: 202`.
- SQS queue drained after writer processing.
- Grafana dashboard showed metric lines from AMP.

Example log shape:

```json
{
  "component": "k6-generator",
  "event": "metric_emit_result",
  "level": "info",
  "status": 202,
  "service_id": "payment-gw",
  "metric_type": "cpu_usage_percent",
  "scenario": "sudden_spike"
}
```

### 5.2 Commands to capture evidence

Run after a generator window:

```bash
aws logs tail /ecs/cdo08-sandbox-generator \
  --region us-east-1 \
  --since 30m \
  --filter-pattern '"metric_emit_result"'
```

```bash
aws sqs get-queue-attributes \
  --region us-east-1 \
  --queue-url "$(terraform -chdir=infra/environments/sandbox output -raw telemetry_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed
```

```bash
aws sqs get-queue-attributes \
  --region us-east-1 \
  --queue-url "$(terraform -chdir=infra/environments/sandbox output -raw telemetry_dlq_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed
```

Expected:

- Main queue visible messages eventually `0`.
- DLQ visible messages `0` for clean run.
- Writer logs should not show remote-write errors.

### 5.3 Screenshot evidence to capture

| Screenshot | Why it matters | Suggested filename |
|---|---|---|
| k6 log summary with `http_req_failed: 0.00%` | Proves generator ran successfully | `k6_2h_summary.png` |
| CloudWatch k6 logs showing `status:202` for all services | Proves API accepted telemetry | `k6_metric_emit_status_202.png` |
| SQS queue attributes visible/not visible/delayed = 0 after drain | Proves pipeline drained | `sqs_queue_drained.png` |
| DLQ attributes = 0 | Proves no poison messages in clean run | `sqs_dlq_empty.png` |
| Grafana panels showing AMP metrics | Proves writer → AMP → Grafana path | `grafana_amp_metrics.png` |

---

## 6. AI integration and prediction evidence

### 6.1 Current AI runtime status

Evidence already observed:

- AI Engine health endpoint returned HTTP 200.
- AI predict endpoint returned HTTP 200 for smoke payload.
- AI Engine ECS target group reached healthy state after rebuilding image for `linux/amd64`.
- Serving Adapter uses SigV4 to call AI API Gateway.
- Prediction Lambda invokes Serving Adapter for services.
- Grafana annotations are created from prediction results.

Example smoke result observed:

```json
{
  "anomaly": true,
  "severity": 1.0,
  "recommendation": {
    "action_verb": "SCALE_UP",
    "target": "payment-gw ECS Service",
    "from_to": "Current -> +2 Tasks",
    "confidence": 0.99,
    "evidence_link": "https://dashboard.internal/metrics/payment-gw/cpu"
  },
  "reasoning": "CPU drift detected. Scale out ECS service.",
  "audit_id": "<ai-audit-id>"
}
```

### 6.2 Known real annotation examples

Use final screenshots/logs to confirm exact values before presentation.

| Service | Observed behavior | Evidence needed |
|---|---|---|
| `payment-gw` | `sudden_spike` triggered AI anomaly/recommendation, e.g. `SCALE_UP` | Grafana popup + DynamoDB audit item |
| `ledger` | Prediction annotation observed, but may be visually confusing if dashboard filtered to another service/scenario | Filter Grafana to `ledger` and capture popup |
| `fraud-detector` | Prediction annotation observed, including non-CPU recommendation in some runs | Filter Grafana to `fraud-detector` and capture popup |

### 6.3 Commands to capture evidence

AI health:

```bash
AI_ENGINE_ENDPOINT="$(terraform -chdir=infra/environments/sandbox output -raw ai_engine_endpoint)" \
  python scripts/smoke-ai-engine.py
```

Prediction Lambda logs:

```bash
aws logs tail /aws/lambda/cdo08-sandbox-prediction-lambda \
  --region us-east-1 \
  --since 30m
```

Serving Adapter logs:

```bash
aws logs tail /aws/lambda/cdo08-sandbox-serving-adapter-lambda \
  --region us-east-1 \
  --since 30m
```

DynamoDB audit query by correlation ID:

```bash
aws dynamodb query \
  --region us-east-1 \
  --table-name cdo08-sandbox-audit \
  --index-name correlation-index \
  --key-condition-expression "correlation_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"<correlation-id-from-annotation>"}}'
```

### 6.4 Screenshot evidence to capture

| Screenshot | Why it matters | Suggested filename |
|---|---|---|
| AI smoke test HTTP 200 health + predict | Proves AI runtime reachable through CDO platform | `ai_smoke_health_predict.png` |
| Prediction Lambda logs `prediction_started` → `prediction_completed` | Proves scheduler/prediction path runs | `prediction_lambda_completed.png` |
| Serving Adapter logs showing AI call success | Proves CDO adapter → AI API path | `serving_adapter_ai_success.png` |
| Grafana annotation popup with service, action, confidence, audit/correlation ID | Main demo evidence | `grafana_prediction_annotation_popup.png` |
| DynamoDB audit item matching annotation correlation ID | Proves traceability | `dynamodb_audit_item.png` |
| CloudWatch dashboard/alarm for fallback/error | Proves operational observability | `cloudwatch_prediction_alarms.png` |

---

## 7. Test and evaluation evidence

### 7.1 What must be proven for TF4

From TF4 learner context:

| Requirement | Evidence status | What to add |
|---|---|---|
| Test window ≥2h | k6 2h run observed | Capture final k6 summary screenshot |
| Lead time ≥15 min before SLO breach | Needs explicit measurement | Mark spike threshold timestamp vs annotation timestamp in Grafana |
| Multi-service ≥3 services | Implemented | Capture dashboard with 3 services in same scenario |
| Per-service baseline | Implemented through service-specific baseline files | Capture S3 baseline bucket + service JSON files |
| FP rate ≤12% | Not fully measured yet | Need table from noisy_baseline run: predictions vs expected no-alert |
| Catch ≥80% drift | Partially proven via sudden_spike annotations | Need final scenario matrix across services/scenarios |
| Capacity recommendation actionable | Observed in annotation popup | Capture popup with action verb, target, from→to, confidence, evidence link |
| Audit log every prediction | Implemented via DynamoDB | Capture audit records and explain schema |
| Fail-open fallback | Code exists; needs evidence | Force AI timeout/503 or set invalid endpoint in controlled test and capture fallback annotation/audit |

### 7.2 Recommended final test matrix

For clean evaluation, run **one scenario per window**. Avoid mixing `all` when measuring precision/recall, because mixed scenarios make ground truth harder to explain.

| Test | Services | Scenario | Duration | Expected outcome | Evidence |
|---|---|---:|---:|---|---|
| Baseline sanity | 3 | `noisy_baseline` | 2h or backfill + short real | Low/no annotations | Grafana + prediction logs |
| Spike detection | 3 | `sudden_spike` | 2h | Anomaly annotations, action recommendation | Grafana popup + audit |
| Gradual drift | 3 | `gradual_drift` | 2h | Early warning before breach | Annotation timestamp vs breach timestamp |
| Slow leak | 3 | `slow_leak` | 2h | Memory/queue exhaustion warning | Grafana + audit |
| AI failure | 1 | Any | short | fallback annotation/audit | Lambda logs + Grafana |
| Stale telemetry | 1 | no generator | 30m after stop | no new spam annotations | Prediction logs show skip |

### 7.3 Known failures and fixes

| Failure | Root cause | Fix | Evidence needed |
|---|---|---|---|
| ECS AI Engine `exec format error` | Docker image built for wrong architecture from Mac | Rebuilt image with `docker buildx --platform linux/amd64` and immutable tag | ECS logs before/after |
| AI API returned 404 | Smoke script path mismatch / route path issue | Corrected smoke path to actual AI API contract path | Smoke output |
| AI returned 400 `Missing data detected` | Prediction window had gaps; backfill/real data not continuous | Use clean 2h real run or controlled backfill; avoid stale mixed windows | Grafana + Serving Adapter logs |
| Annotation spam every 5 min | Cooldown query lacked DynamoDB `Query` permission and stale data guard needed tightening | Added IAM `dynamodb:Query`; Prediction Lambda now has freshness guard, point annotation, cooldown/dedupe | Apply output + logs after fix |
| Dashboard hard to interpret with mixed scenarios | Multiple service/scenario series on same panel | Use service/scenario filters; for formal demo run 3 services + 1 scenario | Grafana filtered screenshots |

---

## 8. Grafana dashboard evidence

### 8.1 Current dashboard

Dashboard: `CDO08 Foresight Lens Overview`  
URL: `https://g-9411285a4b.grafana-workspace.us-east-1.amazonaws.com/d/cdo08-foresight-lens`

Current panels observed:

- CPU usage
- Memory usage
- API latency
- Queue depth
- DB connection pool
- Cache hit rate

### 8.2 Dashboard gap to fix or disclose

Telemetry contract/generator also include `active_connections`. Current dashboard should add one more panel:

- Active connections

If not fixed before presentation, explicitly mark as known gap: metric is ingested and queryable, but not yet visualized as a dedicated panel.

### 8.3 How to interpret lines

Each line is one `service_id / scenario` series for a specific metric panel.

Example:

```text
payment-gw / sudden_spike
ledger / sudden_spike
fraud-detector / sudden_spike
```

For a clean demo, filter to one scenario and show three services. If multiple scenarios are visible together, reviewer may confuse baseline vs spike lines.

### 8.4 Annotation interpretation

Grafana annotation appears as a vertical marker/triangle on the time series. Clicking it opens a popup with:

- Prediction type/tag.
- Tenant.
- Service.
- Anomaly true/false.
- Recommended action.
- Target resource.
- Confidence.
- Reasoning.
- Audit ID.
- Correlation ID.

If annotation says `service:ledger` while visible line is `payment-gw`, that means the annotation belongs to ledger and the dashboard filter/range is showing annotations across services. For final demo, filter dashboard by service or scenario before clicking annotation.

---

## 9. Security evidence

### 9.1 Security controls implemented

| Control | Implementation | Evidence needed |
|---|---|---|
| Ingest auth | API Gateway `AWS_IAM`, k6 signs request with SigV4 | API Gateway auth screenshot + k6 log |
| AI API auth | API Gateway `AWS_IAM`, Serving Adapter signs request with SigV4 | API Gateway route screenshot + code/log evidence |
| AI runtime private path | AI API Gateway → VPC Link → internal ALB → ECS private subnet | VPC Link/ALB/Target Group screenshots |
| Secret management | Grafana token in Secrets Manager, not source code | Secrets Manager metadata screenshot, no secret value |
| Encryption | KMS key, DynamoDB SSE, S3 baseline encryption | KMS/DynamoDB/S3 screenshots |
| Audit store | DynamoDB audit table with correlation lookup | Audit item screenshot |
| Least privilege | Separate roles: generator, ingest, writer, prediction, fallback, AI engine | IAM role/policy snippets |
| IAM Identity Center | Enabled for Grafana workspace login | IAM Identity Center active screenshot |

### 9.2 Negative/security tests to capture

| Test | Expected result | Evidence |
|---|---|---|
| Call ingest API without SigV4 | 403/Unauthorized | curl/awscurl screenshot |
| Payload missing required field | rejected by ingest, not written to AMP | Lambda ingest log |
| Payload with wrong tenant header/payload mismatch | rejected | Lambda ingest log |
| Prediction role tries `aps:RemoteWrite` | AccessDenied | CLI output if tested |
| Writer role tries to read audit table | AccessDenied | CLI output if tested |
| Grafana token not printed in logs | No secret in logs | CloudWatch grep/log sample |

---

## 10. Cost evidence

### 10.1 Current forecast to document

Based on the currently deployed services, monthly cost is expected to be near the cap if left running 24/7. Use Cost Explorer/Budget screenshots for measured actual.

| Cost driver | Rough monthly estimate | Note |
|---|---:|---|
| AI ECS Fargate, 2 tasks, 0.5 vCPU/1GB | ~$35-$45 | 24/7 |
| Internal ALB | ~$16-$30 | ALB hourly + LCU |
| NAT Gateway workload VPC | ~$32.85 + data | Needed for private k6 ECS outbound; should be reviewed after demo |
| VPC interface endpoints | ~$40-$45 + data | ECR/API/Logs endpoints across 2 AZs |
| Managed Grafana | ~$9-$30 | Depends active users/workspace pricing |
| AMP | Low for demo | Depends samples/query volume |
| Lambda/SQS/DynamoDB/S3/KMS/Secrets/CloudWatch | Low/moderate | Watch CloudWatch logs |
| Total rough | ~$160-$190/month | Still under `$200` only if controlled |

### 10.2 Screenshot evidence to capture

| Screenshot | Why it matters | Suggested filename |
|---|---|---|
| AWS Budget `cdo08-tf4-monthly-budget` | Proves cost guardrail exists | `aws_budget_cdo08.png` |
| Cost Explorer by service | Proves measured spend, not only estimate | `cost_explorer_by_service.png` |
| NAT Gateway hourly/cost visible | Explains major fixed cost | `nat_gateway_cost_driver.png` |
| Grafana workspace/users | Explains Grafana cost assumption | `grafana_workspace_users.png` |

---

## 11. Ops/runbook evidence

### 11.1 Terraform commands

```bash
make tf-fmt-check
make tf-validate
make tf-plan
make tf-apply
```

For raw Terraform:

```bash
terraform -chdir=infra/environments/sandbox fmt -check -recursive
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan
terraform -chdir=infra/environments/sandbox apply
```

### 11.2 Run k6 real mode for 3 services + one scenario

Use one scenario per evaluation window.

```bash
CLUSTER_NAME="$(terraform -chdir=infra/environments/sandbox output -raw generator_cluster_name)"
SUBNET_IDS="$(terraform -chdir=infra/environments/sandbox output -json workload_private_subnet_ids | jq -r 'join(",")')"
SG_ID="$(terraform -chdir=infra/environments/sandbox output -raw generator_security_group_id)"
OVERRIDES='{"containerOverrides":[{"name":"generator","environment":[{"name":"BACKFILL_MODE","value":"false"},{"name":"SCENARIO","value":"sudden_spike"},{"name":"RUN_DURATION_SECONDS","value":"7200"},{"name":"EMIT_INTERVAL_SECONDS","value":"60"},{"name":"SERVICE_LIST","value":"payment-gw,ledger,fraud-detector"},{"name":"TENANT_ID","value":"tenant-cdo08-demo"}]}]}'
aws ecs run-task --region us-east-1 --cluster "$CLUSTER_NAME" --task-definition cdo08-sandbox-generator --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SG_ID],assignPublicIp=DISABLED}" --overrides "$OVERRIDES"
```

### 11.3 Provision Grafana dashboard/datasource

Token must be stored in Secrets Manager before provisioning. Do not print or commit token.

```bash
python scripts/provision_grafana.py
```

Expected output:

```json
{
  "grafana_url": "https://g-9411285a4b.grafana-workspace.us-east-1.amazonaws.com",
  "datasource_uid": "amp-cdo08",
  "dashboard_uid": "cdo08-foresight-lens"
}
```

---

## 12. Member evidence mapping

| Member | Area | Evidence to collect |
|---|---|---|
| Thủy | Synthetic Generator ECS Fargate/k6 | ECR image tag, ECS run-task output, k6 2h summary, generator logs `status:202` |
| Phương | Telemetry Entry, SQS Buffer, DLQ | API Gateway auth, ingest Lambda validation, SQS queue drain, DLQ empty |
| Nam | Telemetry Writer and AMP Store | Writer logs, AMP query, Grafana metric lines, no secret in logs |
| Nhân | Prediction Scheduler, Serving Adapter, Fail-open | Scheduler invokes, Prediction Lambda logs, AI API success/fallback, stale/cooldown behavior |
| Quân | Grafana Overlay, Audit Store, Observability | Grafana dashboard/annotation popup, DynamoDB audit query, CloudWatch alarms |
| Quyết | Secrets, KMS, IAM Baseline, Runtime Security | KMS, Secrets Manager, IAM roles, private AI runtime, IAM Identity Center |

---

## 13. Final screenshot checklist for W12 presentation

Minimum set to collect before final presentation:

- [ ] Architecture diagram with final flow.
- [ ] Terraform apply output after final code.
- [ ] ECS AI Engine service healthy + target group healthy.
- [ ] AI smoke test health/predict success.
- [ ] k6 ECS 2h summary with `http_req_failed: 0.00%`.
- [ ] Grafana dashboard showing 3 services in one scenario.
- [ ] Grafana annotation popup with service/action/confidence/audit/correlation.
- [ ] DynamoDB audit item for the same correlation ID.
- [ ] SQS queue drained and DLQ empty.
- [ ] Cost Explorer/Budget screenshot.
- [ ] Security evidence: API Gateway IAM auth, Secrets Manager metadata, KMS key, IAM Identity Center/Grafana user.
- [ ] Failure/fix evidence: old annotation spam vs new cooldown/stale skip behavior, or at least logs after fix.
- [ ] Fallback evidence: AI timeout/503 route creates fallback audit/annotation.
- [ ] Active connections panel or documented dashboard gap.

Do not include screenshots with:

- Grafana service account token.
- AWS secret values.
- Access key/secret key.
- Full Authorization header or SigV4 signature.
- Personal email if not needed for evidence.

---

## 14. Final gaps / risks to close

| Gap | Impact if not closed | Recommended action |
|---|---|---|
| Evidence screenshots not attached | Reviewer sees claims but not raw artifact | Capture screenshots listed in §13 |
| Cost screenshot missing | W12 requires measured cost evidence | Add Cost Explorer/Budget screenshot |
| Dashboard missing `active_connections` panel | Contract metric not fully visualized | Add panel before demo or disclose |
| Annotation spam fix needs final apply/evidence | Dashboard can look noisy | Apply latest Terraform/code and capture cooldown/stale skip evidence |
| Precision/recall not fully measured | Hard requirement partially unproven | Build final scenario matrix; at minimum explain what was measured vs future work |
| Fallback path evidence not captured | Hard requirement fail-open weak | Force controlled AI failure and capture fallback annotation/audit |

---

## 15. Suggested W12 final narrative

Use this sequence in presentation:

1. Problem: silent capacity exhaustion, static threshold misses slow drift.
2. Requirement: detect early, 3 services, per-service baseline, no auto-remediation, actionable recommendation, audit.
3. Architecture: k6 → ingest → SQS → writer → AMP → prediction → AI engine → Grafana/DynamoDB.
4. Security: SigV4 at ingest and AI API, private AI runtime, IAM/KMS/Secrets, audit.
5. Demo evidence:
   - k6 emitted metrics.
   - Grafana shows metrics.
   - AI creates recommendation annotation.
   - Audit item traces the same correlation ID.
6. Reliability evidence:
   - DLQ/queue drain.
   - Fallback path.
   - Stale/cooldown dedupe to avoid alert spam.
7. Cost: under `$200/month` only with guardrails; major drivers are AI ECS, ALB, NAT, endpoints, Grafana.
8. Known gaps: active_connections panel, broader precision/recall matrix, production hardening.
