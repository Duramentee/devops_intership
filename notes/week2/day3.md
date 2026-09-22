# Day 3 学习笔记 · ConfigMap 与 Secret（把配置从镜像中分离）

> 日期：2026-09-21 · 代码：`code/week2/day3/`（`cm.yaml`、`secret.yaml`、`deploy.env.yaml`、`deploy.volume.yaml`、`go-webapp/`、`outputs/`）
> 配套资料：`plan/week2/任务明细.md` 中的 Day 3 节、`docs/k8s_in_action/04-配置与API.md`、教材第 7 章 7.4 至 7.5 节（p.323-357）
> 起点资产：Day 1 创建的 Deployment `webapp`（副本数量为 3）、Day 2 创建的 Service `webapp`（ClusterIP 为 `10.96.135.12`）、镜像 `webapp:v4`
> 今日的模型变化：Pod 模板中除「镜像与端口」之外新增两类引用，也就是对 ConfigMap 的引用与对 Secret 的引用。配置文件不再位于镜像内部，而是在容器创建之前由节点上的 kubelet 依据这些引用写入容器
> 今日新增的资产：镜像 `webapp:v5`、ConfigMap `webapp-config` 与 `webapp-file-config`、Secret `webapp-secret`、Deployment `webapp-vol`（标签 `app=webapp-vol`，与 Service 的选择器隔离）

---

## 一、今日速览（结论）

| 编号 | 结论 | 原始输出依据 |
|---|---|---|
| 1 | 镜像内部没有配置目录，基线命令的输出直接是「配置目录不存在」，因此配置只可能来自部署时注入 | `outputs/00-baseline-appdir.txt` |
| 2 | ConfigMap `webapp-config` 的 `data` 段落中取值是明文，例如 `GREETING: Hello from ConfigMap`、`APP_ENV: dev`、`FOO-BAR: this-key-is-ignored` | `outputs/02-cm-yaml.txt`（该文件是修正键名之前的快照，只含 `GREERTING`） |
| 3 | Secret `webapp-secret` 的 `data` 段落中取值是 base64 编码。`kubectl get secret webapp-secret -o jsonpath='{.data.DB_PASSWORD}'` 得到 `ZGV2LW9ubHktcGFzc3dvcmQ=`，用 `base64 -d` 解码得到 `dev-only-password`，因此 base64 是编码而不是加密 | `outputs/02-secret-yaml.txt`、`outputs/08-secret-volume.txt` |
| 4 | `kubectl describe secret webapp-secret` 只输出键名与字节数（`DB_PASSWORD:  17 bytes`），不输出取值；`kubectl describe configmap` 会输出取值。这是两个对象在输出层面的可见差异 | `outputs/02-describe-secret.txt`、`outputs/02-describe-cm.txt` |
| 5 | 以环境变量方式注入之后，容器内出现 `GREETING`、`APP_ENV`、`DB_PASSWORD` 三个键，同时出现 `FOO-BAR`（键名含短横线，仍然被注入），并且残留了修正键名之前的 `GREERTING` | `outputs/03-env-injected.txt` |
| 6 | 教材 7.4.4 节（p.332）说键名包含破折号时该条目会被静默忽略，本次实测**没有复现**，`FOO-BAR` 被成功注入 | `outputs/03-env-injected.txt` |
| 7 | 没有挂载卷的 Deployment 中，应用报告里 `file GREETING` 一行显示「读取失败」，`/config` 端点返回 500 | `outputs/03-app-report-env.txt` |
| 8 | 卷挂载之后，ConfigMap 中的一个键对应容器内的一个文件，键名就是文件名；目录内同时存在 `..data` 符号链接与 `..2026_...` 时间戳目录 | `outputs/04-volume-files.txt` |
| 9 | 修改 ConfigMap 之后，同一个 Pod 内出现分化：环境变量保持旧取值（`Hello from ConfigMap`），文件变成新取值（`Hello from ConfigMap changed`） | `outputs/05-config-drift.txt` |
| 10 | 环境变量方式要读到新取值必须重建容器：执行 `kubectl rollout restart deploy/webapp` 之后 `env GREETING` 才变成新取值 | `outputs/06-rollout-restart.txt` |
| 11 | 整目录挂载得到的条目是符号链接（`lrwxrwxrwx config.conf -> ..data/config.conf`），`subPath` 挂载得到的是普通文件（`-rw-r--r-- config.conf`）。修改 ConfigMap 之后，前者变成 `log_level=info`，后者仍然是 `log_level=debug` | `outputs/07-subpath-before.txt`、`outputs/07-subpath-after.txt`、`outputs/07-subpath.txt` |
| 12 | 原子切换只替换 `..data` 一个符号链接：更新后 `..data` 指向 `..2026_09_21_02_13_20.198768711`，旧时间戳目录被清理，而 `config.conf` 这个键名符号链接的时间戳仍然是挂载时刻 | `outputs/07-subpath-after.txt` |
| 13 | Secret 以卷方式挂载之后，容器内 `cat /etc/webapp-secret/DB_PASSWORD` 得到明文 `dev-only-password`（17 个字符），说明 kubelet 在写入卷之前已经完成解码，应用不需要自己处理编码 | `outputs/08-secret-volume.txt` |
| 14 | ConfigMap 卷的目录权限是 `drwxrwxrwx`，Secret 卷的目录权限是 `drwxrwxrwt`（带 sticky 位）。这个差异的原因尚未确认，列为待查项 | `outputs/07-subpath-after.txt`、`outputs/08-secret-volume.txt` |
| 15 | 配置文件的取值里含有行尾空格：`config.conf` 的可见内容是 46 字节，而文件大小是 64 字节，差额 15 字节来自两个行尾空格。YAML 块标量会原样保留行尾空格 | `outputs/07-cm-after-edit.yaml`、`outputs/08-secret-volume.txt` |

---

## 二、任务清单

