import uuid

def lambda_handler(event, context=None):
    bucket = event.get("bucket")
    key = event.get("key")

    if not bucket or not key:
        raise ValueError("Input must include 'bucket' and 'key'")

    return {
        "input_bucket": bucket,
        "input_key": key,
        "run_id": str(uuid.uuid4())
    }
