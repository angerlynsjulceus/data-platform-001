variable "yourname" {
  type = string
}

variable "region" {
  description = "AWS region. Bedrock model availability varies by region — us-east-1 supports the widest selection of models."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  type = map(string)
  default = {
    project     = "sales-intelligence"
    environment = "dev"
    managed_by  = "terraform"
  }
}