| 编号 | 任务 | 完成 | 原始输出留在哪 |
|---|---|---|---|
| 1 | 记录七项基线（集群、Pod、ConfigMap、Secret、工作负载、镜像内配置目录、宿主机镜像标签） | ✅ | `outputs/00-*.txt` |
| 2 | 生成 ConfigMap 与 Secret 的客户端模板并逐字段阅读 | ✅ | `outputs/01-dry-run-cm.yaml`、`outputs/01-dry-run-secret.yaml` |
| 3 | 编写并创建 `cm.yaml` 与 `secret.yaml` | ✅ | `code/week2/day3/cm.yaml`、`code/week2/day3/secret.yaml` |
| 4 | 观察两个对象的存储形式并验证 base64 可解码 | ✅ | `outputs/02-*.txt`、`outputs/02-*.yaml` |
| 5 | 编写并创建以环境变量方式注入的 Deployment | ✅ | `outputs/03-env-injected.txt` |
| 6 | 确认环境变量注入结果并与预判 3 对照 | ✅ | `outputs/03-env-injected.txt` |
| 7 | 编写并创建以文件方式挂载的 Deployment `webapp-vol` | ✅ | `outputs/04-volume-files.txt` |
| 8 | 确认卷内出现与键名同名的文件 | ✅ | `outputs/04-volume-files.txt` |
| 9 | 修改 ConfigMap 并观察两种方式的差异 | ✅ | `outputs/05-config-drift.txt` |
| 10 | 观察环境变量方式需要重建容器才生效 | ✅ | `outputs/06-rollout-restart.txt` |
| 11 | 第 17 步：`subPath` 挂载不随配置更新 | ✅ 第一次尝试失败（自变量未真正改变，Pod 报 `RunContainerError`），第二次成功 | `outputs/07-subpath.txt`、`outputs/07-subpath-before.txt`、`outputs/07-subpath-after.txt` |
| 12 | 第 18 步：以文件方式挂载 Secret | ✅ | `outputs/08-secret-volume.txt` |
| 13 | 完成 Linux 每日一题 Day 10（目录权限） | ✅ 讲解式完成，见第七节 | `notes/week2/day3.md` 第七节 |
| 14 | 回答当天的面试问答卡（四道题） | ✅ 批改完成，见第八节 | `notes/week2/day3.md` 第八节 |

---

## 三、概念（机制）

> 阅读顺序建议：先读 3.1 与 3.2，弄清 ConfigMap 与 Secret 这两个对象各自是什么、差别在哪里；再读 3.3 与 3.4，弄清 Deployment 里新增了哪些字段、两种注入方式各自的行为；然后读 3.5 的完整工作链路，把两个对象放进一次部署的全过程中；最后读 3.6 至 3.9 的实现细节与实测差异。

### 3.1 ConfigMap 对象本身是什么

| 问题 | 答案 |
|---|---|
| 它是什么类型的 API 资源 | 内置对象（`apiVersion: v1`、`kind: ConfigMap`），内容是若干条「键 → 字符串取值」的记录。它没有进程，也不监听端口 |
| 它属于哪个层级 | 命名空间级对象，因此 Pod 只能引用**同一个命名空间**中的 ConfigMap，跨命名空间引用是不允许的 |
| 谁创建它 | 由人创建（`kubectl create` 或 `kubectl apply`）。本次实验中由你编写 `cm.yaml` 创建，也可以用 `kubectl create configmap --from-literal` 直接创建 |
| 它的生命周期与谁绑定 | 与 Pod 无关。删除 ConfigMap 不会删除 Pod，也不会影响已经运行的容器；但会让**新建**的 Pod 因为找不到对象而停在 `CreateContainerConfigError` |
| 它不是什么 | 它不是卷、不是环境变量、也不是加密容器。它只是一份键值数据，「怎么进入容器」完全由 Pod 模板决定；同一个 ConfigMap 可以被多个 Pod 以不同方式引用 |

#### 3.1.1 ConfigMap 对象的字段清单

| 字段 | 是否必须 | 含义 |
|---|---|---|
| `apiVersion: v1` 与 `kind: ConfigMap` | 必须 | 声明这是一个 ConfigMap 对象 |
| `metadata.name` | 必须 | 对象的名称，Pod 模板通过这个名称引用它 |
| `metadata.namespace` | 可选 | 省略时使用当前上下文的命名空间；引用它的 Pod 必须位于同一个命名空间 |
| `metadata.labels` 与 `metadata.annotations` | 可选 | 用于标记这个对象自身。它与 Deployment 的选择器没有关系，不要混淆 |
| `data` | 与 `binaryData` 二者取其一 | 字符串键值对。取值必须是字符串，因此 `listen_port: 8080` 会被拒绝，必须写成带引号的 `"8080"` 或者用块标量 |
| `binaryData` | 与 `data` 二者取其一 | 二进制内容，取值必须是 base64 编码的字符串。本次实验不使用 |
| `immutable` | 可选，默认 `false` | 取值为 `true` 时对象的内容不可再修改。本次实验不使用 |
| `status` | 服务端字段 | ConfigMap 没有 `status` 段落，这一点与 Deployment 不同 |

### 3.2 Secret 对象本身是什么

| 问题 | 答案 |
|---|---|
| 它是什么类型的 API 资源 | 内置对象（`apiVersion: v1`、`kind: Secret`），结构上与 ConfigMap 相同，也是键值记录 |
| 它属于哪个层级 | 命名空间级对象，必须与引用它的 Pod 位于同一个命名空间 |
| 它与 ConfigMap 的差别是什么 | 三个差别：① 条目内容以 base64 编码存放在 `data` 段落中；② 分发范围受控，只有真正使用它的节点才会拿到内容，内容保存在内存文件系统（tmpfs）中而不写入节点磁盘，单个体积上限 1 MB（p.346）；③ 可以被单独授权，RBAC 可以只授予读取 Secret 的权限，而不授予读取其他对象的权限 |
| 它是不是加密存储的 | **不是**。base64 只是编码，`kubectl get secret -o jsonpath` 取出 `data` 的取值之后用 `base64 -d` 就能还原出明文。真正的保护手段是访问控制与传输加密 |
| 它不是什么 | 它不是密钥管理系统，不提供凭证轮换、审计与自动过期。生产环境的凭证通常来自外部密钥管理系统，Secret 只承担传输介质 |
| 谁把它送进容器 | 与 ConfigMap 相同，由 Pod 所在节点上的 kubelet 在创建容器之前读取并写入 |

#### 3.2.1 Secret 对象的字段清单

| 字段 | 是否必须 | 含义 |
|---|---|---|
| `apiVersion: v1` 与 `kind: Secret` | 必须 | 声明这是一个 Secret 对象 |
| `metadata.name` | 必须 | 对象的名称，Pod 模板通过这个名称引用它 |
| `metadata.namespace` | 可选 | 省略时使用当前上下文的命名空间 |
| `type` | 可选，默认 `Opaque` | 其他常见取值是 `kubernetes.io/tls`（存放证书与私钥）、`kubernetes.io/dockerconfigjson`（拉取私有镜像时使用）、`kubernetes.io/service-account-token`（服务账户令牌） |
| `data` | 与 `stringData` 二者取其一 | 取值必须是已经 base64 编码的字符串。`kubectl create secret generic` 生成的模板就是这个段落 |
| `stringData` | 与 `stringData` 的对应段落二者取其一 | **只写字段**：写入时给出明文，API Server 在保存之前把它编码进 `data`；读回时这个段落已经消失，只剩下 `data`。本次实验使用它，目的是亲眼看一次「写进去是明文、读出来是编码」 |
| `immutable` | 可选，默认 `false` | 取值为 `true` 时内容不可再修改 |
| `status` | 服务端字段 | Secret 没有 `status` 段落 |

