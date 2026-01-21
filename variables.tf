variable "region" {
  type    = string
  default = "us-west-2"
}

variable "name_prefix" {
  type    = string
  default = "s3-glue"
}

variable "bucket_name" {
  type    = string
  default = "kiran-aws-datalake-stepfn-2026-usw2"
}

# ---------- SNS (optional) ----------
variable "enable_sns" {
  type    = bool
  default = true
}

# Put your email if you want email alerts; keep "" if you don't want subscription.
variable "alert_email" {
  type    = string
  default = ""
}

# ---------- Sample file upload (optional) ----------
variable "upload_sample_csv" {
  type    = bool
  default = false
}

# ---------- Run Step Function once during terraform apply (optional) ----------
variable "run_execution_on_apply" {
  type    = bool
  default = false
}

variable "execution_key" {
  type    = string
  default = "raw/demoLakeData.csv"
}
