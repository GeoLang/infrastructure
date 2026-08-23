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
        "cluster_name": "geolang-prod",
        "service_name": "geolang-prod-ptolemy",
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

    def test_update_failure_removes_initial_target_current_version(self):
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
            )

        self.assertEqual(
            secrets_client.stage_calls,
            [{
                "SecretId": "target-secret",
                "VersionStage": "AWSCURRENT",
                "RemoveFromVersionId": "new-version",
            }],
        )
        self.assertEqual(ecs_client.waiter.calls, [])


if __name__ == "__main__":
    unittest.main()
