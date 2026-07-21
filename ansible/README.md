# ansible/ — Configure and Deploy

Ansible takes bare Ubuntu servers from Terraform and turns them into a production-shaped Kubernetes cluster with HTTPS ingress and a deployed banking application. It's agentless: connects via SSH to every machine in `inventory.ini` and runs tasks. It's idempotent: run it once or ten times — the result is the same.

The handoff from Terraform: `terraform apply` auto-generates `inventory.ini` with the real public IPs of every EC2 instance. Ansible reads that file to find its targets.

---

## Architecture: Roles-Based Pipeline

`site.yml` orchestrates five plays, each assigning a role to the target hosts. Roles are self-contained: tasks, handlers, templates, and defaults in one directory.

```
Play 1: hosts: all       → roles: os-hardening, containerd, kubernetes
Play 2: hosts: master    → roles: cni
Play 3: hosts: master    → verify all nodes Ready
Play 4: hosts: master    → roles: banking-demo (Helm + optional DuckDNS)
```

Tags let you run subsets:
```bash
ansible-playbook -i inventory.ini site.yml --tags os,k8s,cni,verify    # cluster only
ansible-playbook -i inventory.ini site.yml --tags banking-demo         # app only
```

---

## Role-by-Role Deep Dive

### `os-hardening`

Targets all nodes. Prepares the OS for Kubernetes.

**`tasks/main.yml`**

```yaml
- name: Disable swap
  ansible.builtin.command: swapoff -a
  changed_when: false

- name: Remove swap from /etc/fstab
  ansible.posix.mount:
    path: swap
    state: absent

- name: Load overlay kernel module
  community.general.modprobe:
    name: overlay
    state: present

- name: Load br_netfilter kernel module
  community.general.modprobe:
    name: br_netfilter
    state: present

- name: Create sysctl config for Kubernetes
  ansible.builtin.copy:
    dest: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
    mode: "0644"
  notify: reload sysctl
```

Each task explained:
- **swapoff -a** — the kubelet assumes all memory is real RAM. If swap is active, resource accounting breaks because the kernel can page memory to disk. The kubelet refuses to start if it detects swap. `changed_when: false` prevents false-positive change reports.
- **Remove swap from fstab** — without this, swap re-enables on reboot.
- **overlay** — the overlay filesystem enables container image layers. containerd requires this kernel module.
- **br_netfilter** — makes iptables see bridged traffic. Without it, kube-proxy's NAT rules for Services and NetworkPolicy don't apply to pod traffic.
- **sysctl config** — `bridge-nf-call-iptables=1` activates `br_netfilter` at runtime. `ip_forward=1` enables the node to route pod traffic between interfaces. The `notify: reload sysctl` handler only fires when the file is actually written.

---

### `containerd`

Targets all nodes. Installs and configures the container runtime.

**`tasks/main.yml`**

```yaml
- name: Install containerd
  ansible.builtin.apt:
    name: containerd
    state: present
    update_cache: true

- name: Create containerd config directory
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: "0755"

- name: Generate default containerd config
  ansible.builtin.command: containerd config default
  register: containerd_config
  changed_when: false

- name: Write containerd config with SystemdCgroup enabled
  ansible.builtin.copy:
    dest: /etc/containerd/config.toml
    content: |
      {{ containerd_config.stdout | replace('SystemdCgroup = false', 'SystemdCgroup = true') }}
    mode: "0644"
  notify: restart containerd
```

The two-step config strategy: `containerd config default` generates the full default TOML (hundreds of lines), then a Jinja2 `replace()` swaps the single line that matters: `SystemdCgroup = false` → `true`. This is better than maintaining a static config template that drifts from containerd's defaults.

Why `SystemdCgroup = true`? The kubelet uses systemd as its cgroup driver. If containerd uses cgroupfs, they manage cgroups independently — double accounting, resource enforcement breaks, and you get `cgroup driver mismatch` warnings. Aligning both under systemd fixes this.

**`handlers/main.yml`**

```yaml
- name: restart containerd
  ansible.builtin.systemd_service:
    name: containerd
    state: restarted
    enabled: true
```

Only fires when `config.toml` is actually written (idempotency). `enabled: true` ensures the service starts on boot even if restarted manually.

---

### `kubernetes`

Targets all nodes. Installs kubeadm/kubelet/kubectl on every node, then performs `kubeadm init` on the master or `kubeadm join` on workers. Uses `inventory_hostname in groups['master']` guards so the same role works for both master and workers.

**`tasks/main.yml`** — package installation:

