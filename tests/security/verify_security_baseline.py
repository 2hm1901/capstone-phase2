import json
import boto3
import sys
from botocore.exceptions import ClientError

# Constants
REGION = "us-east-1"
PREFIX = "cdo08-sandbox"
BUCKET_NAME = "cdo08-sandbox-ai-baselines-894597652722"
KMS_ALIAS = "alias/cdo08-sandbox-kms-key"
BUDGET_NAME = "cdo08-sandbox-budget-guardrail"
SECRET_ARN = "arn:aws:secretsmanager:us-east-1:894597652722:secret:cdo08-sandbox-grafana-token-gZj9fV"
AUDIT_TABLE = "cdo08-sandbox-audit"
INGEST_LAMBDA = "cdo08-sandbox-ingest"
REVIEWER_ROLE = "arn:aws:iam::894597652722:role/cdo08-sandbox-reviewer-role"
GENERATOR_ROLE = "arn:aws:iam::894597652722:role/cdo08-sandbox-generator-role"

s3_client = boto3.client("s3", region_name=REGION)
kms_client = boto3.client("kms", region_name=REGION)
budgets_client = boto3.client("budgets", region_name=REGION)
logs_client = boto3.client("logs", region_name=REGION)
sts_client = boto3.client("sts", region_name=REGION)
lambda_client = boto3.client("lambda", region_name=REGION)

def log_success(msg):
    print(f"[OK] SUCCESS: {msg}")

def log_failure(msg):
    print(f"[X] FAILURE: {msg}")

def log_info(msg):
    print(f"[-] INFO: {msg}")

# 1. Verify S3 Baseline
def verify_s3():
    print("\n--- Verifying S3 Baseline Bucket ---")
    try:
        # Versioning
        ver = s3_client.get_bucket_versioning(Bucket=BUCKET_NAME)
        if ver.get("Status") == "Enabled":
            log_success("S3 Versioning is Enabled")
        else:
            log_failure("S3 Versioning is NOT Enabled")

        # Public Access Block
        pab = s3_client.get_public_access_block(Bucket=BUCKET_NAME)
        config = pab.get("PublicAccessBlockConfiguration", {})
        if all(config.values()):
            log_success("S3 Block Public Access is fully enabled")
        else:
            log_failure("S3 Block Public Access is NOT fully enabled")

        # Encryption
        enc = s3_client.get_bucket_encryption(Bucket=BUCKET_NAME)
        rules = enc.get("ServerSideEncryptionConfiguration", {}).get("Rules", [])
        if rules and rules[0].get("ApplyServerSideEncryptionByDefault", {}).get("SSEAlgorithm") == "aws:kms":
            log_success("S3 Server Side Encryption is set to aws:kms")
        else:
            log_failure("S3 Server Side Encryption is NOT set to aws:kms")

        # Policy (TLS-only)
        policy_res = s3_client.get_bucket_policy(Bucket=BUCKET_NAME)
        policy_str = policy_res.get("Policy", "")
        if "aws:SecureTransport" in policy_str and "Deny" in policy_str:
            log_success("S3 TLS-only bucket policy is active")
        else:
            log_failure("S3 TLS-only bucket policy is NOT active")
    except Exception as e:
        log_failure(f"S3 verification failed: {e}")

# 2. Verify KMS Alias & Rotation
def verify_kms():
    print("\n--- Verifying KMS Key ---")
    try:
        # Get target key id from alias
        aliases = kms_client.list_aliases()
        target_key_id = None
        for a in aliases.get("Aliases", []):
            if a.get("AliasName") == KMS_ALIAS:
                target_key_id = a.get("TargetKeyId")
                break
        if not target_key_id:
            log_failure(f"KMS Alias {KMS_ALIAS} not found")
            return

        # Rotation status
        rot = kms_client.get_key_rotation_status(KeyId=target_key_id)
        if rot.get("KeyRotationEnabled"):
            log_success("KMS Key Rotation is Enabled")
        else:
            log_failure("KMS Key Rotation is NOT Enabled")
    except Exception as e:
        log_failure(f"KMS verification failed: {e}")

