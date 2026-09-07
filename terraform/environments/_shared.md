Each environment directory is a self-contained Terraform root: its own state,
its own tfvars, its own blast radius. `main.tf` is intentionally identical
across dev/staging/prod — everything that differs is a variable. Diffing two
`terraform.tfvars` files should tell you the whole story of how the
environments differ.
