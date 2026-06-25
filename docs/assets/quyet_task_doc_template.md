# [TF4][W11] Quyết - Secrets, KMS, IAM Review + Encryption

**Người phụ trách:** Quyết
**Ngày:** 2026-06-25
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Trong Task Force 4, CDO08 thiết lập một hạ tầng telemetry pipeline và dự đoán AI có tính bảo mật cao. Phần nghiên cứu và triển khai của Quyết tập trung vào việc thiết kế, rà soát và cấu hình các cơ chế bảo mật cốt lõi:
- **Security baseline:** Đảm bảo toàn bộ tài nguyên cloud tuân thủ các nguyên tắc bảo mật tối thiểu, bao gồm việc mã hóa dữ liệu lưu trữ (Encryption at Rest), mã hóa đường truyền (Encryption in Transit), và ngăn chặn dữ liệu cá nhân nhạy cảm (PII) đi vào hệ thống telemetry.
- **Bảo vệ Secrets & Data stores:** Sử dụng AWS Secrets Manager để quản lý và bảo vệ các tokens động (Grafana service account token). Sử dụng AWS KMS Customer Managed Keys (CMK) để mã hóa dữ liệu audit nhạy cảm trong DynamoDB và CloudWatch Logs. Các tài nguyên khác như SQS queue, S3 bucket và AMP workspace được mã hóa bằng AWS-owned/managed keys nhằm tối ưu hóa chi phí.
- **Tách biệt vai trò (IAM Role Separation):** Phân chia chi tiết và gán IAM execution roles độc lập cho 8 thành phần hệ thống: generator, ingest, writer, prediction, fallback, AI engine, scheduler, reviewer để đảm bảo nguyên tắc đặc quyền tối thiểu (Least Privilege) và cô lập vùng ảnh hưởng (blast radius).
- **Quyết định thiết kế:** CDO08 lựa chọn giải pháp **Secrets Manager + KMS CMK + IAM Least Privilege**.
- **Rủi ro còn lại:** Chi phí cố định cho KMS CMKs ($1/key/tháng) và Secrets Manager ($0.40/secret/tháng). Team đã giảm thiểu rủi ro này bằng cách chỉ dùng CMK cho các data store nhạy cảm thực sự cần thiết (DynamoDB audit và CloudWatch Logs), còn lại sử dụng key mặc định của AWS.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Audit encrypted at rest, security baseline, no PII | Cần triển khai KMS mã hóa cho tất cả các kho lưu trữ dữ liệu, thiết lập ma trận IAM chi tiết, và xây dựng cơ chế reject PII tại tầng Ingest. |
| AI API Contract | IAM SigV4, audit logs retention 3 năm | Tuyệt đối không dùng API key tĩnh để gọi AI Engine; logs audit dự đoán phải được mã hóa KMS và cấu hình retention tối thiểu 3 năm. |
| Deployment Contract | ECS Fargate AI Engine, S3 baseline KMS, CloudWatch logs | Cấp quyền IAM role phù hợp cho ECS task của AI Engine, cấu hình default KMS cho S3 baseline bucket và cấu hình mã hóa log group cho AI Engine. |
| CDO08 docs 03 | Secrets Manager, KMS, runtime role separation | Thiết kế chi tiết và cấu hình IaC/Terraform cho Secrets Manager, KMS key policies, và ma trận IAM least privilege. |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

Cơ chế IAM, Secrets và Encryption bao phủ toàn bộ các thành phần runtime và data stores của CDO08:

```text
[Synthetic Generator] -> (IAM: execute-api:Invoke) -> [API Gateway]
                                                            │
                                                     (IAM: sqs:SendMessage)
                                                            │
                                                            ▼
[AMP (Grafana/Query)]  <- (KMS CMK/Secrets Manager) <- [Ingest Lambda]
         ▲                                                  │
         │                                            (SSE-SQS/KMS)
  (IAM: AMP Read)                                           │
         │                                                  ▼
[Fallback Lambda]      <- (IAM: Receive/Delete)    <- [SQS Queue & DLQ]
         │                                                  │
(KMS/Secrets/SigV4)                                   (IAM: Receive/Delete)
         │                                                  │
         ▼                                                  ▼
[DynamoDB Audit]       <- (IAM: PutItem/SigV4)     <- [Writer Lambda]
         ▲                                                  │
         │                                             (AMP Write)
  (IAM: PutItem)                                            │
         │                                                  ▼
[Prediction Lambda]    <- (IAM: lambda:Invoke)     <- [AMP Workspace]
         │
    (IAM SigV4)
         │
         ▼
[AI Engine ECS Fargate] (KMS / S3 baseline / CloudWatch logs)
```