# 3. Verify Budget
def verify_budget(account_id):
    print("\n--- Verifying AWS Budget ---")
    try:
        budgets = budgets_client.describe_budgets(AccountId=account_id)
        target_budget = None
        for b in budgets.get("Budgets", []):
            if b.get("BudgetName") == BUDGET_NAME:
                target_budget = b
                break
        
        if target_budget:
            limit = target_budget.get("BudgetLimit", {}).get("Amount")
            unit = target_budget.get("BudgetLimit", {}).get("Unit")
            log_success(f"Budget found: {BUDGET_NAME} limit is {limit} {unit}")
            
            # Notifications
            notifs = budgets_client.describe_notifications_for_budget(
                AccountId=account_id,
                BudgetName=BUDGET_NAME
            )
            thresholds = [int(n.get("Threshold")) for n in notifs.get("Notifications", [])]
            log_success(f"Budget alert thresholds configured at: {thresholds}%")
        else:
            log_failure(f"Budget {BUDGET_NAME} not found (might not be applied yet)")
    except Exception as e:
        log_failure(f"Budget verification failed: {e}")

# 4. Verify Log Groups
def verify_logs():
    print("\n--- Verifying CloudWatch Log Groups ---")
    try:
        # App Log Group
        app_lg_name = f"/ecs/{PREFIX}-ai-engine-app"
        app_lgs = logs_client.describe_log_groups(logGroupNamePrefix=app_lg_name)
        app_lg = next((lg for lg in app_lgs.get("logGroups", []) if lg.get("logGroupName") == app_lg_name), None)
        if app_lg:
            ret = app_lg.get("retentionInDays")
            if ret == 14:
                log_success(f"App Log Group retention is {ret} days (Design target: 14 days)")
            else:
                log_failure(f"App Log Group retention is {ret} days (Expected: 14)")
        else:
            log_failure(f"App Log Group {app_lg_name} not found")

        # Audit Log Group
        audit_lg_name = f"/ecs/{PREFIX}-ai-engine-audit"
        audit_lgs = logs_client.describe_log_groups(logGroupNamePrefix=audit_lg_name)
        audit_lg = next((lg for lg in audit_lgs.get("logGroups", []) if lg.get("logGroupName") == audit_lg_name), None)
        if audit_lg:
            ret = audit_lg.get("retentionInDays")
            kms_key = audit_lg.get("kmsKeyId")
            if ret == 365:
                log_success(f"Audit Log Group retention is {ret} days (Design target: 365 days)")
            else:
                log_failure(f"Audit Log Group retention is {ret} days (Expected: 365)")
            if kms_key:
                log_success("Audit Log Group is KMS encrypted")
            else:
                log_failure("Audit Log Group is NOT KMS encrypted")
        else:
            log_failure(f"Audit Log Group {audit_lg_name} not found")
    except Exception as e:
        log_failure(f"Logs verification failed: {e}")

# 5. Negative Test: Reviewer Role
def negative_test_reviewer():
    print("\n--- Running Reviewer Negative Tests ---")
    try:
        sts_client.get_caller_identity()
    except Exception as e:
        log_failure(f"STS connection failed: {e}")
        return

    assumed_credentials = None
    try:
        assumed_role = sts_client.assume_role(
            RoleArn=REVIEWER_ROLE,
            RoleSessionName="ReviewerNegativeTest"
        )
        assumed_credentials = assumed_role["Credentials"]
        log_info(f"Assumed role {REVIEWER_ROLE} successfully")
    except ClientError as e:
        if "AccessDenied" in str(e) or "NoSuchEntity" in str(e):
            log_info(f"Reviewer role cannot be assumed or does not exist (Expected if reviewer_principal_arns is empty)")
            return
        else:
            log_failure(f"Error assuming reviewer role: {e}")
            return

    # If assumed, perform negative tests
    session = boto3.Session(
        aws_access_key_id=assumed_credentials["AccessKeyId"],
        aws_secret_access_key=assumed_credentials["SecretAccessKey"],
        aws_session_token=assumed_credentials["SessionToken"]
    )
    
    # Check Secrets Manager GetSecretValue
    sm_reviewer = session.client("secretsmanager", region_name=REGION)
    try:
        sm_reviewer.get_secret_value(SecretId=SECRET_ARN)
        log_failure("Reviewer was able to read Grafana Token secret! (Security breach)")
    except ClientError as e:
        if "AccessDenied" in str(e):
            log_success("Negative Test Passed: Reviewer is DENIED access to Grafana Token secret")
        else:
            log_failure(f"Unexpected error on secret read: {e}")

    # Check DynamoDB Write/Delete
    ddb_reviewer = session.client("dynamodb", region_name=REGION)
    try:
        ddb_reviewer.put_item(
            TableName=AUDIT_TABLE,
            Item={
                "tenant_service": {"S": "test#test"},
                "prediction_id": {"S": "test-id"},
                "correlation_id": {"S": "test-corr"}
            }
        )
        log_failure("Reviewer was able to write to DynamoDB audit table! (Security breach)")
    except ClientError as e:
        if "AccessDenied" in str(e):
            log_success("Negative Test Passed: Reviewer is DENIED write access to DynamoDB audit table")
        else:
            log_failure(f"Unexpected error on DynamoDB write: {e}")

    try:
        ddb_reviewer.delete_item(
            TableName=AUDIT_TABLE,
            Key={
                "tenant_service": {"S": "test#test"},
                "prediction_id": {"S": "test-id"}
            }
        )
        log_failure("Reviewer was able to delete from DynamoDB audit table! (Security breach)")
    except ClientError as e:
        if "AccessDenied" in str(e):
            log_success("Negative Test Passed: Reviewer is DENIED delete access to DynamoDB audit table")
        else:
            log_failure(f"Unexpected error on DynamoDB delete: {e}")

