.PHONY: init plan apply infra cluster deploy deploy-app destroy clean all

ANSIBLE := cd ansible && ansible-playbook -i inventory.ini
TERRAFORM := cd terraform && terraform

all: infra cluster deploy-app

init:
	$(TERRAFORM) init

plan:
	$(TERRAFORM) plan

apply:
	$(TERRAFORM) apply -auto-approve

infra: init apply
	$(TERRAFORM) output -raw > /dev/null

cluster:
	$(ANSIBLE) site.yml --tags os,k8s,cni,verify

deploy:
	$(ANSIBLE) site.yml --tags banking-demo

deploy-app: cluster deploy

destroy:
	$(TERRAFORM) destroy -auto-approve

clean:
	rm -f ansible/inventory.ini
	find . -type d -name .terraform | xargs rm -rf
	find . -name *.retry -delete
