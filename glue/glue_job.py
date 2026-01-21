import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, functions as F

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "input_bucket",
    "input_key",
     "rules_key"
])

spark = SparkSession.builder.getOrCreate()

import boto3

s3 = boto3.client("s3")
rules_obj = s3.get_object(Bucket=args["input_bucket"], Key=args["rules_key"])
rules_text = rules_obj["Body"].read().decode("utf-8")

print("Loaded rules.yml from S3:")
print(rules_text)


input_path = f"s3://{args['input_bucket']}/{args['input_key']}"
validated_path = f"s3://{args['input_bucket']}/validated/"
rejected_path  = f"s3://{args['input_bucket']}/rejected/"

df = (
    spark.read
    .option("header", "true")
    .option("inferSchema", "true")
    .csv(input_path)
)

# Simple validation: valid if no column is null
is_valid = None
for c in df.columns:
    cond = F.col(c).isNotNull()
    is_valid = cond if is_valid is None else (is_valid & cond)

df2 = df.withColumn("is_valid", is_valid)

valid_df = df2.filter(F.col("is_valid") == True).drop("is_valid")
bad_df   = df2.filter(F.col("is_valid") == False).drop("is_valid")

valid_df.write.mode("overwrite").parquet(validated_path)
bad_df.write.mode("overwrite").parquet(rejected_path)

print("Validated written to:", validated_path)
print("Rejected written to:", rejected_path)
