terraform {
  backend "s3" {
    bucket         = "amithms"              
    key            = "state/terraform.tfstate"
    region         = "us-east-1"           
    dynamodb_table = "terraform-locks-amith"      
    encrypt        = true
  }
}