#### 3.2.2 ConfigMap 与 Secret 对照表

| 维度 | ConfigMap | Secret |
|---|---|---|
| 条目的存放形式 | 明文 | base64 编码 |
| 注入方式 | 环境变量、`envFrom`、卷挂载 | 完全相同 |
| 分发范围 | 使用它的节点 | 使用它的节点（补充说明：Secret 的这一条有明确文档依据，p.346） |
| 落盘位置 | 卷内容由 kubelet 写入节点上的卷目录 | 使用 tmpfs 保存在内存中，不写入节点磁盘（p.346） |
| 访问控制 | 与其他对象相同 | 可以单独授权 |
| 体积上限 | 受 etcd 单对象上限约束 | 1 MB（p.346） |
| 内置类型 | 无类型概念 | 有 `type` 字段与若干内置类型 |
| 推荐的注入方式 | 视场景而定 | 优先使用卷而不是环境变量，因为环境变量会出现在 `env`、`/proc/1/environ`、子进程与崩溃转储中 |

### 3.3 Deployment 中新增的字段清单

| 字段 | 是否必须 | 含义 |
|---|---|---|
| `spec.template.spec.containers[].envFrom[]` | 可选 | 一次注入被引用对象中的**全部**键。列表中的每一项要么是 `configMapRef`，要么是 `secretRef`，两者不能合并写在同一个列表项里 |
| `envFrom[].configMapRef.name` / `envFrom[].secretRef.name` | 引用时必须 | 被引用对象的名称，必须位于同一个命名空间并且已经存在 |
| `envFrom[].prefix` | 可选 | 给注入的每个键名加上统一前缀，例如写成 `CONFIG_` 之后得到 `CONFIG_GREETING` |
| `containers[].env[].valueFrom.configMapKeyRef` / `.secretKeyRef` | 与 `env` 的 `value` 二者取其一 | 逐条注入指定的键，可以配合 `optional: true` 让缺少该键时不阻止容器启动 |
| `containers[].volumeMounts[]` | 与 `volumes[]` 成对出现 | 容器级：说明把卷挂到容器内的哪个路径。`subPath` 一旦出现，`mountPath` 必须指向文件 |
| `volumes[].configMap.name` | 引用 ConfigMap 时必须 | 被挂载的 ConfigMap 对象名称 |
| `volumes[].secret.secretName` | 引用 Secret 时必须 | 被挂载的 Secret 对象名称。**注意字段名是 `secretName`，不是 `configMap` 那种 `name`** |
| `volumes[].configMap.items` / `volumes[].secret.items` | 可选 | 只暴露指定的键，并把键名映射成指定的文件名 |
| `volumeMounts[].readOnly` | 可选 | 取值为 `true` 时卷以只读方式挂载 |
| `volumes[].configMap.defaultMode` / `volumes[].secret.defaultMode` | 可选，默认 `0644` | 卷内文件的权限。收紧权限时要同时考虑卷内文件的属主（默认是 root）与容器进程的 uid |
| `status` | 服务端字段 | 由 Kubernetes 写入并持续更新，手写清单时必须删除该段落 |

### 3.4 两种注入方式对照表

| 维度 | 以环境变量方式注入 | 以文件方式挂载 |
|---|---|---|
| 谁执行写入动作 | kubelet 在**创建容器时**把取值写入容器进程的环境 | kubelet 把取值写入节点上的卷目录，再把该目录挂载进容器 |
| 配置变更之后 | **不变化**，容器内保持创建时刻的取值。实测证据是 `env GREETING` 始终是 `Hello from ConfigMap` | 在若干秒到一分钟之内自动变化，不需要重建容器。实测证据是同一时刻文件已经是 `Hello from ConfigMap changed` |
| 变更的传播机制 | 没有传播机制，环境变量是创建时刻的快照 | kubelet 定期同步挂载内容，通过替换目录内的 `..data` 符号链接完成原子切换（p.342-344） |
| 单个文件挂载（`subPath`） | 不适用 | 以 `subPath` 挂载的单文件**不会更新**，因为它绕过了符号链接。实测证据是同一次修改之后 `sub-config.conf` 仍然是 `log_level=debug` |
| 生效需要什么动作 | 必须重建容器，常用做法是 `kubectl rollout restart deploy/<名称>` | 不需要任何动作；改变挂载结构（例如新增一个卷）仍然会触发滚动升级 |
| 键名限制 | 键名需要是合法的环境变量名。实测：短横线**可以**通过（`FOO-BAR` 被成功注入），与教材 p.332 的结论不同 | 键名直接成为文件名，没有环境变量名那种限制 |
| 敏感信息的暴露面 | 较大：`env`、`/proc/1/environ`、子进程继承、崩溃转储、日志打印配置都会暴露 | 较小：只是普通文件，默认权限 `0644`，可以按需收紧，也不会自动传给子进程 |