### 3.2 Nó chịu trách nhiệm gì?

- **Phân loại Secrets vs Configs:** Định nghĩa rõ ràng những thông tin nào là secret cần lưu trữ bảo mật (Grafana token) và những thông tin nào chỉ là config tĩnh (AI endpoint, AMP ID) để tránh lãng phí tài nguyên và chi phí.
- **Mã hóa dữ liệu lưu trữ (Encryption at rest):** Thiết lập KMS Customer Managed Key (CMK) cho DynamoDB audit table và CloudWatch logs; cấu hình default SSE cho SQS, S3 và AMP.
- **Phân quyền đặc quyền tối thiểu (IAM Least Privilege Matrix):** Thiết kế chi tiết quyền hạn cho 8 vai trò runtime riêng biệt, tuyệt đối không dùng shared credentials hay admin privileges.
- **Kiểm soát rò rỉ (Anti-leak controls):** Ngăn chặn việc đẩy secrets lên git, ghi secret value vào log, hoặc nhúng plaintext secrets vào container image/task definition.
- **Ngăn chặn PII (PII Reject Policy):** Định nghĩa bộ lọc schema whitelist tại ingest để phát hiện và reject các payload chứa thông tin cá nhân.
- **Xây dựng kịch bản kiểm thử bảo mật (Negative Tests):** Đề xuất các ca kiểm thử phủ định cho W12 nhằm kiểm chứng tính hiệu quả của IAM và cơ chế lọc PII.

### 3.3 Nó không chịu trách nhiệm gì?