```yaml
- name: Add Kubernetes APT key
  ansible.builtin.get_url:
    url: "https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/deb/Release.key"
    dest: /etc/apt/keyrings/kubernetes.asc
    mode: "0644"

- name: Add Kubernetes APT repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/kubernetes.asc] https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/deb/ /"
    state: present
    filename: kubernetes

- name: Install kubelet, kubeadm, kubectl
  ansible.builtin.apt:
    name: [kubelet, kubeadm, kubectl]
    state: present
    update_cache: true

- name: Hold kubelet, kubeadm, kubectl versions
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop: [kubelet, kubeadm, kubectl]
```

Three packages: `kubelet` (node agent daemon), `kubeadm` (bootstrap CLI), `kubectl` (client). The `dpkg_selections` hold prevents `apt upgrade` from silently bumping versions, which breaks Kubernetes' strict version skew policy (kubelet at most N-2 behind apiserver).

**Cluster initialization** (master only):

```yaml
- name: Check if cluster is already initialized
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: kubeconfig_check
  when: inventory_hostname in groups['master']

- name: Initialize Kubernetes control plane
  ansible.builtin.command:
    cmd: "kubeadm init --pod-network-cidr={{ pod_network_cidr }}"
  when:
    - inventory_hostname in groups['master']
    - not kubeconfig_check.stat.exists
```

The `admin.conf` file guard makes this idempotent — if the cluster is already initialized, `kubeadm init` is skipped.

**kubeconfig setup** (master):

```yaml
- name: Create .kube directory
  ansible.builtin.file:
    path: "/home/{{ ansible_user }}/.kube"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0755"
  when: inventory_hostname in groups['master']

- name: Copy admin.conf to user kubeconfig
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: "/home/{{ ansible_user }}/.kube/config"
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0600"
    remote_src: true
  when: inventory_hostname in groups['master']
```

Copies the root-owned cluster-admin certificate to the user's home directory so subsequent plays can run `kubectl` and `cilium` without sudo.

**Worker join** (workers only):

```yaml
- name: Get kubeadm join command
  ansible.builtin.command:
    cmd: kubeadm token create --print-join-command
  register: join_cmd
  when: inventory_hostname in groups['master']

- name: Save join command as fact
  ansible.builtin.set_fact:
    kubeadm_join: "{{ join_cmd.stdout }}"
  when: inventory_hostname in groups['master']

- name: Check if node is already joined
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf_check
  when: inventory_hostname in groups['workers']

- name: Join cluster
  ansible.builtin.command: "{{ hostvars[groups['master'][0]]['kubeadm_join'] }}"
  when:
    - inventory_hostname in groups['workers']
    - not kubelet_conf_check.stat.exists
```

The join command is generated on the master and accessed via `hostvars[groups['master'][0]]`. Workers check for `/etc/kubernetes/kubelet.conf` (created on successful join) for idempotency.

---

### `cni`

Targets the master only. Installs Cilium CLI and deploys the CNI plugin.

**`tasks/main.yml`**

```yaml
- name: Install Cilium CLI
  ansible.builtin.shell: |
    set -e
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/v{{ cilium_version }}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
  args:
    creates: /usr/local/bin/cilium

- name: Install Cilium CNI
  become_user: "{{ ansible_user }}"
  ansible.builtin.command:
    cmd: "cilium install --version {{ cilium_version }}"
  changed_when: false

- name: Wait for Cilium to be ready
  become_user: "{{ ansible_user }}"
  ansible.builtin.command:
    cmd: cilium status --wait
  changed_when: false
```

Cilium CLI downloaded with SHA256 verification. `creates: /usr/local/bin/cilium` provides idempotency. `become_user` runs as the `ubuntu` user for kubeconfig access. `cilium status --wait` blocks until all pods are running and connectivity is verified.

Why Cilium? Uses eBPF instead of iptables. No BGP (port 179) or VXLAN (port 4789) required — node-to-node communication rides on the self-referencing security group rule.

---

### `banking-demo`

Targets the master. Five steps: Helm install, clone repo, DuckDNS update + cron, render values override, Helm deploy.

The banking-demo Helm chart v1.0.0 is fully self-contained — Caddy Deployment (hostNetwork), Kong (ClusterIP), all services, datastores, shared-env ConfigMap, K8s Secrets, and NetworkPolicies. k8s-spinup only overrides `caddy.tls.*` when DuckDNS is enabled.

**`defaults/main.yml`**

```yaml
banking_demo:
  repo_url: "https://github.com/dungxnd/banking-demo-revamp.git"
  repo_version: "main"
  clone_dir: "/home/ubuntu/banking-demo"
  helm_release_name: "banking-demo"
  helm_namespace: "banking"
  helm_chart_path: "helm"
  helm_wait_timeout: "5m"

  duckdns:
    enabled: false
    domain: ""
```

