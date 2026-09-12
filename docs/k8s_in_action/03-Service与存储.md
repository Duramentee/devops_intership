# 模块 03 · Service 与存储（第 5~6 章）

> 目标：给 Pod 一个稳定的访问入口，给数据一个安全的家。

## 一、核心概念（整体观）

### 1. Service：稳定的入口（p.207-225）

- Pod 会死亡、迁移、IP 会变 → **Service 提供单一不变的 IP+端口**，把连接路由到后端任一 Pod。
- Service 工作在 **TCP/UDP（第 4 层）**，不理解 HTTP，所以会话亲和只支持 `None` 和 `ClientIP`。
- 通过**标签选择器**（和副本控制器同一机制）决定哪些 Pod 属于该服务。
- Service 和 Pod 之间隔着 **Endpoint** 资源（IP:port 列表）；服务代理每次新连接从 Endpoint 里随机选一个后端。
- 服务发现两种方式：
  - **环境变量** `KUBIA_SERVICE_HOST/PORT`（服务名转大写、横杠转下划线）——**必须服务先于 Pod 创建**。
  - **DNS** `<服务名>.<命名空间>.svc.cluster.local`（推荐，无时序问题）。

### 2. 对外暴露（p.226-246）

| 方式 | 层 | 特点 |
|---|---|---|
| NodePort | L4 | 每个节点开同一端口，转发到随机 Pod |
| LoadBalancer | L4 | NodePort 的扩展，云 LB 提供公网 IP |
| Ingress | L7(HTTP) | 一个 IP 按主机名/路径路由到多个服务；TLS 终止 |

### 3. 卷：让数据有地方放（p.263-304）

| 卷类型 | 生命周期 | 用途 |
|---|---|---|
| emptyDir | 随 Pod | 同 Pod 多容器共享临时数据；`medium: Memory` 用 tmpfs |
| gitRepo | 随 Pod | 启动时克隆 Git 仓库（**之后不同步**）|
| hostPath | 随节点 | 读写节点文件系统，慎用 |
| gcePersistentDisk/awsElasticBlockStore/nfs | 独立 | 持久化存储 |
| PV/PVC | 集群级/命名空间级 | **把存储与 Pod 解耦** |

- **访问模式**（p.293）：RWO（单节点读写）、ROX（多节点只读）、RWX（多节点读写）——限制的是"同时使用的**节点数**"，不是 Pod 数。
- **PV 生命周期**：Available → Bound → Released；回收策略 `Retain`/`Recycle`/`Delete`。
- **StorageClass 动态供给**（p.300）：PVC 引用 StorageClass → provisioner 自动建 PV 和真实磁盘，免预置。

## 二、关键细节

- Service 的集群 IP 是**虚拟 IP**，`ping` 不通是正常的（p.220）。
- 就绪探针失败：Pod 从 Endpoint 移除、不接流量，但**不会被重启**（p.248）。没定义就绪探针 → Pod 几乎立刻成为端点，启动期收到"连接被拒绝"。
- Headless Service（`clusterIP: None`）：DNS 返回各 Pod 的 IP，客户端直连 Pod（p.254）。
- PVC 绑不上常见原因：PV 已 Released 未 Available、容量/访问模式不匹配、引用了不存在的 StorageClass。

## 三、命令速查

| 场景 | 命令 / 字段 | 说明 |
|---|---|---|
| 快速暴露 | `kubectl expose deployment <n> --port=80` | 用选择器建 Service |
| 看服务 | `kubectl get svc` | 集群 IP |
| Pod 内执行 | `kubectl exec <pod> -- curl ...` | `--` 后是 Pod 内命令 |
| 会话亲和 | `spec.sessionAffinity: ClientIP` | 同客户端 IP 到同 Pod |
| 多端口 | `spec.ports[].name`（多端口必填）| |
| 命名端口 | `targetPort: http` | 改端口号不用改 Service |
| DNS 发现 | `<svc>.<ns>.svc.cluster.local` | 同命名空间可省略 |
| 外部服务别名 | `type: ExternalName` | 只建 DNS CNAME |
| NodePort | `type: NodePort` + `nodePort` | 每节点同端口 |
| 本地流量 | `externalTrafficPolicy: Local` | 只转本地 Pod，少一跳 |
| Ingress | `rules[].host` + `paths[].path` | 按主机名/路径路由 |
| TLS | `tls[].secretName` | 证书存 Secret，控制器终止 TLS |
| Headless | `clusterIP: None` | DNS 返回 Pod IP |
| 看 PV/PVC/SC | `kubectl get pv / pvc / sc` | |
| 建 PV | `capacity.storage`、`accessModes`、`persistentVolumeReclaimPolicy` | 管理员 |
| 建 PVC | `resources.requests.storage`、`accessModes` | 用户 |
| 强制用预置 PV | `storageClassName: ""` | 阻止动态供给 |
| 建 StorageClass | `provisioner: ...`、`parameters: {type: pd-ssd}` | |

## 四、易错点

1. 环境变量发现有时序问题——服务要先于 Pod 创建，否则要删 Pod 重建（p.216）。
2. 浏览器 keep-alive 单连接下，即使 `sessionAffinity: None` 也总打同一个 Pod；curl 每次新连接才分散（p.233）。
3. hostPath 别用来持久化跨 Pod 数据——Pod 调度到别的节点就找不到数据（p.278）。
4. gitRepo 卷不会随仓库更新，要删 Pod 重建（p.272）。
5. 挂整个卷到非空目录会**隐藏**目录原有文件，用 `subPath` 只挂单文件（p.339，见模块04）。

## 五、动手实践

1. 建一个 `app=kubia` 的 Deployment（3 副本）+ Service（`kubectl expose`），curl 服务 IP 多次看负载均衡。
2. 在另一个 Pod 里 `curl kubia.default.svc.cluster.local`，验证 DNS 发现。
3. 建 NodePort Service，`minikube service` 从外部访问。
4. 加就绪探针，看 `kubectl get endpoints` 里未就绪 Pod 被移除。
5. 建 PV + PVC + 挂载到 Pod，写入一个文件，删 Pod 重建，看数据还在（PV 持久化）。

## 六、自测题

1. 为什么需要 Service？Pod 有 IP 不就行了吗？
2. 服务发现的两种方式各有什么坑？
3. NodePort / LoadBalancer / Ingress 三者的层级和区别？
4. emptyDir、hostPath、PV 三者的生命周期分别跟什么绑定？
5. PV 的三种回收策略（Retain/Recycle/Delete）各是什么意思？
6. 就绪探针和存活探针失败后的行为有何不同？

> 回查：p.207、p.216-218、p.226-237、p.263-298。