- **Không tạo admin role dùng chung:** Mọi thành phần đều phải chạy với identity và execution role riêng biệt.
- **Không can thiệp vào logic dự đoán của AI:** Chỉ chịu trách nhiệm bảo vệ dữ liệu đầu vào/đầu ra và kiểm soát quyền gọi endpoint.
- **Không cấp quyền wildcard rộng:** Hạn chế tối đa `*` trong action và resource ARN, mọi policy đều phải chỉ định resource cụ thể.
- **Không tự động sửa đổi dữ liệu payload:** Chỉ thực hiện kiểm tra và reject, không chỉnh sửa hay chuẩn hóa metric lỗi chứa PII.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | Secrets Manager + KMS + IAM least privilege |
| Lý do ban đầu | Bảo vệ Grafana token không bị lộ lọt; đáp ứng yêu cầu mã hóa của đề bài; cô lập vùng ảnh hưởng (blast radius) khi một runtime component bị compromise. |
| Input | Yêu cầu kết nối và phân quyền của Generator, Ingest, Writer, Prediction, Fallback, AI Engine, Scheduler, Reviewer. |
| Output | IAM Execution Roles/Policies, Secrets Manager config, KMS keys (CMK) & Key Policies, CloudWatch log group encryption configs. |
| Owner/runtime | Cross-cutting (Quyết phụ trách thiết kế, cấu hình Terraform và audit định kỳ). |
| Security boundary | Tách biệt hoàn toàn runtime roles, giao tiếp nội bộ dùng HTTPS/VPC Endpoint, xác thực AI bằng IAM SigV4, không dùng static credentials. |
| Observability | CloudTrail management logs (theo dõi KMS/Secrets usage), CloudWatch alarm cho Access Denied và Secret retrieval errors, CI/CD secret scanning. |
| Cost driver | Phí cố định của Secrets Manager ($0.40/secret/tháng), KMS CMK ($1/key/tháng), số lượng API requests gọi đến KMS/Secrets Manager, dung lượng lưu trữ logs audit 3 năm. |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| **Current: Secrets Manager + KMS + IAM roles** | Bảo mật tối đa, tích hợp IAM chặt chẽ, hỗ trợ rotation tự động, audit logs đầy đủ qua CloudTrail. | Tăng chi phí ($0.40/secret, $1/CMK), cấu hình IaC/Terraform phức tạp hơn. | Khi cần lưu trữ secrets động (token, password) và mã hóa dữ liệu nhạy cảm cần audit compliance cao. | **High** (Dùng cho Grafana token, DynamoDB audit table, CloudWatch logs). |
| **SSM Parameter Store (SecureString)** | Tiết kiệm chi phí (miễn phí với standard parameter), cấu hình đơn giản, tích hợp KMS tốt. | Không có tính năng tự động rotation cho external secrets; quản lý lifecycle kém linh hoạt hơn Secrets Manager. | Khi cần lưu trữ cấu hình tĩnh được mã hóa mà ít khi thay đổi (như database password tĩnh). | **Medium** (Dùng cho các biến môi trường nhạy cảm trung bình nhưng tĩnh). |
| **Plaintext Environment Variables** | Đơn giản nhất, truy xuất tức thì ở runtime, không phát sinh chi phí AWS. | Rủi ro rò rỉ cực kỳ cao qua code repo, console, CloudWatch logs, hoặc ECS task definition. | Chỉ dùng cho config thông thường không nhạy cảm (Region, Workspace ID, Endpoint URL). | **Low** (Không bao giờ dùng cho credentials hay secrets thực sự). |
| **AWS-owned keys (Default Key)** | Miễn phí hoàn toàn, không cần viết Key Policy phức tạp, AWS tự động quản lý. | Không thể cấu hình Key Policy chi tiết, không ghi nhận data events giải mã chi tiết vào CloudTrail của tài khoản khách hàng. | Dùng cho các data store lưu trữ dữ liệu infrastructure không nhạy cảm (như SQS queue telemetry thường). | **Medium** (Dùng cho SQS và S3 baseline bucket để tối ưu chi phí). |
| **Customer Managed Key (CMK) everywhere** | Kiểm soát toàn diện chính sách truy cập (Key Policy), log audit đầy đủ cho mọi thao tác mã hóa/giải mã. | Chi phí cao ($1/key/tháng cho mỗi key), giới hạn KMS requests rate, quản lý IAM/KMS policy rất phức tạp. | Khi dự án có yêu cầu tuân thủ khắt khe từ phía khách hàng hoặc mentor bắt buộc. | **Medium** (Chỉ dùng CMK cho DynamoDB Audit Table và CloudWatch Log Group của AI Engine). |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [x] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên **giữ** Secrets Manager + KMS + IAM role separation vì **3 lý do chính**:
> 1. **Đảm bảo Least Privilege và Cô lập lỗi:** Việc chia nhỏ thành 8 IAM roles độc lập giúp đảm bảo một lỗ hổng ở một component (ví dụ: Generator bị exploit) không thể dẫn đến việc rò rỉ dữ liệu lưu trữ ở các thành phần khác.
> 2. **Xóa bỏ Static Credentials:** Xác thực gọi AI Engine hoàn toàn qua IAM SigV4 và load Grafana token qua Secrets Manager giúp loại bỏ hoàn toàn việc lưu trữ API keys tĩnh trong code hay file cấu hình.
> 3. **Kiểm soát Audit Trail:** Sử dụng KMS CMK cho DynamoDB và CloudWatch logs giúp mã hóa an toàn dữ liệu nhạy cảm đồng thời ghi nhận rõ ràng nhật ký truy cập (ai đã giải mã dữ liệu gì).

### 6.2 Lý do quyết định

