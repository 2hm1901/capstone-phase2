#!/usr/bin/env python3
import sys
import json
import subprocess

def get_tf_outputs():
    try:
        res = subprocess.run(
            ["terraform", "-chdir=infra/environments/sandbox", "output", "-json"],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(res.stdout)
    except Exception as e:
        print(f"Error getting terraform outputs: {e}")
        sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: python run-scenario.py <scenario_name> [service_id]")
        print("Scenarios: noisy_baseline, gradual_drift, sudden_spike, slow_leak")
        sys.exit(1)
        
    scenario = sys.argv[1]
    
    print("Retrieving network and cluster details from Terraform outputs...")
    outputs = get_tf_outputs()
    
    cluster = outputs["generator_cluster_name"]["value"]
    
    # Fallback to family if ARN output is not populated or exists as empty
    task_def = "cdo08-sandbox-generator"
    if "generator_task_definition_arn" in outputs and outputs["generator_task_definition_arn"]["value"]:
        task_def = outputs["generator_task_definition_arn"]["value"]
        
    subnets = ",".join(outputs["workload_private_subnet_ids"]["value"])
    sg = outputs["generator_security_group_id"]["value"]
    
    overrides = {
        "containerOverrides": [{
            "name": "generator",
            "environment": [
                {"name": "SCENARIO", "value": scenario}
            ]
        }]
    }
    
    if len(sys.argv) > 2:
        service_id = sys.argv[2]
        overrides["containerOverrides"][0]["environment"].append(
            {"name": "SERVICE_LIST", "value": service_id}
        )
        
    cmd = [
        "aws", "ecs", "run-task",
        "--cluster", cluster,
        "--task-definition", task_def,
        "--launch-type", "FARGATE",
        "--network-configuration", f"awsvpcConfiguration={{subnets=[{subnets}],securityGroups=[{sg}],assignPublicIp=DISABLED}}",
        "--overrides", json.dumps(overrides)
    ]
    
    print(f"Executing command: {' '.join(cmd)}")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        print("Task started successfully!")
        print(res.stdout)
    except Exception as e:
        print(f"Error running ECS task: {e}")
        if hasattr(e, 'stderr') and e.stderr:
            print(e.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
