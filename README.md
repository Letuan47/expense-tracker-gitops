# Expense Tracker Infrastructure & GitOps Repository (Ansible + K3s + ArgoCD + Kustomize + SOPS)

Repository quản lý toàn diện **Infrastructure as Code (Ansible Day-0/Day-1)** và **GitOps Continuous Delivery (ArgoCD + Kustomize Day-2)** cho hệ thống **Expense Tracker**.

---

## 1. Cấu Trúc Thư Mục Tổng Thể

```text
expense-tracker-gitops/
├── .sops.yaml                                 # Quy tắc mã hóa SOPS + age cho K8s Secrets
├── ansible/                                   # [Tầng 1: Day-0/Day-1] Ansible Host Hardening & K3s/ArgoCD Bootstrap
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventories/
│   │   └── staging/
│   │       ├── hosts.ini                      # Khai báo IP VPS Staging ([k3s_server])
│   │       └── group_vars/
│   │           ├── all.yml                    # Cấu hình SSH, UFW, Swap (2GB), Sysctl, K3s v1.31.4, ArgoCD v2.13.2
│   │           └── vault.example.yml          # Mẫu lưu khóa age private key bằng Ansible Vault
│   ├── playbooks/
│   │   ├── site.yml                           # Playbook tổng: OS Hardening -> Swap/Sysctl -> K3s -> ArgoCD Hand-off
│   │   ├── harden-os.yml                      # Playbook độc lập: Chỉ thực thi bảo mật OS, SSH, Fail2ban & UFW
│   │   └── fetch-kubeconfig.yml               # Playbook tiện ích: Tải kubeconfig về ~/.kube/k3s-staging.yaml (0600)
│   └── roles/
│       ├── os_hardening/                      # SSH Hardening, Fail2ban, UFW Firewall (Mở 22, 80, 443, CNI; Đóng 6443)
│       ├── k8s_node_prep/                     # Tạo 2GB Swap (swappiness=10), Kernel modules & SRE Sysctl tuning
│       ├── k3s_server/                        # Cài K3s ghim version, cấu hình Log Rotation (10Mi x 3) & Image GC
│       └── argocd_bootstrap/                  # Cài Cert-Manager, ArgoCD Lean, bơm sops-age-key, patch KSOPS & Hand-off
├── base/                                      # [Tầng 2: Day-2] Kustomize Base
│   ├── kustomization.yaml
│   ├── namespace.yaml                         # Namespace: expense-tracker-staging
│   ├── prisma-migrate-job.yaml                # ArgoCD PreSync Hook (-1) + Staging DB Guardrail
│   ├── backend-deployment.yaml                # NestJS 11 API (Non-Root UID 1001, /livez & /readyz)
│   ├── frontend-deployment.yaml               # Nginx 1.27 SPA (Non-Root UID 1001, port 8080, /health)
│   ├── ingress.yaml                           # Traefik HTTPS Ingress (staging.quanlichitieu.tuanstark.id.vn)
│   └── network-policy.yaml                    # Zero-Trust Ingress Isolation
├── overlays/
│   └── staging/                               # Môi trường Staging Overlay
│       ├── kustomization.yaml                 # Image tags bất biến (tự động cập nhật qua GitHub Actions PR)
│       ├── configmap.yaml                     # Biến môi trường không nhạy cảm
│       ├── secret-generator.yaml              # KSOPS generator cho ArgoCD
│       └── secrets/
│           └── expense-tracker-secrets.example.yaml # Mẫu cấu trúc Secret trước khi mã hóa SOPS
├── argocd/
│   ├── cluster-issuer.yaml                    # Let's Encrypt Staging & Production ClusterIssuers
│   ├── ksops-patch.yaml                       # Patch KSOPS + SOPS + age vào argocd-repo-server
│   ├── project-staging.yaml                   # ArgoCD AppProject (Least Privilege)
│   └── application-staging.yaml               # ArgoCD Application
└── scripts/
    └── bootstrap-k3s-staging.sh               # Script fallback khi chạy trực tiếp trên VPS không qua Ansible
```

---

## 2. Quy Trình Triển Khai Hạ Tầng Bằng Ansible (Day-0 / Day-1)