- **Reliability:** Các secrets được truy xuất động ở runtime thông qua SDK có cơ chế retry và caching ngắn hạn trong bộ nhớ Lambda, tránh tình trạng bị nghẽn (throttling) do vượt quá giới hạn API requests của KMS/Secrets Manager.
- **Security:** Tuân thủ tuyệt đối quy định "no static credentials", mã hóa dữ liệu tại chỗ (at rest) cho tất cả data stores, và loại bỏ hoàn toàn payload chứa dữ liệu PII tại Ingest Lambda.
- **Cost:** Tiết kiệm chi phí tối đa bằng cách chỉ dùng KMS CMK cho DynamoDB Audit và CloudWatch Audit Logs ($2/tháng), các thành phần khác (SQS, S3, AMP) sử dụng default AWS managed keys. Tổng chi phí bảo mật ước tính dưới $5/tháng, rất an toàn cho budget capstone.
- **Delivery timeline:** Thiết kế đã được module hóa bằng Terraform IaC, sẵn sàng để triển khai và thực hiện test tự động ngay trong W12.
- **Evidence:** Có kế hoạch thử nghiệm thực tế rõ ràng để cung cấp bằng chứng cho mentor (quét secret, IAM Access Denied tests, test case gửi PII bị reject).

### 6.3 Điều kiện / assumption

- Mặc định AMP sử dụng encryption mặc định của AWS (AWS-owned key) là đủ, trừ khi mentor yêu cầu bắt buộc dùng CMK riêng cho AMP workspace.
- AI Engine endpoint hỗ trợ auth qua IAM SigV4, không phát sinh thêm API key tĩnh nào khác.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| **IAM least privilege** | Tách biệt rõ rệt 8 roles: <br>1. `generator`: Chỉ được invoke API Gateway endpoint.<br>2. `ingest`: Chỉ được ghi (sqs:SendMessage) vào telemetry SQS queue.<br>3. `writer`: Đọc SQS, ghi đè (RemoteWrite) vào AMP workspace.<br>4. `prediction`: Đọc AMP, gọi AI Engine qua SigV4, ghi audit vào DynamoDB.<br>5. `fallback`: Đọc AMP, ghi audit vào DynamoDB, ghi annotation lên Grafana.<br>6. `ai-engine`: Đọc baseline từ S3/KMS, ghi logs/metrics vào CloudWatch.<br>7. `scheduler`: Chỉ được quyền trigger invoke Prediction Lambda.<br>8. `reviewer`: Chỉ có quyền read-only đối với CloudWatch logs/metrics và DynamoDB. |
| **Network exposure** | Không expose bất kỳ public inbound port nào trừ API Gateway ingest endpoint. Toàn bộ giao tiếp giữa Lambda, SQS, DynamoDB và AI Engine ECS Task chạy qua VPC Endpoints hoặc private routing nội bộ. |
| **Secrets vs Configs** | **Secrets** (Grafana service account token, API key ingest nếu có) bắt buộc lưu trữ trong AWS Secrets Manager.<br>**Configs không phải secret** (AI Engine endpoint URL, AMP Workspace ID, AWS Region, OTel collector endpoint, scheduler interval) được quản lý qua SSM Parameter Store ở dạng plaintext hoặc truyền qua Terraform variables. |
| **Encryption at rest** | DynamoDB Audit Table và CloudWatch Log Group (lưu trữ 3 năm) bắt buộc sử dụng KMS CMK. SQS queue sử dụng default SSE-SQS. S3 baseline bucket sử dụng default SSE-S3. |
| **Encryption in transit** | 100% kết nối API sử dụng HTTPS/TLS 1.2+. Không truyền token, API key qua query parameters, headers hoặc log message dạng plaintext. |
| **PII/log redaction** | Thiết lập schema whitelist nghiêm ngặt tại Ingest Lambda. Bất kỳ request payload nào chứa chuỗi ký tự dạng email, phone number, token hoặc credit card sẽ bị reject lập tức. Logs hệ thống chỉ ghi nhận metadata của request bị reject, tuyệt đối không log raw body chứa PII. |
| **Tenant isolation** | Ràng buộc metadata `tenant_id` trong mọi message và log. Ingest Lambda đối chiếu `X-Tenant-Id` header với `tenant_id` trong payload body để đảm bảo tính nhất quán dữ liệu trước khi gửi vào queue. |

### Negative test đề xuất:

