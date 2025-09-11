terraform {
  backend "s3" {
    bucket         = var.s3_bucket_name
    key            = "state/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.dynamodb_table_name
    encrypt        = true
  }
}
