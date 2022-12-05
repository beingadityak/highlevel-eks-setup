terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=4.45"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=2.16"
    }
  }

  required_version = "> 1.1.0"

  backend "s3" {
    bucket  = "highlevel-assignment-terraform-tfstate"
    key     = "assignment/state"
    region  = "us-west-2"
    profile = "interviewsandbox"
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "interviewsandbox"
}

data "aws_availability_zones" "azs" {
  state = "available"
}

data "aws_caller_identity" "current" {}