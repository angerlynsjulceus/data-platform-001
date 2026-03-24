variable "yourname" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type = map(string)
  default = {
    project     = "sales-intelligence"
    environment = "dev"
    managed_by  = "terraform"
  }
}