### 3.5 从创建对象到容器读到配置的完整工作链路

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 1 | 你 | `cm.yaml`、`secret.yaml` | `kubectl create -f` 把对象提交给 API Server | etcd 中写入 ConfigMap 与 Secret 对象；Secret 的 `stringData` 被编码进 `data` | `kubectl get cm,secret` |
| 2 | 你 | `deploy.env.yaml` | `kubectl apply -f` 提交 Deployment | `spec.template` 发生变化，Deployment 控制器创建一个新的 ReplicaSet | `kubectl get deploy,rs` |
| 3 | Deployment 控制器 | Deployment 的 `spec.replicas` 与 `spec.template` | 创建 ReplicaSet 对象并写入期望副本数量 | 新的 ReplicaSet 出现 | `kubectl get rs` |
| 4 | ReplicaSet 控制器 | ReplicaSet 的 `spec.template` | 创建 Pod 对象，Pod 处于 `Pending` | Pod 对象出现，`spec.nodeName` 为空 | `kubectl get po -o wide` |
| 5 | kube-scheduler | Pod 的资源声明等字段 | 为 Pod 选择一个节点，把结果写回 `spec.nodeName` | Pod 进入 `ContainerCreating` | `kubectl get po -o wide` |
| 6 | 该节点上的 kubelet | Pod 的 `envFrom`、`env`、`volumes` 字段 | 向 API Server 读取被引用的 ConfigMap 与 Secret 的取值（这一步由**节点**发起读取，不是由控制器转交；属补充说明） | 节点本地获得配置取值 | 无单独输出，见第 7 步的结果 |
| 7 | 该节点上的 kubelet | 上一步取得的取值 | 生成容器进程的环境变量；把挂载内容写入节点上的卷目录并挂载进容器；调用容器运行时创建容器 | 容器启动，`GREETING` 等变量出现在进程环境中，`/etc/webapp` 下出现与键名同名的文件 | `kubectl exec ... -- env`、`kubectl exec ... -- cat` |
| 8 | 你 | `kubectl edit cm` 或 `kubectl apply -f cm.yaml` | 修改 ConfigMap 中的一个取值 | etcd 中对象版本号增大；**已经运行的容器不受影响** | `kubectl get cm -o yaml` |
| 9 | 该节点上的 kubelet | 挂载目录的当前内容 | 在下一个同步周期内写入新的时间戳目录，并替换 `..data` 符号链接 | 容器内文件变成新取值；环境变量仍然是旧取值；`ls -la` 中 `..data` 指向新的时间戳目录 | `kubectl exec ... -- wget -qO- http://localhost:8080/` 同一次输出里看到两种结果 |
| 10 | kube-controller-manager | Deployment 的 Pod 模板 | 只有模板真正变化时才创建新的 ReplicaSet，因此修改 ConfigMap **不会**触发滚动升级 | ReplicaSet 数量不变 | `kubectl get rs` |
| 11 | 你 | 修改模板（例如新增 `subPath` 挂载或 Secret 卷） | `kubectl apply -f deploy.volume.yaml` | 模板变化触发滚动升级：新 ReplicaSet 出现，新 Pod 创建，旧 ReplicaSet 缩到 0 | `kubectl get po -l app=webapp-vol -w` |
| 12 | 你（需要环境变量生效时） | Deployment 名称 | `kubectl rollout restart deploy/<名称>` | 控制器按新模板重建 Pod，容器重新创建，环境变量重新注入 | `kubectl exec ... -- env` |

第 10 步是本次实验最重要的结论：**修改 ConfigMap 与修改 Deployment 是两件互不触发的事情**。以环境变量方式注入的取值，除了人为重建容器之外没有任何自动生效的途径。

### 3.6 卷热更新的实现：`..data` 符号链接的原子切换

| 环节 | 做什么 |
|---|---|
| 初始写入 | kubelet 在挂载目录里创建一个带时间戳的目录（形如 `..2026_09_21_01_59_37.611228343`），把每一个键写成一个文件放进去；再创建 `..data` 符号链接指向它；最后为每一个键创建一个同名符号链接指向 `..data/<键名>` |
| 读取路径 | 应用打开 `/etc/webapp-file/config.conf` 时，内核先解析 `config.conf` 这个链接，再解析它指向的 `..data/config.conf`，因此实际读到的是当前时间戳目录中的内容 |
| 更新动作 | kubelet 创建一个**新的**时间戳目录并写入新内容，然后把 `..data` 这一个符号链接指向新目录。实测结果是 `..data` 的时间戳从 01:59 变成 02:13 |
| 旧目录的处理 | 本次实测中旧时间戳目录被清理，`ls -la` 里只剩一个时间戳目录。因此「目录里同时存在新旧两份内容」这个预测没有出现（补充说明） |
| 为什么叫原子切换 | 全部改动被压缩成「替换一个符号链接」这一个动作，读取方看到的内容要么全是旧版本、要么全是新版本，不存在部分文件已更新、部分文件未更新的中间状态 |
| 其他条目的状态 | 键名符号链接 `config.conf -> ..data/config.conf` 本身没有被重建，实测它的时间戳仍然是挂载时刻 01:59，因为链接指向的路径字符串从未改变 |

### 3.7 `subPath` 挂载的取舍

| 维度 | 整目录挂载 | `subPath` 单文件挂载 |
|---|---|---|
| 容器内看到的东西 | 目录，目录内每个键是一个符号链接 | 普通文件，由 kubelet 把解析后的目标文件绑定挂载进来 |
| 实测的 `ls -l` 结果 | `lrwxrwxrwx ... config.conf -> ..data/config.conf` | `-rw-r--r-- ... config.conf`（64 字节） |
| 配置变更之后 | 变成新取值 | 保持旧取值 |
| 挂载目标路径的要求 | 目录本身可以不存在，由运行时创建 | `mountPath` 必须指向**文件**；目标路径的父目录必须位于可以创建条目的位置。实测把目标放在另一个只读卷挂载目录内部时，Pod 报 `RunContainerError` |
| 适用场景 | 需要热更新的配置文件目录 | 需要把一个文件放进已有目录，同时不覆盖该目录中的其他文件 |
| 代价 | 会覆盖挂载点上原有的内容 | 放弃热更新能力；Pod 重建之后才会读到新取值（这一条由机制推出，本次未单独实测） |

### 3.8 Secret 的存储与分发

| 环节 | 内容 | 依据 |
|---|---|---|
| 清单中的形式 | 可以用 `stringData` 写明文，也可以用 `data` 写 base64 编码 | 官方字段语义与本次实测 |
| API Server 中的形式 | `data` 段落中保存 base64 编码的字符串 | 实测 `ZGV2LW9ubHktcGFzc3dvcmQ=` |
| `describe` 的输出 | 只输出键名与字节数，不输出取值 | 实测 `DB_PASSWORD:  17 bytes` |
| 节点上的形式 | 只有使用它的节点才会获取内容，内容保存在 tmpfs 中，不写入节点磁盘，单个体积上限 1 MB | p.346 |
| 容器内的形式 | 以卷方式挂载时内容是**解码后的明文**，应用不需要自己处理编码；以环境变量方式注入时同样是明文 | 实测 `cat /etc/webapp-secret/DB_PASSWORD` 得到 `dev-only-password` |

### 3.9 教材结论与本次实测的差异

