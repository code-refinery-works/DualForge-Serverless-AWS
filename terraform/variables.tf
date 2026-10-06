variable "aws_region" {
  type        = string
  description = "AWS region to deploy resources"
  default     = "ap-northeast-1"
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier (e.g. ap-northeast-1)."
  }
}

variable "project" {
  type        = string
  description = "Project name used as resource name prefix"
  default     = "myapp"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,16}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-17 chars, starting with a letter."
  }
}

variable "env" {
  type        = string
  description = "Deployment environment (dev | stg | prod)"
  default     = "dev"
  validation {
    condition     = contains(["dev", "stg", "prod"], var.env)
    error_message = "env must be one of: dev, stg, prod."
  }
}