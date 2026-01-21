terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}

provider "aws" {
  region = var.region
}

############################
# S3 BUCKET
############################
resource "aws_s3_bucket" "lake" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

############################
# OPTIONAL: UPLOAD SAMPLE CSV INTO raw/
############################
resource "aws_s3_object" "sample_csv" {
  count   = var.upload_sample_csv ? 1 : 0
  bucket  = aws_s3_bucket.lake.id
  key     = var.execution_key
  content = "a,b\n1,2\n3,4\n"
}

############################
# PACKAGE + UPLOAD LAMBDA ZIP
############################
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.lake.id
  key    = "artifacts/lambda/lambda.zip"
  source = data.archive_file.lambda_zip.output_path
}

############################
# LAMBDA IAM ROLE + POLICY
############################
resource "aws_iam_role" "lambda_role" {
  name = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.lake.arn,
          "${aws_s3_bucket.lake.arn}/*"
        ]
      }
    ]
  })
}

############################
# LAMBDA FUNCTION
############################
resource "aws_lambda_function" "prep" {
  function_name = "${var.name_prefix}-prep"
  role          = aws_iam_role.lambda_role.arn

  s3_bucket = aws_s3_bucket.lake.id
  s3_key    = aws_s3_object.lambda_zip.key

  handler = "handler.lambda_handler"
  runtime = "python3.11"
  timeout = 30
}

############################
# GLUE IAM ROLE + POLICY
############################
resource "aws_iam_role" "glue_role" {
  name = "${var.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue_policy" {
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.lake.arn,
          "${aws_s3_bucket.lake.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

############################
# UPLOAD GLUE SCRIPT TO S3
############################
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.lake.id
  key    = "scripts/glue/glue_job.py"
  source = "${path.module}/glue/glue_job.py"
}

############################
# UPLOAD DATA QUALITY RULES
############################
resource "aws_s3_object" "dq_rules" {
  bucket = aws_s3_bucket.lake.id
  key    = "governance/ge/rules.yml"
  source = "${path.module}/governance/great_expectations/rules.yml"
}

############################
# GLUE JOB
############################
resource "aws_glue_job" "etl" {
  name     = "${var.name_prefix}-glue-etl"
  role_arn = aws_iam_role.glue_role.arn

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lake.id}/${aws_s3_object.glue_script.key}"
  }

  default_arguments = {
    "--job-language" = "python"
    "--TempDir"      = "s3://${aws_s3_bucket.lake.id}/tmp/"
  }
}

############################
# SNS (OPTIONAL)
############################
resource "aws_sns_topic" "pipeline_alerts" {
  count = var.enable_sns ? 1 : 0
  name  = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.enable_sns && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.pipeline_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  sns_topic_arn = var.enable_sns ? aws_sns_topic.pipeline_alerts[0].arn : null
  alarm_actions = var.enable_sns ? [aws_sns_topic.pipeline_alerts[0].arn] : []
}

############################
# STEP FUNCTIONS IAM ROLE + POLICY
############################
resource "aws_iam_role" "sfn_role" {
  name = "${var.name_prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["lambda:InvokeFunction"]
          Resource = aws_lambda_function.prep.arn
        },
        {
          Effect   = "Allow"
          Action   = ["glue:StartJobRun"]
          Resource = aws_glue_job.etl.arn
        }
      ],
      var.enable_sns ? [
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = aws_sns_topic.pipeline_alerts[0].arn
        }
      ] : []
    )
  })
}

############################
# STEP FUNCTIONS STATE MACHINE (RETRIES + CATCH + OPTIONAL SNS)
############################
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.name_prefix}-state-machine"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    StartAt = "LambdaInvoke"
    States = merge(
      {
        LambdaInvoke = {
          Type     = "Task"
          Resource = "arn:aws:states:::lambda:invoke"
          Parameters = {
            FunctionName = aws_lambda_function.prep.arn
            "Payload.$"  = "$"
          }
          ResultPath = "$.lambda"

          Retry = [{
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 2
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }]

          Catch = [{
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = var.enable_sns ? "NotifyFailure" : "FailState"
          }]

          Next = "GlueJob"
        }

        GlueJob = {
          Type     = "Task"
          Resource = "arn:aws:states:::glue:startJobRun.sync"
          Parameters = {
            JobName = aws_glue_job.etl.name
            Arguments = {
              "--input_bucket.$" = "$.lambda.Payload.input_bucket"
              "--input_key.$"    = "$.lambda.Payload.input_key"
              "--rules_key" = "governance/ge/rules.yml"

            }
          }

          Retry = [{
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }]

          Catch = [{
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = var.enable_sns ? "NotifyFailure" : "FailState"
          }]

          Next = var.enable_sns ? "NotifySuccess" : "SucceedState"
        }

        SucceedState = {
          Type = "Succeed"
        }

        FailState = {
          Type  = "Fail"
          Error = "PipelineFailed"
        }
      },

      var.enable_sns ? {
        NotifySuccess = {
          Type     = "Task"
          Resource = "arn:aws:states:::sns:publish"
          Parameters = {
            TopicArn    = local.sns_topic_arn
            Subject     = "Pipeline SUCCEEDED"
            "Message.$" = "$"
          }
          Next = "SucceedState"
        }

        NotifyFailure = {
          Type     = "Task"
          Resource = "arn:aws:states:::sns:publish"
          Parameters = {
            TopicArn    = local.sns_topic_arn
            Subject     = "Pipeline FAILED"
            "Message.$" = "$"
          }
          Next = "FailState"
        }
      } : {}
    )
  })
}

############################
# CLOUDWATCH ALARMS
############################

# Step Functions failures
resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name          = "${var.name_prefix}-sfn-executions-failed"
  alarm_description   = "Step Functions execution failures > 0"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline.arn
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Lambda errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-lambda-errors"
  alarm_description   = "Lambda Errors > 0"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.prep.function_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Glue failures (AWS/Glue metric name commonly used)
resource "aws_cloudwatch_metric_alarm" "glue_failed" {
  alarm_name          = "${var.name_prefix}-glue-job-failed"
  alarm_description   = "Glue job failures > 0"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "GlueJobRunFailed"
  namespace           = "AWS/Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = aws_glue_job.etl.name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

############################
# CLOUDWATCH DASHBOARD
############################
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.name_prefix}-pipeline-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions - ExecutionsFailed"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.pipeline.arn]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda - Errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.prep.function_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Glue - Job Run Failed"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Glue", "GlueJobRunFailed", "JobName", aws_glue_job.etl.name]
          ]
        }
      }
    ]
  })
}

############################
# OPTIONAL: RUN STEP FUNCTION ON APPLY (PowerShell-safe)
############################
resource "null_resource" "run_execution" {
  count = var.run_execution_on_apply ? 1 : 0

  depends_on = [
    aws_sfn_state_machine.pipeline,
    aws_lambda_function.prep,
    aws_glue_job.etl,
    aws_s3_object.glue_script,
    aws_s3_object.lambda_zip
  ]

  triggers = {
    bucket = aws_s3_bucket.lake.id
    key    = var.execution_key
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.pipeline.arn} --input file://sf_input.json"
  }
}