All values are namespaced under `banking_demo` to avoid collisions with other variables. DuckDNS is disabled by default — pass `-e 'banking_demo.duckdns.enabled=true'` to enable.

**`tasks/main.yml`** — five sequential blocks:

**1. Helm installation:**

```yaml
- name: Check if helm is installed
  ansible.builtin.command: helm version --short
  register: helm_check
  ignore_errors: true
  changed_when: false

- name: Install Helm
  ansible.builtin.shell: |
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  when: helm_check.rc != 0
  args:
    creates: /usr/local/bin/helm
```

`creates` provides idempotency. The `helm version` pre-check avoids the curl if already installed.

**2. Clone repository:**

```yaml
- name: Clone banking-demo repository
  ansible.builtin.git:
    repo: "{{ banking_demo.repo_url }}"
    dest: "{{ banking_demo.clone_dir }}"
    version: "{{ banking_demo.repo_version }}"
    force: true
```

`force: true` performs a hard reset on reruns — ensures the latest committed chart.

**3. DuckDNS A-record + cron** (conditional):

```yaml
- name: Update DuckDNS A record immediately
  ansible.builtin.uri:
    url: "https://www.duckdns.org/update?domains=...&token={{ duckdns_token }}&ip={{ ansible_host }}"
    method: GET
  when: banking_demo.duckdns.enabled | bool

- name: Install DuckDNS cron job
  ansible.builtin.cron:
    name: "duckdns-update"
    minute: "*/5"
    job: 'curl -s "https://www.duckdns.org/update?...&token={{ duckdns_token }}&ip=" > /dev/null'
    user: root
  become: true
  when: banking_demo.duckdns.enabled | bool
```

Immediate update + `*/5 * * * *` cron job (with `&ip=` so DuckDNS auto-detects the source IP). When DuckDNS is disabled, the cron job is automatically removed.

**4. Render values override:**

```yaml
- name: Template values override
  ansible.builtin.template:
    src: values-override.yaml.j2
    dest: /tmp/.banking-values-override.yaml
```

**`templates/values-override.yaml.j2`** — the only override rendered:

```yaml
# Generated by Ansible — overrides values.yaml of banking-demo
{% if banking_demo.duckdns.enabled %}
caddy:
  tls:
    enabled: true
    domain: "{{ banking_demo.duckdns.domain }}"
{% endif %}
```

When DuckDNS is off, this file is empty — Helm uses chart defaults. When on, it sets `caddy.tls.enabled: true` with the domain. Caddy uses Let's Encrypt HTTP-01 challenge (no API token needed in the chart).

**5. Helm deploy:**

```yaml
- name: Deploy banking-demo via Helm
  ansible.builtin.command:
    cmd: >
      helm upgrade --install {{ banking_demo.helm_release_name }}
      {{ banking_demo.clone_dir }}/{{ banking_demo.helm_chart_path }}
      --namespace {{ banking_demo.helm_namespace }}
      --create-namespace
      --values /tmp/.banking-values-override.yaml
      --wait
      --timeout {{ banking_demo.helm_wait_timeout }}
  register: helm_result
```

`helm upgrade --install` is idempotent. `--wait --timeout 5m` blocks until all pods are ready including Caddy (if TLS is being provisioned). No NodePort, no `--set` hacks — the chart handles everything.

---

### `site.yml` — Master Playbook

```yaml
---
- name: Configure all nodes
  hosts: all
  become: true
  roles: [os-hardening, containerd]
  tags: [os, containerd]

- name: Initialize Kubernetes cluster
  hosts: master
  become: true
  roles: [kubernetes, cni]
  tags: [k8s, cni]

- name: Join workers
  hosts: workers
  become: true
  serial: 1
  roles: [kubernetes]
  tags: [k8s]

- name: Verify cluster nodes are Ready
  hosts: master
  become: false
  tasks:
    - name: Wait for all nodes to become Ready
      ansible.builtin.shell: |
        kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -cv Ready
      register: not_ready
      until: not_ready.stdout == "0"
      retries: 30
      delay: 10
      changed_when: false
  tags: [verify]

- name: Deploy banking-demo application
  hosts: master
  become: false
  roles: [banking-demo]
  tags: [banking-demo]
```

Four plays with tags. The verify play polls `kubectl get nodes` every 10 seconds for up to 5 minutes, counting nodes NOT in `Ready` state. When the count reaches `0`, the cluster is fully operational.

---

### `inventory.ini`

Auto-generated by Terraform. Gitignored. Format:

```ini
[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'

[master]
master-node ansible_host=54.12.34.56

[workers]
worker-1 ansible_host=54.78.90.12
worker-2 ansible_host=54.78.90.13

[k8s:children]
master
workers
```

### `inventory.ini.example`

Template showing the expected format for new users.
