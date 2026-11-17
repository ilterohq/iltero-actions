# A test unit that needs no cloud. Terraform downloads no provider for it,
# because terraform_data is built into Terraform. A web server that the CI job
# runs keeps the state outside the working directory.
terraform {
  required_version = ">= 1.4.0"

  backend "http" {}
}

resource "terraform_data" "marker" {
  input = "e2e"
}
