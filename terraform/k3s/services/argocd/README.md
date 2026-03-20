# ArgoCD 部署指南

在 K3s 叢集上使用 Terraform + Helm 部署 ArgoCD，並透過 Traefik Ingress 對外暴露服務。

---

## 環境資訊

| 項目 | 內容 |
|------|------|
| K3s 版本 | v1.34.5+k3s1 |
| ArgoCD Helm Chart | 7.7.0 |
| Master 節點 IP | 10.1.104.10 |
| 存取 Domain | argocd.martinlee.lab |
| Ingress Controller | Traefik（K3s 內建） |

---

## 前置需求

- Terraform 已安裝（>= 1.5.0）
- `~/.kube/config` 已設定好 K3s 連線（context 名稱為 `default`）
- K3s 叢集正常運作，Traefik 已啟動

確認 Traefik 狀態：

```bash
kubectl --context default get pods -n kube-system | grep traefik
```

---

## 部署步驟

### 1. 初始化 Terraform

```bash
cd terraform/k3s/services/argocd
terraform init
```

### 2. 預覽變更

```bash
terraform plan
```

會建立以下資源：
- `kubernetes_namespace.argocd` — 建立 `argocd` namespace
- `helm_release.argocd` — 透過 Helm 安裝 ArgoCD
- `kubernetes_ingress_v1.argocd` — 建立 Traefik Ingress 規則

### 3. 套用

```bash
terraform apply -auto-approve
```

等待約 2 分鐘，所有 Pod 啟動完成。

確認 Pod 狀態：

```bash
kubectl --context default get pods -n argocd
```

預期輸出：

```
argocd-application-controller-0          1/1  Running
argocd-applicationset-controller-xxx     1/1  Running
argocd-dex-server-xxx                    1/1  Running
argocd-notifications-controller-xxx      1/1  Running
argocd-redis-xxx                         1/1  Running
argocd-repo-server-xxx                   1/1  Running
argocd-server-xxx                        1/1  Running
```

---

### 4. 設定本機 /etc/hosts

因為是本地測試環境，需要手動將 domain 指向 Master 節點 IP：

```bash
sudo sh -c 'echo "10.1.104.10  argocd.martinlee.lab" >> /etc/hosts'
```

---

### 5. 取得初始密碼

```bash
kubectl --context default get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

### 6. 登入 ArgoCD UI

開啟瀏覽器：

```
http://argocd.martinlee.lab
帳號：admin
密碼：（上一步取得的密碼）
```

> **建議**：登入後立即至 User Info → Update Password 修改密碼。

---

## 架構說明

```
瀏覽器
  │
  │  http://argocd.martinlee.lab
  ▼
Traefik（Ingress Controller，K3s 內建）
  │
  │  依 Ingress 規則轉發
  ▼
argocd-server Service（port 80）
  │
  ▼
ArgoCD Pod
```

---

## 檔案結構

```
terraform/k3s/services/argocd/
├── provider.tf   # Terraform provider 設定（kubernetes + helm）
├── main.tf       # 主要資源定義（namespace、helm release、ingress）
└── README.md     # 本文件
```

---

## 確認 Traefik 對應狀況

### 查看 Ingress 規則

```bash
kubectl --context default get ingress -A
```

預期輸出：
```
NAMESPACE   NAME             CLASS    HOSTS                  ADDRESS                               PORTS   AGE
argocd      argocd-ingress   <none>   argocd.martinlee.lab   10.1.104.10,10.1.104.11,10.1.104.12   80      7m
```

- **HOSTS**：對應的 domain
- **ADDRESS**：三台 VM 都在接收流量
- **PORTS**：對外暴露的 port

---

### 查看 Traefik Service

```bash
kubectl --context default get svc -n kube-system | grep traefik
```

預期輸出：
```
traefik   LoadBalancer   10.43.82.86   10.1.104.10,10.1.104.11,10.1.104.12   80:32020/TCP,443:30159/TCP
```

- `80` → HTTP（node port 32020）
- `443` → HTTPS（node port 30159）

---

### Traefik Dashboard（詳細流量對應）

透過 port-forward 在本機開啟 Traefik Dashboard：

```bash
kubectl --context default port-forward svc/traefik -n kube-system 9000:9000
```

開啟瀏覽器：

```
http://localhost:9000/dashboard/
```

Dashboard 可以看到：
- 所有 Router（domain 對應規則）
- 所有 Service（後端服務）
- 流量狀態

---

## 清除資源

```bash
terraform destroy -auto-approve
```
