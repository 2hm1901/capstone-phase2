import json
import os


def handler(event, context):
    """Placeholder Telemetry Writer.

    The Terraform task provisions the infrastructure wrapper first. The real
    remote-write implementation still needs the Prometheus payload encoding,
    compression, and SigV4 POC before shared sandbox apply.
    """
    records = event.get("Records", [])
    print(
        json.dumps(
            {
                "component": "telemetry-writer",
                "status": "placeholder",
                "batch_size": len(records),
                "amp_workspace_id": os.environ.get("AMP_WORKSPACE_ID"),
                "remote_write_status": os.environ.get("REMOTE_WRITE_STATUS"),
            }
        )
    )

    return {"batchItemFailures": []}