- [x] **Test IAM Least Privilege (Generator):** Kiểm tra xem Generator task có thể thực hiện `sqs:SendMessage` trực tiếp hoặc write trực tiếp vào AMP hay không -> Kết quả mong muốn: `AccessDenied`.
- [x] **Test IAM Least Privilege (Reviewer):** Sử dụng Reviewer credentials để gọi `secretsmanager:GetSecretValue` trên Grafana secret -> Kết quả mong muốn: `AccessDenied`.
- [x] **Test IAM Least Privilege (Writer):** Thử nghiệm dùng Writer Lambda role để ghi dữ liệu vào DynamoDB audit table hoặc xóa CloudWatch logs -> Kết quả mong muốn: `AccessDenied`.
- [x] **Test PII Reject:** Gửi một payload telemetry mẫu chứa trường email (`test@example.com`) hoặc số điện thoại qua API Gateway -> Kết quả mong muốn: Ingest Lambda trả về HTTP `400 Bad Request` hoặc `403 Forbidden` kèm log reject metadata.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- **CloudTrail logs:** Theo dõi hành động gọi API `GetSecretValue` của Secrets Manager và `Decrypt` của KMS key để đảm bảo chỉ có đúng các Lambda/Fargate roles hợp lệ mới thực thi được.
- **Access Denied logs:** Lưu trữ kết quả chạy các ca negative test trong CI/CD hoặc môi trường staging để làm bằng chứng (evidence) kiểm thử.
- **CI/CD Secret Scan logs:** Lưu log quét mã nguồn từ các tool scan secret (Trufflehawk/GitGuardian) để chứng minh không có secret nào bị commit vào repository.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| `secret_retrieval_error` | Phát hiện lỗi phân quyền hoặc lỗi kết nối khi lấy token từ Secrets Manager. | >0 |
| `kms_access_denied` | Phát hiện hành vi truy cập KMS key không hợp lệ hoặc sai IAM policy. | >0 |
| `pii_reject_count` | Giám sát số lượng request chứa PII bị reject tại layer Ingest (cảnh báo tấn công hoặc lỗi generator). | >5 (hoặc tăng đột biến trong 5 phút) |
| `audit_log_delivery_error` | Cảnh báo khi dữ liệu audit dự đoán không thể ghi xuống DynamoDB/CloudWatch. | >0 |

### 8.3 W12 evidence cần attach

- [x] Ma trận phân quyền IAM chi tiết (IAM Matrix Markdown & Terraform configs).
- [x] Logs/Screenshots chứng minh hành vi "Access Denied" khi test negative cases.
- [x] Terraform resource configuration cho KMS key và DynamoDB/CloudWatch SSE config.
- [x] CI/CD build log chứng minh Secret Scan không phát hiện secret.
- [x] Postman/curl log test case gửi payload chứa PII bị reject.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| **Compute/runtime** | Rất nhỏ (Độ trễ khi call Secrets Manager/KMS decrypt ở mức vài mili-giây). | Sử dụng local memory caching cho Secrets để tránh gọi API Secrets Manager liên tục trên mỗi Lambda invocation. |
| **Requests/messages** | KMS Decrypt/Encrypt calls và Secrets Manager GetSecretValue requests. | Thiết lập cache time-to-live (TTL) cho secrets; chỉ dùng CMK cho các dữ liệu thực sự cần thiết. |
| **Storage/retention** | Lưu trữ CloudWatch Logs của AI Engine trong 3 năm theo contract. | Sử dụng filter log để chỉ log các thông tin audit bắt buộc; bật DynamoDB TTL 90 ngày cho prediction audit table để tự động dọn dẹp dữ liệu. |
| **Logs/observability** | Chi phí CloudTrail ghi nhận data events của KMS và Secrets Manager. | Chỉ enable CloudTrail cho Management events và các API ghi/đọc nhạy cảm; tắt log data events của các bucket không nhạy cảm. |
| **Fixed cost risk** | Chi phí cố định của Secrets Manager ($0.40/secret/tháng) và KMS CMK ($1/key/tháng). | Gom nhóm secrets nếu có thể; tránh tạo thừa KMS CMK (chỉ dùng tối đa 1-2 CMK cho toàn bộ platform CDO08). |
