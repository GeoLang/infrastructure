import importlib.util
import json
import pathlib
import unittest
from datetime import datetime, timedelta, timezone


MODULE_PATH = pathlib.Path(__file__).parents[1] / "functions" / "demo_scaling.py"
SPECIFICATION = importlib.util.spec_from_file_location("demo_scaling", MODULE_PATH)
DEMO_SCALING = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(DEMO_SCALING)

NOW = datetime(2026, 9, 23, 3, 0, tzinfo=timezone.utc)
ENVIRONMENT = {
    "DEMO_CLUSTER_NAME": "geolang-prod",
    "DEMO_RUNNING_DESIRED_COUNTS": json.dumps(
        {"geolang-prod-platform-proxy": 1, "geolang-prod-geolang-api": 1}
    ),
    "DEMO_ACTIVITY_METRIC_NAMESPACE": "GeoLang/geolang-prod",
    "DEMO_ACTIVITY_METRIC_NAME": "DemoActivity",
    "DEMO_IDLE_MINUTES": "30",
}


class FakeEcsClient:
    def __init__(self):
        self.update_calls = []

    def update_service(self, **kwargs):
        self.update_calls.append(kwargs)


class FakeCloudwatchClient:
    def __init__(self, sums=()):
        self.sums = sums
        self.put_calls = []
        self.statistics_calls = []

    def put_metric_data(self, **kwargs):
        self.put_calls.append(kwargs)

    def get_metric_statistics(self, **kwargs):
        self.statistics_calls.append(kwargs)
        return {"Datapoints": [{"Sum": value} for value in self.sums]}


class DemoScalingTests(unittest.TestCase):
    def test_wake_records_activity_and_starts_every_service(self):
        ecs_client = FakeEcsClient()
        cloudwatch_client = FakeCloudwatchClient()

        DEMO_SCALING.wake(ecs_client, cloudwatch_client, ENVIRONMENT)

        self.assertEqual(
            cloudwatch_client.put_calls,
            [{
                "Namespace": "GeoLang/geolang-prod",
                "MetricData": [{"MetricName": "DemoActivity", "Value": 1, "Unit": "Count"}],
            }],
        )
        self.assertEqual(
            ecs_client.update_calls,
            [
                {"cluster": "geolang-prod", "service": "geolang-prod-platform-proxy", "desiredCount": 1},
                {"cluster": "geolang-prod", "service": "geolang-prod-geolang-api", "desiredCount": 1},
            ],
        )

    def test_idle_stack_scales_every_service_to_zero(self):
        ecs_client = FakeEcsClient()
        cloudwatch_client = FakeCloudwatchClient()

        result = DEMO_SCALING.scale_down_when_idle(ecs_client, cloudwatch_client, ENVIRONMENT, NOW)

        self.assertEqual(result, {"activity": 0, "scaled_down": True})
        self.assertEqual(
            ecs_client.update_calls,
            [
                {"cluster": "geolang-prod", "service": "geolang-prod-platform-proxy", "desiredCount": 0},
                {"cluster": "geolang-prod", "service": "geolang-prod-geolang-api", "desiredCount": 0},
            ],
        )

    def test_recent_chat_keeps_the_stack_up(self):
        ecs_client = FakeEcsClient()
        cloudwatch_client = FakeCloudwatchClient(sums=(0.0, 2.0))

        result = DEMO_SCALING.scale_down_when_idle(ecs_client, cloudwatch_client, ENVIRONMENT, NOW)

        self.assertEqual(result, {"activity": 2.0, "scaled_down": False})
        self.assertEqual(ecs_client.update_calls, [])

    def test_idle_check_reads_the_last_idle_window(self):
        cloudwatch_client = FakeCloudwatchClient()

        DEMO_SCALING.scale_down_when_idle(FakeEcsClient(), cloudwatch_client, ENVIRONMENT, NOW)

        [call] = cloudwatch_client.statistics_calls
        self.assertEqual(call["Namespace"], "GeoLang/geolang-prod")
        self.assertEqual(call["MetricName"], "DemoActivity")
        self.assertEqual(call["StartTime"], NOW - timedelta(minutes=30))
        self.assertEqual(call["EndTime"], NOW)
        self.assertEqual(call["Unit"], "Count")

    def test_wake_refuses_anything_but_post(self):
        response = DEMO_SCALING.wake_handler({"requestContext": {"http": {"method": "GET"}}}, None)

        self.assertEqual(response, {"statusCode": 405})


if __name__ == "__main__":
    unittest.main()
