# terraform/ — Provision Infrastructure

Terraform creates the AWS resources. It's declarative: you describe what should exist, and Terraform figures out the API calls to make it happen. Every resource is tracked in `terraform.tfstate`.

The key output of this folder is `../ansible/inventory.ini` — the handoff to Ansible.

---

## File-by-file deep dive

### `main.tf`

This is the entire infrastructure definition in one file. Let's go through every block.

**Terraform block** — configures Terraform itself, not your infrastructure:

```hcl
terraform {
  required_providers {
    aws   = { source = "hashicorp/aws",   version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.9" }
  }
  required_version = ">= 1.5"
}
```

- `required_providers` tells `terraform init` which plugins to download from the Terraform Registry.
- `~> 6.0` means "any 6.x version" — accepts 6.1, 6.99, but rejects 7.0 (which could break the config). This is the pessimistic constraint operator.
- The `local` provider manages files on your local filesystem. We need it because the `local_file` resource writes `inventory.ini` to disk. Without this block, you'd get a "provider not found" error.
- `required_version = ">= 1.5"` sets the minimum Terraform binary version.

**Provider block** — configures a specific provider instance:

```hcl
provider "aws" {
  region = var.region
}
```

Every `resource` and `data` block that starts with `aws_` implicitly uses this provider. Setting `region` here means all resources are created in the configured region without having to specify it on each resource.

**Data sources** — fetch information that already exists in AWS. They don't create anything:

```hcl
data "aws_vpc" "default" {
  default = true
}
```

`default = true` queries AWS for "the default VPC of this region." Every AWS region comes with one pre-created default VPC. Using a data source instead of hardcoding `vpc-abc123` makes this work across accounts and regions.

```hcl
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
```

