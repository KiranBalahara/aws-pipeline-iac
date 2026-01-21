terraform {
  backend "s3" {
    bucket  = "kiran-tf-state-2026-usw2"
    key     = "aws-pipeline-iac/terraform.tfstate"
    region  = "us-west-2"
    encrypt = true
  }
}
