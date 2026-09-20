import json
import os
import re
import secrets
import time
from urllib.parse import quote, unquote, urlsplit


WAITER_DELAY_SECONDS = 5
WAITER_MAX_ATTEMPTS = 45
RESUME_RETRY_DELAY_SECONDS = 5
RESUME_RETRY_ATTEMPTS = 24
sleep = time.sleep
RDS_CA_BUNDLE_PATH = "/etc/ssl/rds-global-bundle.pem"
POSTGRES_IDENTIFIER_PATTERN = re.compile(r"^[a-z_][a-z0-9_]*$")
ROLE_PASSWORD_BYTES = 32


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
    # a first write has no version to fall back to, and nothing runs until the readiness apply
    if previous_version_id is None:
        return
    secrets_client.update_secret_version_stage(
        SecretId=target_secret_arn,
        VersionStage="AWSCURRENT",
        RemoveFromVersionId=new_version_id,
        MoveToVersionId=previous_version_id,
    )


def target_is_on_its_role(target, current_target):
    role_name = target.get("role_name", "")
    if not role_name or current_target is None:
        return False
    return unquote(urlsplit(current_target["SecretString"]).username or "") == role_name


def validate_identifier(kind, value):
    if not POSTGRES_IDENTIFIER_PATTERN.match(value):
        raise ValueError(f"{kind} must match {POSTGRES_IDENTIFIER_PATTERN.pattern}: {value}")


def run_statement(rds_data_client, target, sql, database=None, parameters=None):
    arguments = {
        "resourceArn": target["cluster_arn"],
        "secretArn": target["source_secret_arn"],
        "database": database or target["admin_database"],
        "sql": sql,
    }
    if parameters is not None:
        arguments["parameters"] = parameters
    return execute_statement_when_resumed(rds_data_client, **arguments)


def database_is_present(rds_data_client, target):
    database_name = target["database_name"]
    validate_identifier("database name", database_name)
    existing = run_statement(
        rds_data_client,
        target,
        "SELECT 1 FROM pg_database WHERE datname = :name",
        parameters=[{"name": "name", "value": {"stringValue": database_name}}],
    )
    return bool(existing.get("records"))


def create_database_if_absent(rds_data_client, target):
    if database_is_present(rds_data_client, target):
        return
    run_statement(rds_data_client, target, f'CREATE DATABASE "{target["database_name"]}"')


def create_login_role(rds_data_client, target, password):
    role_name = target["role_name"]
    validate_identifier("role name", role_name)
    existing = run_statement(
        rds_data_client,
        target,
        "SELECT 1 FROM pg_roles WHERE rolname = :name",
        parameters=[{"name": "name", "value": {"stringValue": role_name}}],
    )
    action = "ALTER" if existing.get("records") else "CREATE"

    # token_urlsafe emits only letters, digits, hyphen and underscore, so the literal needs no escaping
    run_statement(
        rds_data_client,
        target,
        f"{action} ROLE \"{role_name}\" WITH LOGIN PASSWORD '{password}'",
    )


def hand_database_to_role(rds_data_client, target, master_username, role_password):
    validate_identifier("master username", master_username)
    database_name = target["database_name"]
    role_name = target["role_name"]

    database_present = database_is_present(rds_data_client, target)
    create_login_role(rds_data_client, target, role_password)
    # the creator's automatic membership does not inherit, which REASSIGN OWNED needs
    run_statement(
        rds_data_client,
        target,
        f'GRANT "{role_name}" TO "{master_username}" WITH INHERIT TRUE',
    )
    if database_present:
        run_statement(rds_data_client, target, f'ALTER DATABASE "{database_name}" OWNER TO "{role_name}"')
    else:
        run_statement(rds_data_client, target, f'CREATE DATABASE "{database_name}" OWNER "{role_name}"')

    # tables the master user created before the role existed still belong to it
    run_statement(
        rds_data_client,
        target,
        f'REASSIGN OWNED BY "{master_username}" TO "{role_name}"',
        database=database_name,
    )


# a paused cluster answers the first call with DatabaseResumingException and wakes up
def execute_statement_when_resumed(rds_data_client, **arguments):
    for attempt in range(1, RESUME_RETRY_ATTEMPTS + 1):
        try:
            return rds_data_client.execute_statement(**arguments)
        except rds_data_client.exceptions.DatabaseResumingException:
            if attempt == RESUME_RETRY_ATTEMPTS:
                raise
            sleep(RESUME_RETRY_DELAY_SECONDS)


def refresh_database_secret(target, secrets_client, ecs_client, rds_data_client):
    current_target = read_target_secret(secrets_client, target["target_secret_arn"])
    role_name = target.get("role_name", "")

    # the role password never changes with the master password, so its URL stays valid
    if target_is_on_its_role(target, current_target):
        return {"name": target["name"], "changed": False}

    master_username, master_password = read_source_credentials(secrets_client, target["source_secret_arn"])
    if role_name:
        username = role_name
        password = secrets.token_urlsafe(ROLE_PASSWORD_BYTES)
    else:
        username = master_username
        password = master_password

    database_url = build_database_url(
        username,
        password,
        target["host"],
        target["port"],
        target["database_name"],
    )
    if current_target is not None and current_target["SecretString"] == database_url:
        return {"name": target["name"], "changed": False}

    # a Data API call resumes a paused cluster, so a target that is already on its role never reaches one
    if role_name:
        hand_database_to_role(rds_data_client, target, master_username, password)
    elif current_target is None and target.get("cluster_arn"):
        create_database_if_absent(rds_data_client, target)

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


def refresh_database_secrets(targets, secrets_client, ecs_client, rds_data_client):
    return [
        refresh_database_secret(target, secrets_client, ecs_client, rds_data_client)
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
            boto3.client("rds-data"),
        )
    }
