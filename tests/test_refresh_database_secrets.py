import importlib.util
import json
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "functions" / "refresh_database_secrets.py"
SPECIFICATION = importlib.util.spec_from_file_location("refresh_database_secrets", MODULE_PATH)
REFRESH_DATABASE_SECRETS = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(REFRESH_DATABASE_SECRETS)


class ResourceNotFoundException(Exception):
    pass


class FakeSecretsClient:
    class exceptions:
        ResourceNotFoundException = ResourceNotFoundException

    def __init__(
        self,
        source_value,
        target_value=None,
        target_missing=False,
        target_version_id="previous-version",
    ):
        self.source_value = source_value
        self.target_value = target_value
        self.target_missing = target_missing
        self.target_version_id = target_version_id
        self.put_calls = []
        self.stage_calls = []

    def get_secret_value(self, SecretId):
        if SecretId == "source-secret":
            return {"SecretString": self.source_value}
        if self.target_missing:
            raise self.exceptions.ResourceNotFoundException()
        return {
            "SecretString": self.target_value,
            "VersionId": self.target_version_id,
        }

    def put_secret_value(self, **kwargs):
        self.put_calls.append(kwargs)
        return {"VersionId": "new-version"}

    def update_secret_version_stage(self, **kwargs):
        self.stage_calls.append(kwargs)


class DatabaseResumingException(Exception):
    pass


class FakeRdsDataClient:
    class exceptions:
        DatabaseResumingException = DatabaseResumingException

    def __init__(self, records=None, role_records=None, resuming_failures=0):
        self.records = [] if records is None else records
        self.role_records = [] if role_records is None else role_records
        self.resuming_failures = resuming_failures
        self.calls = []

    def execute_statement(self, **kwargs):
        if self.resuming_failures > 0:
            self.resuming_failures -= 1
            raise self.exceptions.DatabaseResumingException()
        self.calls.append(kwargs)
        if kwargs["sql"].startswith("SELECT 1 FROM pg_roles"):
            return {"records": self.role_records}
        if kwargs["sql"].startswith("SELECT"):
            return {"records": self.records}
        return {}


class FakeWaiter:
    def __init__(self):
        self.calls = []

    def wait(self, **kwargs):
        self.calls.append(kwargs)


class FakeEcsClient:
    def __init__(self, update_error=None):
        self.update_calls = []
        self.waiter = FakeWaiter()
        self.update_error = update_error

    def update_service(self, **kwargs):
        self.update_calls.append(kwargs)
        if self.update_error is not None:
            raise self.update_error

    def get_waiter(self, waiter_name):
        self.waiter_name = waiter_name
        return self.waiter


def target():
    return {
        "name": "ptolemy",
        "source_secret_arn": "source-secret",
        "target_secret_arn": "target-secret",
        "host": "database.example.internal",
        "port": 5432,
        "database_name": "ptolemy",
        "role_name": "",
        "cluster_arn": "",
        "admin_database": "",
        "cluster_name": "geolang-prod",
        "service_name": "geolang-prod-ptolemy",
    }


def agora_target(database_name="agora", role_name="agora"):
    return {
        "name": "agora",
        "source_secret_arn": "source-secret",
        "target_secret_arn": "target-secret",
        "host": "database.example.internal",
        "port": 5432,
        "database_name": database_name,
        "role_name": role_name,
        "cluster_arn": "arn:aws:rds:us-west-2:000152811496:cluster:geolang-prod-postgis",
        "admin_database": "ptolemy",
        "cluster_name": "geolang-prod",
        "service_name": "geolang-prod-agora",
    }


