import boto3
import pytest
from moto import mock_aws

from audit_api.storage import S3Store, parse_s3_path


def test_parse_s3_path():
    assert parse_s3_path("s3://crs-data/requests/a.json") == ("crs-data", "requests/a.json")
    with pytest.raises(ValueError):
        parse_s3_path("https://x/y")
    with pytest.raises(ValueError):
        parse_s3_path("s3://only-bucket")


@mock_aws
def test_s3_store_round_trip():
    client = boto3.client("s3", region_name="ap-south-1")
    client.create_bucket(Bucket="crs-data", CreateBucketConfiguration={"LocationConstraint": "ap-south-1"})
    store = S3Store("crs-data", client=client)
    assert not store.exists("output/a.json")
    store.write_json("output/a.json", {"ok": True})
    assert store.exists("output/a.json")
    assert not store.exists("output/a.js")          # prefix match is not enough
    assert store.read_json("output/a.json") == {"ok": True}
