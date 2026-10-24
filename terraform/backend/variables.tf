variable "aws_region" {
  type        = string
  description = "The region where the resources will be located"
  default     = "us-east-1"
}

variable "unique_id" {
  type        = string
  description = "Unique id to attach to the created resources"
  default     = "dvd"
}