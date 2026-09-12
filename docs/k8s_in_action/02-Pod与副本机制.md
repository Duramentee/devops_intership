# 模块 02 · Pod 与副本机制（第 3~4 章）

> 目标：理解 Pod 是最小单元，会用标签组织资源，会用探针和副本控制器让应用"活着且够数"。

## 一、核心概念（整体观）

### 1. Pod 是什么（p.108-113）

- Pod 是**一组并置的容器**，是 K8s 的基本构建模块；同一 Pod 的容器**永远在同一节点**，不可能跨节点。
- 为什么需要 Pod：容器设计为"每容器跑一个进程"，但多个紧密相关的进程需要绑成一个管理单元。
- **部分隔离**：同 Pod 容器共享 Network、UTS、IPC 命名空间（共享 IP、主机名、端口空间），文件系统默认隔离。
- **平坦网络**：所有 Pod 同处一个共享网络地址空间，Pod 间无 NAT，各自有可路由 IP。
- 同 Pod 容器共享端口空间 → 不能绑相同端口；不同 Pod 端口空间独立，永无冲突；同 Pod 内用 `localhost` 互访。
- **拆 Pod 原则**：Pod 是扩缩容基本单位，扩缩需求不同的组件分到不同 Pod；同 Pod 多容器主要用于"主进程 + sidecar（日志轮转、数据处理）"。

### 2. 组织三件套（p.126-150）

| 机制 | 用途 | 关键点 |
|---|---|---|
| 标签 label | 任意键值对，标识资源 | key 在资源内唯一 |
| 选择器 selector | 按标签选资源子集 | 多条件逗号分隔需全部匹配 |
| 注解 annotation | 键值对，供工具使用 | **没有**注解选择器；≤256KB |
| 命名空间 namespace | 资源名称作用域，分组 | 只隔离名称，**不提供运行时隔离** |

### 3. 副本机制全家福（p.154-204）

| 控制器 | 干什么 | 何时用 |
|---|---|---|
| ReplicationController(RC) | 保证匹配选择器的 Pod 数=期望值 | 旧，已被 RS 取代 |
| ReplicaSet(RS) | 同 RC，选择器更强（matchExpressions） | 一般由 Deployment 托管 |
| DaemonSet(DS) | 每节点恰好一个 Pod | 日志采集、监控、kube-proxy |
| Job | 跑完就结束的一次性任务 | 批处理 |
| CronJob | 按 cron 时间表定期建 Job | 定时任务 |

## 二、关键细节

### 存活探针（p.155-161）

- 三种机制：**HTTP GET**（2xx/3xx 成功）、**TCP socket**（能建立连接）、**Exec**（退出码 0）。
- 由节点上的 **Kubelet** 执行（不是控制平面）。
- 参数默认值：`initialDelaySeconds=0`、`timeoutSeconds=1`、`periodSeconds=10`、连续失败 3 次重启。

### RC/RS 如何保证副本数（p.163-170）

- 控制器**持续对比**"匹配标签的 Pod 数"与期望值，不一致就协调（少补多删）。
- 它响应的不是删除事件，而是删除后产生的**状态**（数量不足）。
- 节点故障：直建的 Pod 永久丢失；RC/RS 托管的会被替换重建（先等节点失联几分钟，Pod 变 Unknown）。

## 三、命令速查

| 场景 | 命令 / 字段 | 说明 |
|---|---|---|
| 看 Pod 完整 YAML | `kubectl get po <name> -o yaml` | metadata/spec/status 三部分 |
| 查字段说明 | `kubectl explain pods` / `kubectl explain pod.spec` | 离线查属性 |
| 从 YAML 创建 | `kubectl create -f x.yaml` | 任意资源 |
| 看标签 | `kubectl get pods --show-labels` / `-L env` | 全量 / 指定列 |
| 加/改标签 | `kubectl label po <n> env=prod` / 改值加 `--overwrite` | |
| 选择器 | `kubectl get pods -l env` / `-l '!env'` / `-l 'env in (prod,devel)'` | `!` 要加引号 |
| 看日志 | `kubectl logs <pod>` / 多容器 `-c <name>` / 上一个 `--previous` | |
| 转发端口 | `kubectl port-forward <pod> 8888:8080` | 不经 Service 调试 |
| 加注解 | `kubectl annotate pod <n> key="value"` | |
| 命名空间 | `kubectl get ns` / `get po -n kube-system` / `create namespace <n>` | |
| 节点打标签 | `kubectl label node <n> gpu=true` | 配合 nodeSelector |
| 调度约束 | `spec.nodeSelector: {gpu: "true"}` | 只去有该标签的节点 |
| 删 Pod | `kubectl delete po <n>` / `-l 标签` / `ns 整删` | SIGTERM→30s→SIGKILL |
| 删除全部 | `kubectl delete po --all` / `delete all --all` | 注意托管 pod 会重建 |
| 看重启原因 | `kubectl describe pod` | 事件里 exit code 137/143 |
| 只删控制器留 Pod | `kubectl delete rc <n> --cascade=false` | 让 Pod 脱管 |
| RS 选择器 | `selector.matchExpressions` 支持 In/NotIn/Exists/DoesNotExist | |
| Job 字段 | `restartPolicy: OnFailure`、`completions`、`parallelism`、`activeDeadlineSeconds`、`backoffLimit` | |
| CronJob | `schedule: "0,15,30,45 * * * *"`（分 时 日 月 周）| |

## 四、易错点

1. **不设 `initialDelaySeconds`**：应用没起来就被探针杀，常见退出码 137（SIGKILL）、143（SIGTERM）→ 启动即重启。
2. 健康检查端点**不能要求认证**，否则无限重启。
3. 探针别耦合外部依赖（前端探针别因连不上后端而失败）。
4. Java 应用别用重量级 Exec 探针（每次起 JVM），用 HTTP GET。
5. 模板的标签与选择器不匹配 → 控制器无休止创建 Pod。
6. Pod spec 里的端口是**展示性的**，不影响连接；只要容器绑 0.0.0.0 就能被连。
7. `kubectl logs` 只显示最近一次轮替后日志；Pod 删除日志也删。

## 五、动手实践

1. 写 Pod YAML（带 label `app=kubia`），`kubectl create -f` 创建。
2. 写一个带 `livenessProbe.httpGet`（路径 `/healthz` 故意 500）的 Pod，观察 `RESTARTS` 增长、`kubectl describe` 看事件。
3. 用 `kubectl run` + 标签建 Pod，练 `-l` 选择器筛选。
4. 写一个 RC YAML（replicas=3），删掉其中一个 Pod，看它被自动重建；再 `--cascade=false` 删 RC，看 Pod 脱管。
5. 写一个 Job（`restartPolicy: OnFailure`，跑 `sleep 5` 的命令），观察 COMPLETIONS=1 后不再重启。

## 六、自测题

1. 同 Pod 两个容器共享哪些命名空间？能用 localhost 互访吗？能绑同一端口吗？
2. 存活探针三种机制各怎么判定成功？
3. RC 保证副本数的机制是"响应删除事件"还是"对比状态"？这决定了什么？
4. 直接 `kubectl run` 建的 Pod 和 RC 托管的 Pod，在节点宕机后表现有何不同？
5. DaemonSet 和 ReplicaSet 的区别是什么？各举一个典型用途。
6. Job 的 Pod 为什么不能用默认的 `restartPolicy: Always`？

> 回查：p.109-110、p.155、p.163-164、p.171、p.188、p.196。