| 项目 | 内容 |
|---|---|
| 教材原文的结论 | 教材 7.4.4 节（p.332）说：键名中包含破折号时「创建环境变量时会忽略对应的条目，忽略时不会发出事件通知」 |
| 本次实测的结果 | `FOO-BAR=this-key-is-ignored` **出现在容器的进程环境中**，说明这个条目被成功注入 |
| 机制依据（补充，非书本原文） | `envFrom` 展开时对每一个键做的「是否为合法环境变量名」判定使用 C 标识符规则，也就是允许字母、数字、下划线、短横线与点号，并且首字符不能是数字。短横线位于这条规则之内，因此不会跳过 |
| 真正的限制在哪里 | 在 shell 语法层面：`$FOO-BAR` 会被 shell 解析成 `$FOO` 加上 `-BAR`，因此这类环境变量无法用变量语法引用，只能用 `env`、`printenv FOO-BAR`，或者程序里的 `os.LookupEnv("FOO-BAR")` 读取。本次实验的应用正是用后者读到的 |
| 待补的实验 | 需要确认「哪些键名才会被真正忽略」。可以增加一个以数字开头的键（例如 `1FOO`），它在 ConfigMap 中合法可创建，预期在 `envFrom` 展开时被跳过，从而验证上面的机制说明 |

---

## 四、命令

| 场景 | 命令 / 字段 | 说明 |
|---|---|---|
| 用字面量创建 ConfigMap | `kubectl create configmap <名称> --from-literal=<键>=<取值>` | 可以重复使用 `--from-literal` 传入多个键 |
| 从文件创建 ConfigMap | `kubectl create configmap <名称> --from-file=<键>=<文件路径>` | 省略 `=<键>` 时使用文件名作为键 |
| 生成 Secret 模板 | `kubectl create secret generic <名称> --from-literal=<键>=<取值> --dry-run=client -o yaml` | 只输出到文件，不创建资源；模板中 `data` 的取值已经是 base64 编码 |
| 取出 Secret 的取值并解码 | `kubectl get secret <名称> -o jsonpath='{.data.<键>}' \| base64 -d` | 用于证明 base64 是编码而不是加密 |
| 取出 ConfigMap 中带点号的键 | `kubectl get cm <名称> -o jsonpath='{.data.config\.conf}'` | jsonpath 中键名含点号时必须写成 `\.`，否则取不到取值 |
| 一次注入全部键 | `envFrom.configMapRef.name` / `envFrom.secretRef.name` | 列表中的每一项只能是两者之一，被引用对象必须同命名空间且已存在 |
| 逐条注入指定键 | `env[].valueFrom.configMapKeyRef` / `.secretKeyRef` | 可以配合 `optional: true` |
| 以卷方式挂载 ConfigMap | `volumes[].configMap.name` 与 `volumeMounts[].mountPath` | 两处 `name` 必须成对出现 |
| 以卷方式挂载 Secret | `volumes[].secret.secretName` 与 `volumeMounts[].mountPath` | 字段名是 `secretName`，写成 `name` 会被校验拒绝 |
| 只暴露指定键 | `volumes[].configMap.items[]` | 可以同时把键名映射成另一个文件名 |
| 单文件挂载 | `volumeMounts[].subPath` 与指向文件的 `mountPath` | 会失去热更新能力 |
| 观察卷的目录结构 | `kubectl exec <Pod> -- ls -la <挂载路径>` | 关注 `..data` 指向的时间戳目录与键名符号链接 |
| 查看环境变量 | `kubectl exec <Pod> -- env` | 用于核对 `envFrom` 的注入结果 |
| 让环境变量方式生效 | `kubectl rollout restart deploy/<名称>` | 环境变量是创建时刻的快照，必须重建容器 |
| 查看 Pod 状态变化 | `kubectl get po -l <标签> -w` | 观察滚动升级过程中新旧 Pod 的替换 |
| 定位容器创建失败 | `kubectl describe po <Pod 名称>` 与 `kubectl get po <Pod 名称> -o jsonpath='{.status.containerStatuses[0].state}'` | `RunContainerError` 属于运行时创建失败，容器从未启动，日志为空 |
| 删除 ConfigMap 中的单个键 | `kubectl patch cm <名称> --type=json -p '[{"op":"remove","path":"/data/<键>"}]'` | `kubectl apply` 不会删除不由它管理的字段，需要显式删除 |

---

## 五、易错点

| 编号 | 易错点 | 正确做法或判断依据 |
|---|---|---|
| 1 | 认为修改 ConfigMap 会触发 Deployment 升级 | 修改 ConfigMap 不会改动 Pod 模板，因此不会创建新的 ReplicaSet。以环境变量方式注入的取值必须重建容器才会变化 |
| 2 | 认为环境变量会在若干秒后自动更新 | 环境变量是容器创建时刻的快照。本次实测中 `GREETING` 被编辑两次之后，`env GREETING` 仍然是最初的取值 |
| 3 | 认为 Secret 的内容是加密的 | base64 只是编码。凭证的保护依赖访问控制与传输加密；`kubectl get secret -o jsonpath` 加上 `base64 -d` 即可还原明文 |
| 4 | 把「与 API Server 的通道受 TLS 保护」当成「Secret 对象的内容被加密」 | 通道加密对 ConfigMap 同样成立，它不构成两者的差别。两者的差别在于内容是否编码、分发范围、落盘位置、访问控制与体积上限 |
| 5 | 认为 `kubectl apply` 会把对象改成与清单完全一致 | apply 只删除由它管理的字段，也就是「上一次 apply 的记录里有、这次文件里没有」的字段。本次实测中修正键名之后旧的 `GREERTING` 一直保留，必须显式删除 |
| 6 | 改完工作区里的清单就认为集群对象已经改好 | 改完对象之后要立刻用只读命令确认**实时对象**的取值。本次第 17 步第一次失败的原因就是实时对象仍然是旧取值，导致卷没有理由更新 |
| 7 | 把 `subPath` 挂载与热更新同时期待 | 两者不可兼得。`subPath` 挂载的容器持有解析后的普通文件，不经过 `..data` 符号链接，因此配置变更对它无效 |
| 8 | 写了 `subPath` 却把 `mountPath` 指向目录 | 两者同时出现时 `mountPath` 必须指向文件；否则容器内该路径会变成文件，应用按原路径读取会失败 |
| 9 | 把 `subPath` 的挂载目标放在另一个只读卷挂载目录内部 | 运行时需要创建挂载目标，父目录只读时创建失败，Pod 报 `RunContainerError`。本次实测把它改到独立目录 `/etc/webapp-sub/config.conf` 之后挂载成功 |
| 10 | 认为密钥名写成什么都可以 | 键名必须与应用读取的路径一致。本次实验中键名一开始拼成 `GREERTING`，Kubernetes 不会报错，只是应用读不到，表现为 `env GREETING = "<未注入>"` |
| 11 | 在 YAML 块标量里留下行尾空格 | 块标量会原样保留行尾空格。本次实测 `config.conf` 的可见内容是 46 字节，实际 64 字节，差额 15 字节来自行尾空格，应用解析配置时可能因此出错 |
| 12 | 认为 Secret 卷与 ConfigMap 卷的目录权限完全相同 | 本次实测两者都带有 `..data` 结构，但目录权限分别是 `drwxrwxrwx` 与 `drwxrwxrwt`，差异原因尚未确认，列为待查项，不要在面试中凭印象解释 |
| 13 | 把 `RunContainerError` 当成应用启动失败 | 它表示容器运行时创建容器失败，容器进程从未启动，因此日志为空。应用自身启动失败对应的状态是 `CrashLoopBackOff` |

