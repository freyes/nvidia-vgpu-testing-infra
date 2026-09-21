.PHONY: init plan apply destroy fmt validate test

init:
	terraform -chdir=terraform init

plan:
	terraform -chdir=terraform plan

apply:
	terraform -chdir=terraform apply -auto-approve

destroy:
	terraform -chdir=terraform destroy -auto-approve

fmt:
	terraform -chdir=terraform fmt -recursive

validate:
	terraform -chdir=terraform validate

test:
	terraform -chdir=terraform test
