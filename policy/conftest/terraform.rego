# Policy checks over a Terraform plan.
#
#   terraform -chdir=terraform/environments/prod show -json tfplan > plan.json
#   conftest test --policy policy/conftest --namespace terraform plan.json
#
# These are the platform invariants that must not regress. They duplicate the
# assertions in tests/lint_terraform.py deliberately: that script reads source
# and can be fooled by a variable default, whereas a plan carries the values
# that will actually be applied.

package terraform

import rego.v1

resources(kind) := [r |
	some r in input.resource_changes
	r.type == kind
	# Ignore deletions; a resource being removed has no posture to check.
	"delete" != r.change.actions[_]
]

after(r) := r.change.after

# ── Cluster ──────────────────────────────────────────────────────────────────

deny contains msg if {
	some r in resources("google_container_cluster")
	cfg := after(r).private_cluster_config[0]
	cfg.enable_private_nodes != true
	msg := sprintf("%s: nodes must be private. Public node IPs put every workload directly on the internet.", [r.address])
}

deny contains msg if {
	some r in resources("google_container_cluster")
	count(after(r).workload_identity_config) == 0
	msg := sprintf("%s: Workload Identity must be enabled. Without it pods inherit the node service account.", [r.address])
}

deny contains msg if {
	some r in resources("google_container_cluster")
	count(after(r).database_encryption) == 0
	msg := sprintf("%s: application-layer Secret encryption (CMEK) must be configured.", [r.address])
}

deny contains msg if {
	some r in resources("google_container_cluster")
	after(r).datapath_provider != "ADVANCED_DATAPATH"
	msg := sprintf("%s: Dataplane V2 is required. Without it NetworkPolicy objects are accepted and silently unenforced.", [r.address])
}

# ── Nodes ────────────────────────────────────────────────────────────────────

deny contains msg if {
	some r in resources("google_container_node_pool")
	cfg := after(r).node_config[0]
	cfg.workload_metadata_config[0].mode != "GKE_METADATA"
	msg := sprintf("%s: workload metadata mode must be GKE_METADATA so pods cannot read the node's instance credentials.", [r.address])
}

deny contains msg if {
	some r in resources("google_container_node_pool")
	cfg := after(r).node_config[0]
	cfg.shielded_instance_config[0].enable_secure_boot != true
	msg := sprintf("%s: secure boot must be enabled.", [r.address])
}

deny contains msg if {
	some r in resources("google_container_node_pool")
	cfg := after(r).node_config[0]
	not cfg.service_account
	msg := sprintf("%s: node pools must use a dedicated service account, never the default compute identity.", [r.address])
}

# ── Data services ────────────────────────────────────────────────────────────

deny contains msg if {
	some r in resources("google_sql_database_instance")
	cfg := after(r).settings[0].ip_configuration[0]
	cfg.ipv4_enabled != false
	msg := sprintf("%s: Cloud SQL must not have a public IP.", [r.address])
}

deny contains msg if {
	some r in resources("google_sql_database_instance")
	backup := after(r).settings[0].backup_configuration[0]
	backup.enabled != true
	msg := sprintf("%s: automated backups must be enabled.", [r.address])
}

deny contains msg if {
	some r in resources("google_redis_instance")
	after(r).auth_enabled != true
	msg := sprintf("%s: Redis AUTH must be enabled even on a private network.", [r.address])
}

# ── Storage ──────────────────────────────────────────────────────────────────

deny contains msg if {
	some r in resources("google_storage_bucket")
	after(r).public_access_prevention != "enforced"
	msg := sprintf("%s: public access prevention must be enforced.", [r.address])
}

deny contains msg if {
	some r in resources("google_storage_bucket")
	after(r).uniform_bucket_level_access != true
	msg := sprintf("%s: uniform bucket-level access must be enabled.", [r.address])
}

# ── IAM ──────────────────────────────────────────────────────────────────────
# A service-account key is a long-lived credential that can leak into a repo, a
# log, or a laptop. Every identity here uses Workload Identity instead.

deny contains msg if {
	some r in resources("google_service_account_key")
	msg := sprintf("%s: service-account keys are not permitted. Use Workload Identity or Workload Identity Federation.", [r.address])
}

primitive_roles := {"roles/owner", "roles/editor"}

deny contains msg if {
	some r in resources("google_project_iam_member")
	after(r).role in primitive_roles
	msg := sprintf("%s: grants %s at the project level. Use a narrow predefined role.", [r.address, after(r).role])
}

# ── Warnings ─────────────────────────────────────────────────────────────────

warn contains msg if {
	some r in resources("google_container_cluster")
	cfg := after(r).private_cluster_config[0]
	cfg.enable_private_endpoint != true
	msg := sprintf("%s: the control plane has a public endpoint. Acceptable in dev with master_authorized_networks set; not above it.", [r.address])
}

warn contains msg if {
	some r in resources("google_sql_database_instance")
	after(r).settings[0].availability_type != "REGIONAL"
	msg := sprintf("%s: availability_type is not REGIONAL. A zonal instance has no automatic failover.", [r.address])
}

warn contains msg if {
	some r in resources("google_compute_security_policy")
	some rule in after(r).rule
	rule.priority == 1000
	"0.0.0.0/0" in rule.match[0].config[0].src_ip_ranges
	msg := sprintf("%s: the source allowlist is open to the internet. Deliberate for remote staff; narrow it if every client is on the corporate network.", [r.address])
}
