output "state_bucket" {
  description = "Terraform remote-state bucket. Copy into terraform/environments/*/backend.tf."
  value       = google_storage_bucket.tfstate.name
}

output "workload_identity_provider" {
  description = "Full provider resource name for the google-github-actions/auth step."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account" {
  description = "Service account GitHub Actions impersonates."
  value       = google_service_account.ci_deployer.email
}

output "github_actions_auth_snippet" {
  description = "Drop-in configuration for the auth step in .github/workflows."
  value = <<-EOT
    - uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${google_iam_workload_identity_pool_provider.github.name}
        service_account: ${google_service_account.ci_deployer.email}
  EOT
}
