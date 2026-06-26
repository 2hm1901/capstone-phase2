# Telemetry Ingest Terraform Module

## Overview

This Terraform module provisions the telemetry ingestion entry point for the TF4 platform.

The module creates the infrastructure required to receive telemetry data before it is processed by downstream components.

Provisioned resources include:

* API Gateway HTTP API (`POST /v1/telemetry`)
* Lambda Ingest wrapper
* Amazon SQS Telemetry Queue
* Amazon SQS Dead Letter Queue (DLQ)
* IAM Role and Least-Privilege Policy for Lambda
* CloudWatch Log Group
* CloudWatch Alarms
* Module outputs for downstream integration

## Architecture

```text
Generator / Service
        │
        ▼
API Gateway
        │
        ▼
Lambda Ingest
        │
        ├── Invalid Request
        │      └── Reject + CloudWatch Log
        │
        └── Valid Request
               │
               ▼
      SQS Telemetry Queue
               │
               ▼
        Writer Lambda
               │
               ▼
 Amazon Managed Prometheus

Failure
   │
   ▼
Telemetry DLQ
   │
   ▼
Manual Review / Replay
```

## Security

* HTTPS endpoint
* IAM authentication (AWS_IAM)
* API throttling
* Least-privilege IAM policy
* SQS Server-Side Encryption (SSE)
* Queue Redrive Policy
* CloudWatch logging

## Module Outputs

The module exports:

* API Endpoint
* Authentication Mode
* Telemetry Queue URL / ARN / Name
* DLQ URL / ARN / Name
* Lambda Function Name / ARN

These outputs are consumed by downstream platform components.

## Notes

This module provisions infrastructure only.

Business validation such as:

* Telemetry schema validation
* Metric type validation
* Tenant validation
* PII rejection
* Correlation ID generation

is implemented by the Lambda application, not by Terraform.