# 6. Negative Test: Ingest Tenant Mismatch
def test_tenant_mismatch():
    print("\n--- Running Tenant Mismatch Ingest Test ---")
    try:
        # Valid event body
        payload = {
            "ts": 1774888800,
            "tenant_id": "tenant-cdo08-demo",
            "service_id": "payment-api",
            "metric_type": "cpu_usage_percent",
            "value": 45.5,
            "labels": {
                "env": "sandbox"
            }
        }
        
        # 1. Test Match (Valid)
        response_match = lambda_client.invoke(
            FunctionName=INGEST_LAMBDA,
            InvocationType="RequestResponse",
            Payload=json.dumps({
                "headers": {
                    "X-Tenant-Id": "tenant-cdo08-demo",
                    "X-Correlation-Id": "test-match-corr-id"
                },
                "body": json.dumps(payload)
            })
        )
        res_payload_match = json.loads(response_match["Payload"].read().decode("utf-8"))
        # Parse body from API Gateway Proxy integration response if wrapped
        body_match = res_payload_match
        if isinstance(res_payload_match, dict) and "body" in res_payload_match:
            body_match = json.loads(res_payload_match["body"])
            statusCode = res_payload_match.get("statusCode")
        else:
            statusCode = 202 if "status" in res_payload_match else 400
            
        if statusCode == 202 or (isinstance(body_match, dict) and body_match.get("status") == "accepted"):
            log_success("Ingest accepted request with matching tenant header")
        else:
            log_failure(f"Ingest rejected request with matching tenant header: {res_payload_match}")

        # 2. Test Mismatch (Invalid)
        response_mismatch = lambda_client.invoke(
            FunctionName=INGEST_LAMBDA,
            InvocationType="RequestResponse",
            Payload=json.dumps({
                "headers": {
                    "X-Tenant-Id": "tenant-mismatch-attack",
                    "X-Correlation-Id": "test-mismatch-corr-id"
                },
                "body": json.dumps(payload)
            })
        )
        res_payload_mismatch = json.loads(response_mismatch["Payload"].read().decode("utf-8"))
        body_mismatch = res_payload_mismatch
        if isinstance(res_payload_mismatch, dict) and "body" in res_payload_mismatch:
            body_mismatch = json.loads(res_payload_mismatch["body"])
            statusCode = res_payload_mismatch.get("statusCode")
        else:
            statusCode = 403 if "error" in res_payload_mismatch and res_payload_mismatch["error"] == "tenant_mismatch" else 200
            
        if statusCode == 403 or (isinstance(body_mismatch, dict) and body_mismatch.get("error") == "tenant_mismatch"):
            log_success("Negative Test Passed: Ingest rejected request with mismatched tenant header (statusCode 403)")
        else:
            log_failure(f"Security breach: Ingest accepted or did not properly deny mismatched tenant request: {res_payload_mismatch}")
    except Exception as e:
        log_failure(f"Tenant mismatch test failed: {e}")

if __name__ == "__main__":
    sts = boto3.client("sts")
    try:
        identity = sts.get_caller_identity()
        account_id = identity["Account"]
        log_info(f"Running validations on AWS Account: {account_id}")
    except Exception as e:
        log_failure(f"Cannot connect to AWS API: {e}")
        sys.exit(1)

    verify_s3()
    verify_kms()
    verify_budget(account_id)
    verify_logs()
    negative_test_reviewer()
    test_tenant_mismatch()