1. **Cài đặt Ansible Collections trên máy quản trị viên:**
   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ```
2. **Khai báo IP VPS Staging và Mã hóa khóa `age` bằng Ansible Vault:**
   * Điền địa chỉ IP VPS vào [`ansible/inventories/staging/hosts.ini`](file:///home/stark/Documents/Projects/Expense%20Tracker/expense-tracker-gitops/ansible/inventories/staging/hosts.ini).
   * Tạo file `vault.yml` chứa `age` private key và mã hóa bằng `ansible-vault`:
     ```bash
     cp inventories/staging/group_vars/vault.example.yml inventories/staging/group_vars/vault.yml
     # Dán age private key vào vault.yml rồi mã hóa:
     ansible-vault encrypt inventories/staging/group_vars/vault.yml
     ```
3. **Kiểm tra Dry-Run (`--check --diff`) và Thực thi Playbook Tổng (`site.yml`):**
   ```bash
   # Kiểm tra trước những thay đổi sẽ áp dụng lên VPS:
   ansible-playbook -i inventories/staging/hosts.ini playbooks/site.yml --ask-vault-pass --check --diff

   # Thực thi chính thức (OS Hardening -> Swap/Sysctl -> K3s -> Cert-Manager -> ArgoCD -> GitOps Hand-off):
   ansible-playbook -i inventories/staging/hosts.ini playbooks/site.yml --ask-vault-pass
   ```
4. **Truy cập Cụm K3s & ArgoCD UI An Toàn qua SSH Tunnel (Do Port 6443 & 8080 không mở ra Internet):**
   ```bash
   # Kéo kubeconfig về máy local (~/.kube/k3s-staging.yaml):
   ansible-playbook -i inventories/staging/hosts.ini playbooks/fetch-kubeconfig.yml

   # Mở SSH Tunnel tới K3s API (6443) trên VPS:
   ssh -fNL 6443:127.0.0.1:6443 ubuntu@<VPS_IP>
   export KUBECONFIG=~/.kube/k3s-staging.yaml
   kubectl get nodes,pods -A
   ```

---

## 3. Hướng Dẫn Mã Hóa App Secret Bằng SOPS + age (Day-2 GitOps)

1. **Tạo và mã hóa Secret của ứng dụng (`DATABASE_URL`, `JWT_SECRET`, `PAYOS_*`):**
   ```bash
   cp overlays/staging/secrets/expense-tracker-secrets.example.yaml \
      overlays/staging/secrets/expense-tracker-secrets.enc.yaml
   # Điền giá trị Staging vào file .enc.yaml rồi mã hóa tại chỗ bằng SOPS:
   sops --encrypt --in-place overlays/staging/secrets/expense-tracker-secrets.enc.yaml
   ```
2. **Bỏ comment phần `generators:` trong [`overlays/staging/kustomization.yaml`](file:///home/stark/Documents/Projects/Expense%20Tracker/expense-tracker-gitops/overlays/staging/kustomization.yaml) và commit/push lên Git.**

---

## 4. Runbook Vận Hành & Phục Hồi Sự Cố (SRE Runbook)

### 4.1. Khi Prisma Migration Job (`PreSync`) thất bại
* **Triệu chứng:** ArgoCD dừng ở bước `PreSync`, Pod Backend cũ vẫn đang chạy bình thường (`0%` downtime).
* **Chẩn đoán:**
  ```bash
  kubectl -n expense-tracker-staging logs job/prisma-migrate-deploy
  ```

### 4.2. Khi cần Rollback phiên bản ứng dụng
* Revert commit cập nhật image tag trên nhánh `main` của repo GitOps:
  ```bash
  git revert HEAD
  git push origin main
  ```

### 4.3. Khi VPS Staging gặp sự cố hỏng phần cứng (Disaster Recovery < 10 phút)
1. Khởi tạo VPS Ubuntu 22.04/24.04 mới, cập nhật IP mới vào [`ansible/inventories/staging/hosts.ini`](file:///home/stark/Documents/Projects/Expense%20Tracker/expense-tracker-gitops/ansible/inventories/staging/hosts.ini), DNS `A` record và IP Allowlist của Managed PostgreSQL.
2. Chạy `ansible-playbook -i inventories/staging/hosts.ini playbooks/site.yml --ask-vault-pass`. Toàn bộ hệ thống tự động khôi phục 100%.