class RefreshDatabaseSecretsTests(unittest.TestCase):
    def test_build_database_url_encodes_credentials_and_database_name(self):
        database_url = REFRESH_DATABASE_SECRETS.build_database_url(
            "user@example.com",
            "pa:ss/word?",
            "database.example.internal",
            5432,
            "db/name",
        )

        self.assertEqual(
            database_url,
            "postgres://user%40example.com:pa%3Ass%2Fword%3F@database.example.internal:5432/"
            "db%2Fname?sslmode=verify-full&sslrootcert=/etc/ssl/rds-global-bundle.pem",
        )

    def test_missing_credentials_fail(self):
        secrets_client = FakeSecretsClient(json.dumps({"username": "ptolemy"}))

        with self.assertRaisesRegex(ValueError, "nonempty password"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                target(),
                secrets_client,
                FakeEcsClient(),
                FakeRdsDataClient(),
            )

    def test_unchanged_target_does_not_write_or_restart(self):
        database_url = REFRESH_DATABASE_SECRETS.build_database_url(
            "ptolemy",
            "password",
            "database.example.internal",
            5432,
            "ptolemy",
        )
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_value=database_url,
        )
        ecs_client = FakeEcsClient()

        result = REFRESH_DATABASE_SECRETS.refresh_database_secret(
            target(),
            secrets_client,
            ecs_client,
            FakeRdsDataClient(),
        )

        self.assertEqual(result, {"name": "ptolemy", "changed": False})
        self.assertEqual(secrets_client.put_calls, [])
        self.assertEqual(ecs_client.update_calls, [])
        self.assertEqual(ecs_client.waiter.calls, [])

    def test_empty_target_writes_and_restarts_once(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        ecs_client = FakeEcsClient()

        result = REFRESH_DATABASE_SECRETS.refresh_database_secret(
            target(),
            secrets_client,
            ecs_client,
            FakeRdsDataClient(),
        )

        self.assertEqual(result, {"name": "ptolemy", "changed": True})
        self.assertEqual(len(secrets_client.put_calls), 1)
        self.assertEqual(
            ecs_client.update_calls,
            [{
                "cluster": "geolang-prod",
                "service": "geolang-prod-ptolemy",
                "forceNewDeployment": True,
            }],
        )
        self.assertEqual(ecs_client.waiter_name, "services_stable")
        self.assertEqual(
            ecs_client.waiter.calls,
            [{
                "cluster": "geolang-prod",
                "services": ["geolang-prod-ptolemy"],
                "WaiterConfig": {"Delay": 5, "MaxAttempts": 45},
            }],
        )

    def test_changed_target_writes_and_restarts_once(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_value="postgres://old-value",
        )
        ecs_client = FakeEcsClient()

        result = REFRESH_DATABASE_SECRETS.refresh_database_secret(
            target(),
            secrets_client,
            ecs_client,
            FakeRdsDataClient(),
        )

        self.assertEqual(result, {"name": "ptolemy", "changed": True})
        self.assertEqual(len(secrets_client.put_calls), 1)
        self.assertEqual(len(ecs_client.update_calls), 1)
        self.assertEqual(len(ecs_client.waiter.calls), 1)

    def test_update_failure_restores_existing_target_version(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_value="postgres://old-value",
            target_version_id="previous-version",
        )
        ecs_client = FakeEcsClient(update_error=RuntimeError("update failed"))

        with self.assertRaisesRegex(RuntimeError, "update failed"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                target(),
                secrets_client,
                ecs_client,
                FakeRdsDataClient(),
            )

        self.assertEqual(
            secrets_client.stage_calls,
            [{
                "SecretId": "target-secret",
                "VersionStage": "AWSCURRENT",
                "RemoveFromVersionId": "new-version",
                "MoveToVersionId": "previous-version",
            }],
        )
        self.assertEqual(ecs_client.waiter.calls, [])

    def test_update_failure_keeps_initial_target_version(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        ecs_client = FakeEcsClient(update_error=RuntimeError("update failed"))

        with self.assertRaisesRegex(RuntimeError, "update failed"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                target(),
                secrets_client,
                ecs_client,
                FakeRdsDataClient(),
            )

        self.assertEqual(len(secrets_client.put_calls), 1)
        self.assertEqual(secrets_client.stage_calls, [])
        self.assertEqual(ecs_client.waiter.calls, [])

    def test_paused_cluster_is_retried_until_resumed(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[], resuming_failures=2)
        sleeps = []
        REFRESH_DATABASE_SECRETS.sleep = sleeps.append

        REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            FakeEcsClient(),
            rds_data_client,
        )

        self.assertEqual(sleeps, [REFRESH_DATABASE_SECRETS.RESUME_RETRY_DELAY_SECONDS] * 2)
        self.assertEqual(
            [call["sql"].split()[0] for call in rds_data_client.calls],
            ["SELECT", "SELECT", "CREATE", "CREATE", "REASSIGN"],
        )

    def test_cluster_that_never_resumes_fails(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        attempts = REFRESH_DATABASE_SECRETS.RESUME_RETRY_ATTEMPTS
        rds_data_client = FakeRdsDataClient(records=[], resuming_failures=attempts)
        REFRESH_DATABASE_SECRETS.sleep = lambda seconds: None

        with self.assertRaises(DatabaseResumingException):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                agora_target(),
                secrets_client,
                FakeEcsClient(),
                rds_data_client,
            )

        self.assertEqual(secrets_client.put_calls, [])

    def test_absent_database_is_created(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[])

        REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            FakeEcsClient(),
            rds_data_client,
        )

        self.assertEqual(len(rds_data_client.calls), 5)
        self.assertEqual(
            rds_data_client.calls[0],
            {
                "resourceArn": "arn:aws:rds:us-west-2:000152811496:cluster:geolang-prod-postgis",
                "secretArn": "source-secret",
                "database": "ptolemy",
                "sql": "SELECT 1 FROM pg_database WHERE datname = :name",
                "parameters": [{"name": "name", "value": {"stringValue": "agora"}}],
            },
        )
        self.assertEqual(
            rds_data_client.calls[3]["sql"],
            'CREATE DATABASE "agora" OWNER "agora"',
        )
        self.assertEqual(rds_data_client.calls[4]["database"], "agora")
        self.assertEqual(
            rds_data_client.calls[4]["sql"],
            'REASSIGN OWNED BY "ptolemy" TO "agora"',
        )

    def test_master_url_moves_onto_the_role(self):
        master_url = REFRESH_DATABASE_SECRETS.build_database_url(
            "ptolemy",
            "master-password",
            "database.example.internal",
            5432,
            "agora",
        )
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "master-password"}),
            target_value=master_url,
        )
        ecs_client = FakeEcsClient()
        rds_data_client = FakeRdsDataClient(records=[[{"longValue": 1}]])

        result = REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            ecs_client,
            rds_data_client,
        )

        self.assertEqual(result, {"name": "agora", "changed": True})
        self.assertEqual(
            [call["sql"].split()[0] for call in rds_data_client.calls],
            ["SELECT", "SELECT", "CREATE", "ALTER", "REASSIGN"],
        )
        self.assertEqual(
            rds_data_client.calls[3]["sql"],
            'ALTER DATABASE "agora" OWNER TO "agora"',
        )
        self.assertEqual(rds_data_client.calls[4]["database"], "agora")
        self.assertEqual(
            rds_data_client.calls[4]["sql"],
            'REASSIGN OWNED BY "ptolemy" TO "agora"',
        )
        role_password = rds_data_client.calls[2]["sql"].split("PASSWORD '")[1].rstrip("'")
        self.assertEqual(
            secrets_client.put_calls[0]["SecretString"],
            REFRESH_DATABASE_SECRETS.build_database_url(
                "agora",
                role_password,
                "database.example.internal",
                5432,
                "agora",
            ),
        )
        self.assertEqual(len(ecs_client.update_calls), 1)
        self.assertEqual(len(ecs_client.waiter.calls), 1)

    def test_written_agora_url_survives_a_master_rotation(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "rotated-password"}),
            target_value="postgres://agora:role-password@database.example.internal:5432/agora",
        )
        ecs_client = FakeEcsClient()
        rds_data_client = FakeRdsDataClient(records=[])

        result = REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            ecs_client,
            rds_data_client,
        )

        self.assertEqual(result, {"name": "agora", "changed": False})
        self.assertEqual(rds_data_client.calls, [])
        self.assertEqual(secrets_client.put_calls, [])
        self.assertEqual(ecs_client.update_calls, [])

    def test_created_database_is_owned_by_a_role_with_a_generated_password(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "master-password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[])

        REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            FakeEcsClient(),
            rds_data_client,
        )

        self.assertEqual(
            rds_data_client.calls[1],
            {
                "resourceArn": "arn:aws:rds:us-west-2:000152811496:cluster:geolang-prod-postgis",
                "secretArn": "source-secret",
                "database": "ptolemy",
                "sql": "SELECT 1 FROM pg_roles WHERE rolname = :name",
                "parameters": [{"name": "name", "value": {"stringValue": "agora"}}],
            },
        )
        role_password = rds_data_client.calls[2]["sql"].split("PASSWORD '")[1].rstrip("'")
        self.assertEqual(
            rds_data_client.calls[2]["sql"],
            f"CREATE ROLE \"agora\" WITH LOGIN PASSWORD '{role_password}'",
        )
        self.assertRegex(role_password, r"^[A-Za-z0-9_-]{40,}$")
        self.assertEqual(
            secrets_client.put_calls[0]["SecretString"],
            REFRESH_DATABASE_SECRETS.build_database_url(
                "agora",
                role_password,
                "database.example.internal",
                5432,
                "agora",
            ),
        )

    def test_rerun_after_a_failed_write_resets_the_role_password(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "master-password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(
            records=[[{"longValue": 1}]],
            role_records=[[{"longValue": 1}]],
        )

        REFRESH_DATABASE_SECRETS.refresh_database_secret(
            agora_target(),
            secrets_client,
            FakeEcsClient(),
            rds_data_client,
        )

        role_password = rds_data_client.calls[2]["sql"].split("PASSWORD '")[1].rstrip("'")
        self.assertEqual(
            rds_data_client.calls[2]["sql"],
            f"ALTER ROLE \"agora\" WITH LOGIN PASSWORD '{role_password}'",
        )
        self.assertEqual(
            secrets_client.put_calls[0]["SecretString"],
            REFRESH_DATABASE_SECRETS.build_database_url(
                "agora",
                role_password,
                "database.example.internal",
                5432,
                "agora",
            ),
        )

    def test_invalid_role_name_is_refused(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "master-password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[])

        with self.assertRaisesRegex(ValueError, "role name must match"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                agora_target(role_name='agora"; DROP DATABASE ptolemy'),
                secrets_client,
                FakeEcsClient(),
                rds_data_client,
            )

        self.assertEqual([call["sql"].split()[0] for call in rds_data_client.calls], ["SELECT"])
        self.assertEqual(secrets_client.put_calls, [])

    def test_invalid_database_name_is_refused(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": "ptolemy", "password": "password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[])

        with self.assertRaisesRegex(ValueError, "database name must match"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                agora_target(database_name='agora"; DROP DATABASE ptolemy'),
                secrets_client,
                FakeEcsClient(),
                rds_data_client,
            )

        self.assertEqual(rds_data_client.calls, [])
        self.assertEqual(secrets_client.put_calls, [])

    def test_invalid_master_username_is_refused(self):
        secrets_client = FakeSecretsClient(
            json.dumps({"username": 'ptolemy"; DROP DATABASE agora', "password": "master-password"}),
            target_missing=True,
        )
        rds_data_client = FakeRdsDataClient(records=[])

        with self.assertRaisesRegex(ValueError, "master username must match"):
            REFRESH_DATABASE_SECRETS.refresh_database_secret(
                agora_target(),
                secrets_client,
                FakeEcsClient(),
                rds_data_client,
            )

        self.assertEqual(rds_data_client.calls, [])
        self.assertEqual(secrets_client.put_calls, [])


if __name__ == "__main__":
    unittest.main()
