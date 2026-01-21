output "bucket_name" {
  value = aws_s3_bucket.lake.id
}

output "lambda_name" {
  value = aws_lambda_function.prep.function_name
}

output "glue_job_name" {
  value = aws_glue_job.etl.name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "sns_topic_arn" {
  value       = try(aws_sns_topic.pipeline_alerts[0].arn, null)
  description = "SNS topic ARN (if enable_sns=true)"
}