---

## 六、我的疑问

| 编号 | 疑问 | 计划如何解决 |
|---|---|---|
| 1 | ConfigMap 卷的目录权限是 `drwxrwxrwx`，Secret 卷的目录权限是 `drwxrwxrwt`，这个差异由什么决定 | 第 3 周学习存储与卷时结合资料查证，在此之前不要凭印象作答 |
| 2 | 哪些键名才会被 `envFrom` 真正忽略 | 补做一次以数字开头的键（例如 `1FOO`）的实验，预期它因为首字符不是字母而被跳过 |
| 3 | 把 `defaultMode` 收紧到 `0400` 时应用读不到内容，`securityContext.fsGroup` 具体如何配合 | 第 3 周学习安全上下文时验证 |
| 4 | 以 `subPath` 挂载的容器在 Pod 重建之后是否会拿到新取值 | 机制上应当会，因为重建时会重新解析并重新挂载；本次未单独实测，属于推断 |
| 5 | 卷挂载的更新延迟由哪些因素决定，是否可以缩短 | 与 kubelet 的同步周期和缓存有效期有关，具体参数留待后续查证 |

---

## 七、Linux 每日一题 Day 10 · 目录权限

> 对应 `docs/linux/Linux-每日一题.md` 第 10 题。

### 7.1 目录的 `x` 位是干什么的

**答**：目录的 `x` 位是**穿越位**（在 `ls -l` 中显示为 `d` 之后第三个字符组中的 `x`）。它决定一个进程能否把该目录当作路径中的一段来解析，也就是能否**穿过**这个目录去访问其中**已知名称**的条目。

判定要点如下。

| 观察项 | 含义 |
|---|---|
| 有 `x` 位 | 可以把目录作为路径的一段，对其中已知名称的条目做 `stat`、打开、执行 |
| 没有 `x` 位 | 即使知道条目的名称，也无法访问它；路径解析在目录这一层就失败 |
| 与 `r` 位的分工 | `r` 位决定能否**列出目录中的名称清单**，`x` 位决定能否**穿过目录访问具体条目**。这是两个独立的能力 |

### 7.2 只有 `r` 没有 `x` 的目录

**答**：可以列出目录中的文件名，但不能访问其中任何一个条目的内容与元数据。

| 操作 | 结果 | 原因 |
|---|---|---|
| `ls /dir` | 成功，能列出名称 | `r` 位允许读取目录条目清单 |
| `ls -l /dir` | 能列出名称，但每个条目的权限、属主、大小都显示为 `?`，并且出现 `cannot access` 一类的提示 | 显示这些信息需要对该条目做 `stat`，而 `stat` 需要穿过目录，也就是需要 `x` 位 |
| `cat /dir/file` | 失败，提示权限不足 | 打开条目需要穿过目录 |
| `/dir/script` | 失败 | 执行同样需要穿过目录 |

### 7.3 只有 `x` 没有 `r` 的目录

**答**：可以用**已知的完整路径**穿过目录访问其中已知名称的条目，但不能列出目录内容。

| 操作 | 结果 | 原因 |
|---|---|---|
| `ls /dir` | 失败，提示权限不足 | 列出名称需要 `r` 位 |
| `cd /dir` | 成功 | 进入目录只需要 `x` 位 |
| `cat /dir/file`（已知文件名） | 成功 | 穿过目录只需要 `x` 位，能否读取文件内容由文件自身的权限决定 |
| `ls /dir/file`（已知文件名） | 成功 | 对已知条目做 `stat` 只需要穿过目录 |

**一句话总结**：`r` 决定「能不能看到有哪些名字」，`x` 决定「能不能走过去按名字拿东西」。

---

## 八、面试问答卡批改记录（Day 3）

| 题目 | 我的回答要点 | 批改结论 |
|---|---|---|
| 1. 为什么要把配置放在 ConfigMap 中，而不是写进镜像？ | 这是一种解耦策略；注入动作由 kubelet 完成；能提供自动更新机制；可以避免更新不及时以及频繁重启这类工程问题 | 部分正确。答对了「解耦」与「kubelet 完成注入」，但漏掉了两条核心原因：① 同一份镜像需要部署到开发、测试、生产多个环境，配置必须在部署时决定；② 修改配置时不应该重新构建并重新发布镜像。此外「避免频繁重启」这一条只对卷挂载方式成立，环境变量方式恰恰必须重建容器才能读到新取值，因此不能把它当作普遍好处 |
| 2. 以环境变量注入与以卷挂载注入有什么区别？ | 环境变量在整个 Pod 生命周期内不可变，必须重启才能修改；卷挂载会随 Kubernetes 的更新机制动态变化 | 基本正确。需要把限定条件说准：变化的是**容器进程的环境**，不是整个 Pod；读取 ConfigMap 的动作发生在**容器创建时刻**，因此生效的条件是重建容器。还应当补上三点：卷挂载的更新依赖 kubelet 的定期同步，延迟在若干秒到一分钟之间；`subPath` 单文件挂载**不会**更新；两种方式在容器内拿到的都是明文 |
| 3. Secret 是加密存储的吗？ | 不是加密存储，而是以 base64 编码保存在 YAML 里，可以解码 | 正确。可以再补一句：编码关系在 API Server 侧的 `data` 段落中同样成立；真正的保护手段是访问控制（RBAC）与传输加密 |
| 4. Secret 与 ConfigMap 在用法上有什么区别？ | Secret 用于密码这类需要安全性的配置，它在传输中是加密的；ConfigMap 用于存放端口之类的常规配置 | 不完全正确。用途区分答对了，但「传输中是加密的」这个说法混淆了两个层次：受 TLS 保护的是与 API Server 之间的**通道**，这对 ConfigMap 同样成立，不构成两者的差别。两者在用法上的真实差异是：注入方式**完全相同**；差别在内容是否编码、分发范围与落盘位置（Secret 使用 tmpfs 且体积上限 1 MB，p.346）、能否单独授权、是否有内置类型，以及推荐的注入方式不同（Secret 优先用卷） |
| 5. 目录的 `x` 位是干什么的？ | `x` 表示可执行，在目录这里就是能否访问内部文件 | 方向正确，措辞需要精确：目录的 `x` 位称为穿越位，决定能否把目录当作路径的一段，去访问其中**已知名称**的条目。它与 `r` 位分工不同，`r` 决定能否列出名称 |
| 6. 只有 `r` 没有 `x` 的目录，能做什么、不能做什么？ | 无法查看文件内容，无法执行文件，可以看到目录信息 | 方向正确。需要把「能看到目录信息」说准：`ls` 能列出名称，但 `ls -l` 中每个条目的权限、属主、大小都会显示为 `?` 并伴随 `cannot access`，因为显示这些信息需要 `stat`，而 `stat` 需要穿过目录 |
| 7. 只有 `x` 没有 `r` 的目录，能做什么、不能做什么？ | 不清楚 | 无法列出目录内容（`ls` 失败），但可以 `cd` 进入，也可以按**已知的完整路径**读取、执行其中已知名称的条目。判断依据是列出名称需要 `r` 位，穿过目录只需要 `x` 位 |

