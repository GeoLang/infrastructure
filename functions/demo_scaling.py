import json
import os
from datetime import datetime, timedelta, timezone

ACTIVITY_PERIOD_SECONDS = 60
ACTIVITY_UNIT = "Count"
STOPPED_DESIRED_COUNT = 0


def set_desired_counts(ecs_client, cluster_name, desired_counts):
    for service_name, desired_count in desired_counts.items():
        ecs_client.update_service(
            cluster=cluster_name,
            service=service_name,
            desiredCount=desired_count,
        )


def record_activity(cloudwatch_client, namespace, metric_name):
    cloudwatch_client.put_metric_data(
        Namespace=namespace,
        MetricData=[{"MetricName": metric_name, "Value": 1, "Unit": ACTIVITY_UNIT}],
    )


def recent_activity(cloudwatch_client, namespace, metric_name, idle_minutes, now):
    statistics = cloudwatch_client.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        StartTime=now - timedelta(minutes=idle_minutes),
        EndTime=now,
        Period=ACTIVITY_PERIOD_SECONDS,
        Statistics=["Sum"],
        Unit=ACTIVITY_UNIT,
    )
    return sum(point["Sum"] for point in statistics["Datapoints"])


def wake(ecs_client, cloudwatch_client, environment):
    # the press counts as activity so the idle check leaves the stack up while it starts
    record_activity(
        cloudwatch_client,
        environment["DEMO_ACTIVITY_METRIC_NAMESPACE"],
        environment["DEMO_ACTIVITY_METRIC_NAME"],
    )
    set_desired_counts(
        ecs_client,
        environment["DEMO_CLUSTER_NAME"],
        json.loads(environment["DEMO_RUNNING_DESIRED_COUNTS"]),
    )


def scale_down_when_idle(ecs_client, cloudwatch_client, environment, now):
    activity = recent_activity(
        cloudwatch_client,
        environment["DEMO_ACTIVITY_METRIC_NAMESPACE"],
        environment["DEMO_ACTIVITY_METRIC_NAME"],
        int(environment["DEMO_IDLE_MINUTES"]),
        now,
    )
    if activity > 0:
        return {"activity": activity, "scaled_down": False}

    service_names = json.loads(environment["DEMO_RUNNING_DESIRED_COUNTS"])
    set_desired_counts(
        ecs_client,
        environment["DEMO_CLUSTER_NAME"],
        {service_name: STOPPED_DESIRED_COUNT for service_name in service_names},
    )
    return {"activity": activity, "scaled_down": True}


def wake_handler(event, context):
    if event["requestContext"]["http"]["method"] != "POST":
        return {"statusCode": 405}

    import boto3

    wake(boto3.client("ecs"), boto3.client("cloudwatch"), os.environ)
    return {"statusCode": 202}


def idle_handler(event, context):
    import boto3

    return scale_down_when_idle(
        boto3.client("ecs"),
        boto3.client("cloudwatch"),
        os.environ,
        datetime.now(timezone.utc),
    )
