# State bucket is created by terraform/bootstrap. Replace PROJECT_ID with your
# project (or run `buzzctl infra init dev`, which fills it from bootstrap output).
terraform {
  backend "gcs" {
    bucket = "PROJECT_ID-buzz-tfstate"
    prefix = "buzz/staging"
  }
}
