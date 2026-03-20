# n8n 部署指南

在 K3s 叢集上使用 Terraform 部署 n8n（工作流程自動化工具），搭配 PostgreSQL 作為後端資料庫，並透過 Traefik Ingress 對外暴露服務。

---

## 環境資訊

| 項目 | 內容 |
|------|------|
| K3s 版本 | v1.34.5+k3s1 |
| n8n Helm Chart | 8gears library 0.25.2 |
| PostgreSQL Image | postgres:16-alpine |
| Master 節點 IP | 10.1.104.10 |
| 存取 Domain | n8n.martinlee.lab |
| Namespace | staging |
| Ingress Controller | Traefik（K3s 內建） |

---

## 架構說明

```
瀏覽器
  │
  │  http://n8n.martinlee.lab
  ▼
Traefik（Ingress Controller，K3s 內建）
  │
  │  依 Ingress 規則轉發（port 5678）
  ▼
n8n Pod（helm_release）
  │
  │  postgresql.staging.svc.cluster.local:5432
  ▼
PostgreSQL Pod（StatefulSet）
  │
  ▼
PersistentVolumeClaim（5Gi，local-path StorageClass）
```

---

## 檔案結構

```
terraform/k3s/services/n8n/
├── provider.tf              # Terraform provider 設定（kubernetes + helm）
├── main.tf                  # 主要資源定義
├── terraform.tfvars.example # 敏感變數範本
└── README.md                # 本文件
```

---

## 前置需求

- Terraform 已安裝（>= 1.5.0）
- `~/.kube/config` 已設定好 K3s 連線（context 名稱為 `default`）
- K3s 叢集正常運作，Traefik 已啟動
- `staging` namespace 已存在

確認 staging namespace：

```bash
kubectl --context default get namespace staging
```

若不存在，建立它：

```bash
kubectl --context default create namespace staging
```

---

## 部署步驟

### 1. 建立 terraform.tfvars

複製範本並填入實際值：

```bash
cd terraform/k3s/services/n8n
cp terraform.tfvars.example terraform.tfvars
```

編輯 `terraform.tfvars`：

```hcl
postgres_password  = "your-strong-password"
n8n_encryption_key = "your-random-32-char-encryption-key"
```

> **注意**：`terraform.tfvars` 已加入 `.gitignore`，不會被 commit 到 Git。

---

### 2. 初始化 Terraform

```bash
terraform init
```

---

### 3. 預覽變更

```bash
terraform plan \
  -var="postgres_password=your-password" \
  -var="n8n_encryption_key=your-key"
```

會建立以下資源：

| 資源 | 說明 |
|------|------|
| `kubernetes_secret.postgresql` | 儲存 PostgreSQL 密碼 |
| `kubernetes_persistent_volume_claim.postgresql` | 5Gi 持久化儲存 |
| `kubernetes_stateful_set.postgresql` | PostgreSQL Pod |
| `kubernetes_service.postgresql` | PostgreSQL ClusterIP Service |
| `helm_release.n8n` | n8n 應用程式 |
| `kubernetes_ingress_v1.n8n` | Traefik Ingress 規則 |

---

### 4. 套用

```bash
terraform apply -auto-approve \
  -var="postgres_password=your-password" \
  -var="n8n_encryption_key=your-key"
```

等待約 2-3 分鐘，所有 Pod 啟動完成。

---

### 5. 確認部署狀態

```bash
kubectl --context default get pods -n staging
```

預期輸出：

```
NAME                   READY   STATUS    RESTARTS   AGE
n8n-xxx                1/1     Running   0          2m
postgresql-0           1/1     Running   0          3m
```

確認 PVC 已 Bound：

```bash
kubectl --context default get pvc -n staging
```

確認 Ingress：

```bash
kubectl --context default get ingress -n staging
```

---

### 6. 設定本機 /etc/hosts

因為是本地測試環境，需要手動將 domain 指向 Master 節點 IP：

```bash
sudo sh -c 'echo "10.1.104.10  n8n.martinlee.lab" >> /etc/hosts'
```

---

### 7. 存取 n8n

開啟瀏覽器：

```
http://n8n.martinlee.lab
```

首次進入會引導建立管理員帳號。

---

## 遭遇的問題與解法

### 問題 1：Bitnami PostgreSQL Helm chart 找不到

```
Error: chart "postgresql" version "x.x.x" not found
```

嘗試 Bitnami OCI registry 及多個版本均失敗。

**解法**：改用官方 `postgres:16-alpine` Docker image，透過 `kubernetes_stateful_set` 直接部署，不依賴 Helm chart。

---

### 問題 2：PVC 卡在 WaitForFirstConsumer，Terraform 逾時

```
Error: client rate limiter Wait returned an error: context deadline exceeded
  with kubernetes_persistent_volume_claim.postgresql
```

K3s 預設的 `local-path` StorageClass 採用延遲綁定（`WaitForFirstConsumer`），PVC 要等到有 Pod 實際掛載後才會變成 `Bound` 狀態。Terraform 預設會等待 PVC 達到 `Bound` 才繼續，因此超時。

**解法**：在 PVC 資源加入 `wait_until_bound = false`：

```hcl
resource "kubernetes_persistent_volume_claim" "postgresql" {
  ...
  wait_until_bound = false  # local-path StorageClass 採 WaitForFirstConsumer
}
```

---

### 問題 3：殘留資源衝突

```
Error: services "postgresql" already exists
```

前次失敗的部署留下殘留 Service。

**解法**：手動清理後重新 apply：

```bash
kubectl --context default delete svc postgresql -n staging
kubectl --context default delete pvc postgresql-pvc -n staging
terraform apply -auto-approve ...
```

---

## 清除資源

```bash
terraform destroy -auto-approve \
  -var="postgres_password=your-password" \
  -var="n8n_encryption_key=your-key"
```

---

## 確認 Traefik 對應狀況

查看 Ingress 規則：

```bash
kubectl --context default get ingress -A
```

查看 Traefik Service：

```bash
kubectl --context default get svc -n kube-system | grep traefik
```

透過 port-forward 開啟 Traefik Dashboard：

```bash
kubectl --context default port-forward svc/traefik -n kube-system 9000:9000
```

開啟瀏覽器：`http://localhost:9000/dashboard/`