---

## 九、十分钟速记卡

> 用途：复习时只读这一节。内容与前面的小节重复是刻意的，重复的目的是不翻回正文就能回忆。

### 9.1 三个对象各一句话

| 对象 | 一句话定义 | 最容易说错的地方 |
|---|---|---|
| ConfigMap | 存放普通配置的命名空间级键值对象（`v1`/`ConfigMap`），本身没有进程，也不会主动进入容器 | 不能说「ConfigMap 会注入到容器里」，注入动作由 kubelet 在创建容器时完成 |
| Secret | 与 ConfigMap 结构相同的命名空间级键值对象，内容以 base64 编码存放，并额外受到分发范围与访问控制的约束 | 它不是加密存储，base64 只是编码；「传输加密」是通道属性，不是它的专属差别 |
| 卷（ConfigMap 卷与 Secret 卷） | kubelet 依据 Pod 模板创建的目录结构，目录内每个键对应一个文件，通过 `..data` 符号链接实现原子切换 | 卷不是对象；对象（ConfigMap、Secret）与卷（挂载结果）是两层不同的东西 |

### 9.2 必须记住的字段

| 对象 | 字段 | 记住什么 |
|---|---|---|
| ConfigMap | `data` | 取值必须是字符串；一个键对应卷内的一个文件 |
| ConfigMap | `binaryData` | 二进制内容，取值必须是 base64 编码 |
| Secret | `data` | 取值必须是 base64 编码 |
| Secret | `stringData` | 只写字段：写明文，读完变成 `data` |
| Secret | `type` | 省略时为 `Opaque`；其他常见值有 `kubernetes.io/tls`、`kubernetes.io/dockerconfigjson`、`kubernetes.io/service-account-token` |
| Deployment | `envFrom[].configMapRef.name` / `.secretRef.name` | 一次注入全部键；列表项二选一，不能合并 |
| Deployment | `env[].valueFrom.configMapKeyRef` / `.secretKeyRef` | 逐条注入指定键，可加 `optional: true` |
| Deployment | `volumes[].configMap.name` | 引用 ConfigMap 的字段名是 `name` |
| Deployment | `volumes[].secret.secretName` | 引用 Secret 的字段名是 `secretName`，写错会被校验拒绝 |
| Deployment | `volumeMounts[].subPath` | 与 `mountPath` 同时出现时，`mountPath` 必须指向文件；并且失去热更新 |

### 9.3 全链路摘要

| 步骤 | 执行者 | 做了什么 |
|---|---|---|
| 1 | 你 | `kubectl create` 提交 ConfigMap 与 Secret，对象写入 etcd，Secret 的明文被编码进 `data` |
| 2 | 你 | `kubectl apply` 提交 Deployment，模板变化产生新的 ReplicaSet |
| 3 | Deployment 控制器 | 创建 ReplicaSet，写入期望副本数量 |
| 4 | ReplicaSet 控制器 | 创建 Pod 对象 |
| 5 | kube-scheduler | 选择节点并写回 `spec.nodeName` |
| 6 | 节点上的 kubelet | 向 API Server 读取被引用的 ConfigMap 与 Secret 的取值 |
| 7 | 节点上的 kubelet | 写入进程环境变量、写入卷目录并挂载、调用容器运行时创建容器 |
| 8 | 你 | 修改 ConfigMap，只有 etcd 中的对象发生变化，运行中的容器不受影响 |
| 9 | 节点上的 kubelet | 在同步周期内写新时间戳目录、替换 `..data`，卷内文件更新而环境变量保持旧值 |

要记住三件事：修改 ConfigMap 不会触发 Deployment 升级；环境变量的生效条件是重建容器；卷内文件的生效条件是 kubelet 的同步周期。

### 9.4 今天实测出来的硬结论

| 编号 | 结论 | 实测数据 |
|---|---|---|
| 1 | 镜像内部本来没有配置目录 | 基线命令输出「配置目录不存在」 |
| 2 | ConfigMap 的取值是明文，Secret 的取值是 base64 编码 | `GREETING: Hello from ConfigMap` 对比 `ZGV2LW9ubHktcGFzc3dvcmQ=` |
| 3 | base64 可以任意解码，因此它不是加密 | `ZGV2LW9ubHktcGFzc3dvcmQ=` 解码得到 `dev-only-password` |
| 4 | `describe secret` 只输出字节数，不输出取值 | `DB_PASSWORD:  17 bytes` |
| 5 | 键名包含短横线的条目会被成功注入，与教材 p.332 的结论不同 | `env` 输出中出现 `FOO-BAR=this-key-is-ignored` |
| 6 | `kubectl apply` 不会删除不由它管理的字段 | 修正键名之后，`env` 输出中同时存在 `GREERTING` 与 `GREETING` |
| 7 | 同一个 Pod 内，环境变量与卷内文件会出现取值分化 | `env GREETING = "Hello from ConfigMap"`，同时 `file GREETING = "Hello from ConfigMap changed"` |
| 8 | 环境变量方式必须重建容器才生效 | `kubectl rollout restart deploy/webapp` 之后 `GREETING=Hello from ConfigMap changed` |
| 9 | 整目录挂载得到符号链接，`subPath` 挂载得到普通文件 | `lrwxrwxrwx config.conf -> ..data/config.conf` 对比 `-rw-r--r-- config.conf` |
| 10 | `subPath` 挂载的文件不随 ConfigMap 更新 | 修改之后整目录挂载的文件是 `log_level=info`，`subPath` 挂载的文件仍是 `log_level=debug` |
| 11 | 原子切换只替换 `..data` 一个符号链接 | `..data` 的时间戳由 `01:59` 变为 `02:13`，而 `config.conf` 符号链接的时间戳仍是 `01:59` |
| 12 | 旧时间戳目录会被清理 | 更新之后 `ls -la` 中只剩 `..2026_09_21_02_13_20.198768711` 一个时间戳目录 |
| 13 | Secret 以卷方式挂载之后容器内是明文 | `cat /etc/webapp-secret/DB_PASSWORD` 得到 `dev-only-password` |
| 14 | 块标量会保留行尾空格 | `config.conf` 可见内容 46 字节，文件大小 64 字节，差额 15 字节 |
| 15 | `subPath` 命名的挂载目标路径写错会使容器无法创建 | 写成 `/etc/webapp-file/sub-config.path` 时报 `RunContainerError`，改成 `/etc/webapp-sub/config.conf` 后达到 `1/1 Running` |

