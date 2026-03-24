variable "yourname" {
  description = "Your name suffix used in all resource names. Lowercase, no spaces."
  type        = string
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project     = "sales-intelligence"
    environment = "dev"
    managed_by  = "terraform"
  }
}

variable "db_password" {
  description = "RDS MySQL root password"
  type        = string
  sensitive   = true
}

variable "allowed_cidr" {
  description = "CIDR block allowed to connect to RDS on port 3306. Use your IP e.g. 203.0.113.0/32"
  type        = string
}
