# Manual Bootstrapping — Kubernetes Core

Initialize the control plane, join workers, and install a CNI network plugin (Cilium by default).

> **Automation available:** This entire process is now automated via Ansible roles (`site.yml`). Run `make cluster` or `ansible-playbook -i inventory.ini ansible/site.yml --tags os,k8s,cni,verify` for a single-command setup. The steps below remain for learning/debugging.

> **Prerequisite:** Complete OS preparation first. Run `ansible-playbook -i inventory.ini ansible/site.yml --tags os`. All nodes must have `kubeadm`, `kubelet`, `kubectl`, and `containerd` installed.

## Overview

| Step | Node    | Action                              |
|------|---------|-------------------------------------|
| 1–5  | Master  | Init cluster, kubeconfig, CNI       |
| 6–7  | Workers | Join cluster                        |
| 8    | Master  | Verify all nodes Ready              |

## 1. SSH into Master Node

```bash
ssh -i ~/.ssh/YourKey.pem ubuntu@<MASTER_PUBLIC_IP>
```

## 2. Initialize the Cluster

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

This provisions the control plane and generates bootstrap tokens for worker nodes.

Wait for the output — it ends with a confirmation line and the join command.

## 3. Save the Join Command

At the end of `kubeadm init` output, you'll see:

```
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join <MASTER_PRIVATE_IP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

**Copy this entire line.** You'll paste it on each worker node.

> If you lose it, regenerate on the master:
> ```bash
> kubeadm token create --print-join-command
> ```

## 4. Configure kubeconfig on Master

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Verify access:

```bash
kubectl get nodes
```

Output should show the master node in `NotReady` state (network not yet configured).

## 5. Install a CNI

Pick one CNI plugin (default: Cilium).

### Default: Cilium

Install the Cilium CLI:

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

Install Cilium:

```bash
cilium install --version 1.19.6
```

Wait for Cilium pods to be ready:

```bash
cilium status --wait
```

All pods should reach `Running` before continuing. At this point, the master node transitions to `Ready`.

Verify Cilium is operational:

```bash
cilium connectivity test
```

### Alternative: Calico

Install the Tigera operator and custom resources:

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
```

Wait for Calico pods to be ready:

```bash
kubectl get pods -n calico-system -w
```

All pods should reach `Running` before continuing. At this point, the master node transitions to `Ready`.

## 6. SSH into Worker 1

Open a new terminal:

```bash
ssh -i ~/.ssh/YourKey.pem ubuntu@<WORKER1_PUBLIC_IP>
```

## 7. Join the Cluster

Paste the join command saved from step 3 and run with `sudo`:

```bash
sudo kubeadm join <MASTER_PRIVATE_IP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

Output:

```
This node has joined the cluster.
```

Repeat steps 6–7 for Worker 2.

## 8. Verify the Cluster

Back on the master node, watch nodes transition to `Ready`:

```bash
kubectl get nodes -w
```

Expected output:

```
NAME          STATUS   ROLES           AGE   VERSION
k8s-node-1    Ready    control-plane   5m    v1.36.x
k8s-node-2    Ready    <none>          2m    v1.36.x
k8s-node-3    Ready    <none>          1m    v1.36.x
```

Press `Ctrl+C` to exit the watch once all nodes are `Ready`.

```bash
kubectl get pods -A
```

All system pods should be `Running`.

## Token Expiry

Join tokens expire after 24 hours. To add new workers later:

```bash
# On master
kubeadm token create --print-join-command
```

## Troubleshooting

**Node stuck at `NotReady`**

Check Cilium status:

```bash
cilium status
kubectl get pods -n kube-system | grep cilium
kubectl describe pod -n kube-system -l k8s-app=cilium
```

If using Calico instead:

```bash
kubectl get pods -n calico-system
kubectl describe pod -n calico-system <pod-name>
```

**`kubeadm init` fails**

Common causes:
- Swap not disabled → `sudo swapoff -a` (Ansible should have handled this)
- Port 6443 already in use → `sudo lsof -i :6443`
- Reset and retry: `sudo kubeadm reset -f`

**Join fails with connection refused**

Ensure security group allows port 6443 on the master and worker-to-master connectivity:

```bash
# From worker, test connectivity
nc -zv <MASTER_PRIVATE_IP> 6443
```

**Join fails with token expired**

Generate a new token on master:

```bash
kubeadm token create --print-join-command
```