Finds all subnets in that VPC. Returns a list — we only use `ids[0]` (the first one) when creating instances. All instances land in the same subnet/AZ, which is fine for learning but not production.

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID
```

Finds the latest Ubuntu AMI from Canonical. `099720109477` is Canonical's verified AWS account — this is a public constant documented by Canonical. `most_recent = true` picks the newest build so you always launch a patched image.

```hcl
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-*-26.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
```

Three filters narrowing down to the exact AMI type:
- AMI name pattern: HVM virtualization + gp3-backed + Ubuntu 26.04 + x86_64
- HVM (hardware virtual machine) — paravirtual is obsolete
- x86_64 architecture — excludes ARM/Graviton images

**Security group** — the firewall around your instances:

```hcl
resource "aws_security_group" "k8s" {
  name        = "${var.cluster_name}-sg"
  description = "Security group for Kubernetes cluster"
  vpc_id      = data.aws_vpc.default.id
```

A `resource` block creates and manages infrastructure — unlike data sources, which only read. `${var.cluster_name}-sg` becomes `k8s-sg`. `vpc_id` binds it to the default VPC.

Each `ingress` block is an inbound firewall rule. `0.0.0.0/0` means any IP — wide open, fine for learning, lock down in production.

| Rule | Port(s) | Why Kubernetes needs it |
|---|---|---|
| SSH | 22 TCP | Ansible connects here to configure the OS. Without it, no remote access. |
| kube-apiserver | 6443 TCP | The `kubectl` CLI, `kubeadm join`, and internal control plane components talk to this. |
| Kubelet API | 10250 TCP | The apiserver uses this to do `kubectl exec`, `kubectl logs`, `kubectl port-forward`. |
| NodePort | 30000–32767 TCP | When you create a `type: NodePort` Service, Kubernetes opens one port in this range on every node. External traffic hits any node IP on this port. |
| Calico BGP | 179 TCP | Calico uses BGP to exchange pod routes between nodes. Every node peers with every other node. Only needed if using Calico instead of the default Cilium CNI. |
| Calico VXLAN | 4789 UDP | Alternative to BGP — encapsulates pod traffic in VXLAN tunnels. Standard VXLAN port. Only needed if using Calico instead of the default Cilium CNI. |

The egress rule uses `protocol = "-1"` and `from_port = 0, to_port = 0` — the Terraform idiom for "all protocols, all ports." Nodes need outbound internet to pull container images and APT packages.

**EC2 instances** — the actual virtual machines:

```hcl
resource "aws_instance" "k8s" {
  count         = var.node_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = data.aws_subnets.default.ids[0]
```

`count = var.node_count` creates N copies of this resource. With `node_count = 3`, you get `aws_instance.k8s[0]`, `k8s[1]`, `k8s[2]` — each with its own IP, EBS volume, and lifecycle.

`data.aws_subnets.default.ids[0]` takes only the first subnet. This is the simplest approach — production would use different subnets/AZs for each instance.

```hcl
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  associate_public_ip_address = true
```

All instances share the same security group. `associate_public_ip_address = true` assigns a public IP to each instance — required for Ansible to SSH in.

**Spot market** — the cost-saving mechanism:

```hcl
  instance_market_options {
    market_type = "spot"
    spot_options {
      instance_interruption_behavior = "stop"
      spot_instance_type             = "persistent"
    }
  }
```

- `market_type = "spot"` uses spare EC2 capacity at ~60-70% discount instead of on-demand pricing.
- `instance_interruption_behavior = "stop"` — when AWS needs capacity back (with a 2-minute warning), the instance **stops** (not terminates). Your EBS root volume survives. When capacity returns, you restart it and everything is still there.
- `spot_instance_type = "persistent"` — after interruption, AWS automatically relaunches the instance when the spot price drops below your max again. Combined with `stop` behavior, the same EBS volume reattaches.

If interruption behavior were "terminate", the EBS volume would be destroyed and all your containerd/kubelet config lost.

```hcl
  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }
```

`gp3` is simpler and cheaper than gp2 — baseline 3000 IOPS regardless of volume size. 20 GB is the Ubuntu AMI minimum.

```hcl
  tags = {
    Name = "${var.cluster_name}-node-${count.index + 1}"
    Role = count.index == 0 ? "master" : "worker"
  }
```

`count.index` runs 0, 1, 2 for three instances. The `Role` tag uses a ternary: index 0 gets `"master"`, the rest get `"worker"`. This is how the entire cluster knows which node is the control plane — purely positional.

**Inventory file** — the bridge to Ansible:

```hcl
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = templatefile("${path.module}/inventory.tftpl", {
    master_public_ip  = coalesce(aws_instance.k8s[0].public_ip, "")
    worker_public_ips = slice(aws_instance.k8s, 1, var.node_count)
    ssh_key_path      = var.ssh_private_key_path
    ansible_user      = "ubuntu"
  })
  depends_on = [aws_instance.k8s]
}
```

`templatefile(path, vars)` reads a template, substitutes variables, and returns a rendered string. Then `local_file` writes that string to disk.

- `coalesce(a, "")` returns the first non-null/non-empty value. During `terraform plan`, `public_ip` might not be known yet (AWS assigns IPs after launch). `coalesce` prevents an error by falling back to empty string.
- `slice(list, 1, var.node_count)` extracts elements `[1]` through `[node_count-1]` — all instances except index 0 (the master). With `node_count = 3`, this gives `[k8s[1], k8s[2]]`.

`depends_on` creates an explicit ordering dependency. Terraform normally infers dependencies from references (`aws_instance.k8s[0].public_ip`), but `slice()` references the collection indirectly. Without `depends_on`, Terraform might write the inventory before instances are fully created.

### `variables.tf`

Declares every configurable input with a type and optional default:

| Variable | Type | Default | Notes |
|---|---|---|---|
| `region` | `string` | `ap-southeast-1` | AWS region |
| `cluster_name` | `string` | `k8s` | Used in security group name and instance tags |
| `instance_type` | `string` | `t3a.medium` | 2 vCPU, 4 GB RAM — AMD EPYC, cheapest t3 variant |
| `node_count` | `number` | `3` | Index 0 = master, rest = workers |
| `key_name` | `string` | **none** | Required — Terraform will prompt if not set. This is your EC2 key pair name from the AWS console. |
| `ssh_private_key_path` | `string` | `~/.ssh/id_ed25519` | Path to the private key matching `key_name`. Fed into the Ansible inventory. |
| `root_volume_size` | `number` | `20` | GB, gp3 |

`key_name` has no default — Terraform forces you to either set it in `terraform.tfvars` or answer a prompt. This prevents accidentally creating instances you can't SSH into.

### `outputs.tf`

Outputs are values printed after `terraform apply` and stored in state. They can be queried with `terraform output <name>`.

```hcl
output "instance_ids"       { value = aws_instance.k8s[*].id }
output "instance_public_ips" { value = aws_instance.k8s[*].public_ip }
output "instance_private_ips" { value = aws_instance.k8s[*].private_ip }
output "security_group_id"  { value = aws_security_group.k8s.id }
output "master_ip"          { value = aws_instance.k8s[0].public_ip }
```

`[*]` is the splat expression — collects a single attribute from every instance in the list. So `aws_instance.k8s[*].id` returns `["i-abc", "i-def", "i-ghi"]`.

`master_ip` gives just the first instance's IP — useful for SSH or `kubeadm init`.

### `inventory.tftpl`

An HCL template that Terraform renders into an Ansible INI inventory file. Let's go section by section:

```ini
[all:vars]
ansible_user=${ansible_user}
ansible_ssh_private_key_file=${ssh_key_path}
ansible_python_interpreter=/usr/bin/python3
```

`[all:vars]` is Ansible INI syntax for "variables that apply to every host." `${ansible_user}` gets replaced with `"ubuntu"` during rendering. `ansible_python_interpreter=/usr/bin/python3` is explicit because Ubuntu no longer ships Python 2 and some SSH connections might not auto-detect Python 3.

```ini
[master]
master ansible_host=${master_public_ip}
```

`[master]` defines an Ansible group with one host named `master`. `${master_public_ip}` gets replaced with the real public IP of instance `k8s[0]`. `ansible_host` is the IP Ansible SSH's to.

```hcl
[workers]
%{ for i, ip in worker_public_ips ~}
worker-${i + 1} ansible_host=${ip.public_ip}
%{ endfor ~}
```

This is a template loop. `worker_public_ips` is the list of instance objects from `slice(aws_instance.k8s, 1, var.node_count)`. `i` is the loop index (0, 1), `ip` is the instance object. `ip.public_ip` accesses that instance's attribute. The `~` strips trailing whitespace after the directive.

Renders to:
```ini
worker-1 ansible_host=54.12.34.56
worker-2 ansible_host=54.78.90.12
```

```ini
[k8s:children]
master
workers
```

`[group:children]` is Ansible's group-of-groups syntax. Targeting `k8s` includes all hosts from both `master` and `workers`. This lets you run a play on every node without repeating host definitions.

### `terraform.tfvars` / `terraform.tfvars.example`

`.tfvars` files contain variable values. Terraform auto-loads `terraform.tfvars` — no need to pass `-var-file`. The `.example` version is safe to commit; the real `terraform.tfvars` is gitignored because it contains your actual key name.