### 9.5 面试问答卡标准答法

| 问题 | 标准答法 |
|---|---|
| 为什么要把配置放在 ConfigMap 中，而不是写进镜像？ | 两条理由：同一份镜像需要部署到开发、测试、生产多个环境，配置必须在部署时决定；修改配置时不应该重新构建并重新发布镜像。此外配置抽成独立对象之后可以按名引用，同一个 Pod 模板能够复用不同的配置 |
| 以环境变量注入与以卷挂载注入有什么区别？ | 环境变量由 kubelet 在创建容器时写入进程环境，是创建时刻的快照，修改配置必须重建容器；卷由 kubelet 持续同步，修改配置后文件会在若干秒到一分钟之内自动更新，但以 `subPath` 挂载的单文件不会更新。此外环境变量的暴露面更大，Secret 更推荐用卷 |
| Secret 是加密存储的吗？ | 不是。它只做 base64 编码，`kubectl get secret -o jsonpath` 加上 `base64 -d` 就能还原明文。它的保护来自访问控制与传输加密；内容只会分发到使用它的节点并保存在 tmpfs 中，体积上限 1 MB |
| Secret 与 ConfigMap 在用法上有什么区别？ | 注入方式完全相同，都是环境变量、`envFrom` 或卷挂载。差别在于：Secret 的内容以 base64 编码存放，分发范围与落盘位置受控（tmpfs，p.346），可以被单独授权，有内置类型，体积上限 1 MB；并且 Secret 更推荐以卷方式使用，避免环境变量带来的泄漏面 |

### 9.6 出现「配置没有生效」时的排查顺序

| 顺序 | 命令 | 看什么 |
|---|---|---|
| 1 | `kubectl get cm <名称> -o yaml` 或 `kubectl get cm <名称> -o jsonpath='{.data.<键>}'` | 先确认**实时对象**的取值是否已经改变。自变量没变，后面的一切观察都无意义 |
| 2 | `kubectl exec <Pod> -- env \| grep <键名>` | 环境变量是否是创建时刻的旧取值；这种情况需要 `kubectl rollout restart` |
| 3 | `kubectl exec <Pod> -- ls -la <挂载路径>` | `..data` 指向的时间戳目录是否已经更新；如果仍是旧时间戳，说明 kubelet 还没有完成同步 |
| 4 | `kubectl exec <Pod> -- cat <文件路径>` | 文件取值是否已经更新；`subPath` 挂载的文件预期仍然是旧取值 |
| 5 | `kubectl describe po <Pod 名称>` | 容器是否停在 `CreateContainerConfigError`（引用的对象或键不存在）或 `RunContainerError`（挂载设置失败） |
| 6 | `kubectl get po -l <标签> -w` | 模板是否真的触发过一次滚动升级，当前 Pod 是否是新模板创建的 Pod |

### 9.7 最容易答错的九点

| 编号 | 错误说法 | 正确说法 |
|---|---|---|
| 1 | 「改了 ConfigMap，Deployment 就会滚动升级」 | 修改 ConfigMap 不改变 Pod 模板，不会创建新的 ReplicaSet |
| 2 | 「环境变量过一会儿会自己更新」 | 环境变量是容器创建时刻的快照，必须重建容器 |
| 3 | 「Secret 是加密的」 | base64 是编码，可以解码；保护来自访问控制与传输加密 |
| 4 | 「Secret 在传输中是加密的，这就是它和 ConfigMap 的区别」 | 受 TLS 保护的是与 API Server 的通道，对 ConfigMap 同样成立；差异在内容是否编码、分发范围、落盘位置、访问控制与体积上限 |
| 5 | 「`apply` 之后集群对象与清单完全一致」 | apply 只删除由它管理的字段，历史遗留的键会被保留，必须显式删除 |
| 6 | 「`subPath` 挂载也能热更新」 | 不经过 `..data` 符号链接，因此不会更新；Pod 重建之后才会拿到新取值 |
| 7 | 「`mountPath` 写目录或文件都可以」 | 与 `subPath` 同时出现时 `mountPath` 必须指向文件 |
| 8 | 「容器创建失败就去查应用日志」 | `RunContainerError` 说明容器从未启动，日志为空，要找 `describe` 里的事件与容器状态消息 |
| 9 | 「键名随便写，Kubernetes 会报错提醒」 | 键名与应用读取路径之间没有校验关系，写错只会表现为「变量未注入、文件读不到」 |

### 9.8 合上笔记自测六个问题

| 编号 | 问题 | 判断标准 |
|---|---|---|
| 1 | 说出 ConfigMap 与 Secret 在三个维度上的差别 | 内容是否编码、分发范围与落盘位置、能否单独授权 |
| 2 | 说出一次配置注入从提交到容器读到的六个阶段 | 提交对象 → 模板变化产生 ReplicaSet → 创建 Pod → 调度 → kubelet 读取对象 → kubelet 写入环境与卷 |
| 3 | 修改 ConfigMap 之后，环境变量与卷内文件分别在什么条件下变成新取值 | 环境变量需要重建容器；卷内文件需要 kubelet 完成一次同步，且该文件不是 `subPath` 挂载 |
| 4 | `..data` 符号链接的作用是什么 | 让一次更新变成「替换一个链接」的原子动作，读取方永远看不到半新半旧的内容 |
| 5 | 目录的 `r` 位与 `x` 位各自决定什么 | `r` 决定能否列出名称，`x` 决定能否穿过目录访问已知名称的条目 |
| 6 | 容器内读到 Secret 的值时是否还是 base64 | 不是，写入卷之前已经解码，容器内是明文 |
