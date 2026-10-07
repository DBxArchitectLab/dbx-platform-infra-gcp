variable "gcp_project_id" {
  type        = string
  description = "GCP project that owns the bucket."
}

variable "bucket_name" {
  type        = string
  description = "Globally unique GCS bucket name."
}

variable "location" {
  type        = string
  description = "Bucket location; use the workspace region so clusters read and write in-region."
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow Terraform to delete the bucket even if it still contains objects."
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to the bucket (lowercase keys and values)."
}
