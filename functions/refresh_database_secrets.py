import json
import os
from urllib.parse import quote


WAITER_DELAY_SECONDS = 5
WAITER_MAX_ATTEMPTS = 45
RDS_CA_BUNDLE_PATH = "/etc/ssl/rds-global-bundle.pem"


def build_database_url(username, password, host, port, database_name):
    encoded_username = quote(username, safe="")
    encoded_password = quote(password, safe="")
    encoded_database_name = quote(database_name, safe="")
    return (
        f"postgres://{encoded_username}:{encoded_password}@{host}:{port}/"
        f"{encoded_database_name}?sslmode=verify-full&sslrootcert={RDS_CA_BUNDLE_PATH}"
    )


def read_source_credentials(secrets_client, source_secret_arn):
    response = secrets_client.get_secret_value(SecretId=source_secret_arn)
    if "SecretString" not in response:
        raise ValueError("source database secret must contain SecretString")

    credentials = json.loads(response["SecretString"])
    if not isinstance(credentials, dict):
        raise ValueError("source database secret must contain a JSON object")

    username = credentials.get("username")
    password = credentials.get("password")
    if not isinstance(username, str) or not username:
        raise ValueError("source database secret must contain a nonempty username")
    if not isinstance(password, str) or not password:
        raise ValueError("source database secret must contain a nonempty password")

    return username, password


def read_target_secret(secrets_client, target_secret_arn):
    try:
        response = secrets_client.get_secret_value(SecretId=target_secret_arn)
    except secrets_client.exceptions.ResourceNotFoundException:
        return None

    if "SecretString" not in response:
        raise ValueError("target runtime secret must contain SecretString")
    if "VersionId" not in response:
        raise ValueError("target runtime secret must contain VersionId")
    return response


def restore_target_version(
    secrets_client,
    target_secret_arn,
    previous_version_id,
    new_version_id,
):
    update_arguments = {
        "SecretId": target_secret_arn,
        "VersionStage": "AWSCURRENT",
        "RemoveFromVersionId": new_version_id,
    }
    if previous_version_id is not None:
        update_arguments["MoveToVersionId"] = previous_version_id
    secrets_client.update_secret_version_stage(**update_arguments)


def refresh_database_secret(target, secrets_client, ecs_client):
    username, password = read_source_credentials(secrets_client, target["source_secret_arn"])
    database_url = build_database_url(
        username,
        password,
        target["host"],
        target["port"],
        target["database_name"],
    )
    current_target = read_target_secret(secrets_client, target["target_secret_arn"])
    if current_target is not None and current_target["SecretString"] == database_url:
        return {"name": target["name"], "changed": False}

    put_response = secrets_client.put_secret_value(
        SecretId=target["target_secret_arn"],
        SecretString=database_url,
    )
    if "VersionId" not in put_response:
        raise ValueError("target runtime secret write did not return VersionId")

    previous_version_id = None if current_target is None else current_target["VersionId"]
    try:
        ecs_client.update_service(
            cluster=target["cluster_name"],
            service=target["service_name"],
            forceNewDeployment=True,
        )
    except Exception:
        restore_target_version(
            secrets_client,
            target["target_secret_arn"],
            previous_version_id,
            put_response["VersionId"],
        )
        raise

    ecs_client.get_waiter("services_stable").wait(
        cluster=target["cluster_name"],
        services=[target["service_name"]],
        WaiterConfig={
            "Delay": WAITER_DELAY_SECONDS,
            "MaxAttempts": WAITER_MAX_ATTEMPTS,
        },
    )
    return {"name": target["name"], "changed": True}


def refresh_database_secrets(targets, secrets_client, ecs_client):
    return [
        refresh_database_secret(target, secrets_client, ecs_client)
        for target in targets
    ]


def handler(event, context):
    import boto3

    targets = json.loads(os.environ["DATABASE_SECRET_REFRESH_TARGETS"])
    if not isinstance(targets, list):
        raise ValueError("DATABASE_SECRET_REFRESH_TARGETS must contain a JSON list")

    return {
        "targets": refresh_database_secrets(
            targets,
            boto3.client("secretsmanager"),
            boto3.client("ecs"),
        )
    }
