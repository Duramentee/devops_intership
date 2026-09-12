# 模块 04 · 配置与 API 交互（第 7~8 章）

> 目标：把配置和敏感信息从镜像里拆出来，并学会从 Pod 内获取元数据、访问 API server。

## 一、核心概念（整体观）

### 1. 给容器配置的三种方式（p.311-312）

命令行参数、环境变量、挂载配置文件（卷）。配套的"解耦"手段：**ConfigMap**（普通配置）、**Secret**（敏感数据）、**Downward API**（运行期元数据）。

### 2. 覆盖命令和参数（p.313-317）

| Dockerfile | K8s 字段 |
|---|---|
| ENTRYPOINT | `command` |
| CMD | `args` |

- `command`/`args`/`env` 创建后**都不可修改**。
- 推荐 Dockerfile 用 exec 形式 `ENTRYPOINT ["node","app.js"]`，避免 shell 吞掉信号（详见模块08）。

### 3. ConfigMap（p.323-345）

- 把配置抽成独立键值对资源；Pod 按名引用，同一 Pod 定义可复用不同配置。
- 三种注入：单条 `valueFrom.configMapKeyRef` → env；`envFrom` 一次全注入（可加 `prefix`）；卷挂载（每条成一个文件）。
- **热更新**：挂成卷后，更新 ConfigMap 卷内文件会自动更新（`..data` 符号链接原子切换）——但 `subPath` 挂的单文件**不会**更新。

### 4. Secret（p.346-357）

- 结构与 ConfigMap 相同，但条目是 **Base64 编码**（是"编码"不是"加密"）。
- 只分发到需要的节点、只存内存（tmpfs）不落盘，大小限 1MB。
- 每个 Pod 自动挂 **default-token Secret**（ca.crt / namespace / token），用于访问 API server。
- 优先用 **secret 卷**而非环境变量（env 容易在日志/报错/子进程里泄露）。

### 5. Downward API（p.362-373）

- 不是 REST 端点，是把 Pod 自身的元数据以 env 或文件注入容器。
- 可暴露：Pod 名/IP/命名空间/节点名/服务账户名、CPU/内存 requests 与 limits、Pod 标签、注解。
- 标签和注解**只能通过卷**（运行期可变，env 无法更新）；资源字段需要 `divisor` 除数；卷引用容器级元数据必须写 `containerName`。

### 6. 从 Pod 访问 API server（p.374-391）

三件事：① 找到地址（`KUBERNETES_SERVICE_HOST/PORT` 或 `https://kubernetes`）；② 验证服务器（`ca.crt`）；③ 用 token 授权（`Authorization: Bearer $TOKEN`）。
- `kubectl proxy` 在本机 8001 端口转发 HTTP 并处理认证。
- **ambassador 容器**：sidecar 跑 kubectl proxy，主容器用普通 HTTP 连 localhost，对应用透明。

## 二、关键细节

- `envFrom` 遇到非法键名（如 `FOO-BAR`）会**静默忽略**，不报错。
- configMap 卷每个条目成一个文件，默认权限 644（`defaultMode` 可改），`items` 只暴露指定条目。
- 挂整个卷到非空目录会隐藏原文件；`subPath` 只挂单文件但失去热更新。
- Secret 的 `stringData` 是只写字段，读回时被编码进 `data`。

## 三、命令速查

| 场景 | 命令 / 字段 | 说明 |
|---|---|---|
| 字面量建 ConfigMap | `kubectl create configmap <n> --from-literal=key=value` | 可多次 |
| 从文件建 | `--from-file=config.conf` / `--from-file=key=config.conf` | 文件名作键 |
| 单条注入 env | `valueFrom.configMapKeyRef.name/key` + `optional: true` | |
| 全量注入 | `envFrom.configMapRef` + `prefix: CONFIG_` | |
| args 引用 env | `$(VAR)` | 命令行参数里引用 |
| configMap 卷 | `volumes[].configMap` → `mountPath`，`items`、`defaultMode` | |
| 单文件挂载 | `volumeMount.subPath` | 不覆盖目录其他文件 |
| 更新后重载 | `kubectl edit configmap` → `kubectl exec ... nginx -s reload` | 手动通知 |
| 建 generic Secret | `kubectl create secret generic <n> --from-file=...` | Base64 编码 |
| 建 TLS/docker-registry | `kubectl create secret tls ...` / `docker-registry ...` | |
| 拉私有镜像 | `spec.imagePullSecrets` | 引用 docker-registry Secret |
| 关默认令牌 | `automountServiceAccountToken: false` | |
| Downward API env | `valueFrom.fieldRef.fieldPath: metadata.name` | Pod 名 |
| 资源除数 | `resourceFieldRef.divisor: "1m"` / `"1Ki"` | |
| 卷里文件名 | `downwardAPI.items[].path` | |
| 启动代理 | `kubectl proxy` | 监听 8001 |
| 浏览 API | `curl http://localhost:8001/apis/batch/v1` | |

## 四、易错点

1. `command`/`args`/`env` 创建后不可改；env 只能设在**容器级**。
2. `envFrom` 对非法键名静默丢弃，不转下划线。
3. Secret 是编码不是加密；挂载后自动解码，应用不用手动处理。
4. 生产环境**永远不要跳过证书校验**（否则凭证暴露给中间人）。
5. 标签/注解不能走 env（会变），只能走卷。
6. 卷暴露容器级资源元数据时，**必须**指定 `containerName`。

## 五、动手实践

1. 建 ConfigMap（from-literal 和 from-file 各一个），分别用 env、envFrom、卷三种方式注入，`kubectl exec` 验证。
2. `kubectl edit configmap` 改一个值，观察卷里文件是否自动更新；再用 `subPath` 挂单文件，观察它**不**更新。
3. 建一个 generic Secret，用卷挂载，exec 进 Pod `cat` 验证是明文。
4. 用 Downward API 把 Pod 名/IP 暴露成 env，打印出来。
5. `kubectl proxy` + curl 列出 `apis/apps/v1/deployments`，理解 REST 结构。

## 六、自测题

1. ConfigMap 和 Secret 的本质区别是什么？（提示：不是功能，是编码和分发方式）
2. ConfigMap 卷热更新的机制是什么？为什么 `subPath` 挂载不更新？
3. Downward API 能暴露哪些元数据？哪些只能走卷？
4. 从 Pod 访问 API server 需要解决哪三件事？各靠 default-token Secret 里的哪个文件？
5. ambassador 容器模式解决了什么问题？代价是什么？

> 回查：p.346、p.342-344、p.363-372、p.381-386、p.389-391。
