# Day 4 学习笔记 · 存活探针与就绪探针（让应用具备自动重启与自动摘除流量的能力）

> 日期：2026-09-21 · 代码：`code/week2/day4/`（`deploy.liveness.yaml`、`deploy.readiness.yaml`、`deploy.startup.yaml`、`deploy.startup.noprobe.yaml`、`go-webapp/`、`outputs/`）
> 配套资料：`plan/week2/任务明细.md` 中的 Day 4 节、`docs/k8s_in_action/02-Pod与副本机制.md` 的探针小节、教材第 4 章 4.1 节（p.155-161，存活探针）与第 5 章 5.5 节（p.247-253，就绪探针）
> 起点资产：Deployment `webapp`（副本数量为 2、镜像 `webapp:v6`）、Service `webapp`（ClusterIP 为 `10.96.135.12`、选择器为 `app=webapp`）、ConfigMap `webapp-config`、Secret `webapp-secret`
> 今日的模型变化：Pod 模板中的容器段落里新增了两个检查字段，也就是 `livenessProbe` 与 `readinessProbe`。应用本身没有改动它的业务逻辑，改动只在于新增了 `/healthz`、`/readyz`、`/state` 与 `/admin/fault` 四个端点，其中前两个端点分别供两种探针调用。
> 今日新增资产：ReplicaSet `webapp-7f78498c55`（带两种探针）、ReplicaSet `webapp-5bd67f6c57`（启动探针对照组）

---

## 一、今日速览（结论）

| 编号 | 结论 | 原始输出依据 |
|---|---|---|
| 1 | 探针的检查动作由 Pod 所在节点上的 kubelet 执行，`kubectl describe po` 输出中的事件来源列写的正是 `kubelet` | `05-describe-liveness.txt` 的 `Events` 段落，每一行的 `From` 列都是 `kubelet` |
| 2 | 本次存活探针的实际参数为 `delay=5s timeout=1s period=5s #success=1 #failure=3`，与清单中的取值逐项一致 | `05-describe-liveness.txt` 的 `Liveness:` 行 |
| 3 | 存活探针失败会产生两条事件：`Liveness probe failed: HTTP probe failed with statuscode: 500` 与 `Container webapp failed liveness probe, will be restarted` | 同上，`Events` 段落 |
| 4 | 容器被重启时，Pod 的 uid 与 IP 地址完全不变，只有容器标识与重启计数改变。实测取值为 uid `6fc68957-44b9-4979-aaf0-66216732356c` 与 IP `10.244.0.14` 在重启前后保持一致，容器标识由 `containerd://b0331821…` 变为 `containerd://53273ab2…`，重启计数由 0 变为 1 | `05-identity-before.txt` 与 `05-identity-after.txt` |
| 5 | 本次由探针触发的终止，容器的退出码是 `2`，原因是 `Error`。它不是 `137`，因为进程没有等待到宽限期结束就被终止 | `07-exit-code.txt` 的取值为 `2 Error 2026-09-21T08:49:52Z 2026-09-21T08:54:41Z` |
| 6 | 上一个被终止的容器的日志完整记录了因果链：启动之后连续 7 次探测返回 200，注入故障之后连续 3 次返回 500，随后日志终止 | `06-logs-previous.txt`，时间从 `08:50:01` 到 `08:54:47` |
| 7 | 就绪探针失败时，`READY` 一列由 `1/1` 变为 `0/1`，而 `RESTARTS` 一列保持为 `0` | `10-po-after-fault.txt` 中 `webapp-7f78498c55-kst78` 的两状态行 |
| 8 | 就绪探针失败之后，该 Pod 的地址从 `kubectl get endpoints webapp` 的输出中消失，端点列表只剩另一个 Pod 的地址 | `11-endpoints-after-fault.txt`，输出为 `webapp 10.244.0.17:8080` |
| 9 | `EndpointSlice` 与 `Endpoints` 的口径不同：前者列出全部地址并用就绪条件标识状态，后者只列出就绪地址。同一时刻 `EndpointSlice` 显示 `10.244.0.16,10.244.0.17`，而 `Endpoints` 只显示 `10.244.0.17` | `11-endpoints-after-fault.txt` 的两段输出 |
| 10 | 未就绪的 Pod 收不到 Service 转发的流量。从就绪的 Pod 向 Service 发起 20 次请求，响应全部来自就绪的那个容器，未就绪的容器日志里没有任何 `/state` 请求行 | `12-service-routing.txt`，就绪 Pod 的 `/state` 请求行数为 `20`，未就绪 Pod 的日志中只有 `/healthz` 与 `/readyz` |
| 11 | 同一个容器内，两种探针各自独立计时，一类失败不影响另一类的判定。未就绪期间 `/healthz` 一直返回 200，`/readyz` 一直返回 500 | `12-service-routing.txt` 中 `kst78` 的日志 |
| 12 | 解除就绪故障之后，`READY` 在一到两个探测周期内恢复为 `1/1`，端点列表重新出现该 Pod 的地址，全过程 `RESTARTS` 保持为 `0` | `13-fault-clear-readyz.txt` 与 `13-endpoints-after-recovery.txt` |
| 13 | 由探针注入的故障是进程内的状态，容器一旦被重建，故障随即清零。重启之后容器内 `/state` 返回 `healthz_fault=false` 与 `uptime_seconds=25` | `08-fault-clear-healthz.txt` |
| 14 | 没有启动探针时，启动耗时 40 秒的应用会被存活探针反复杀掉，重启计数增长到 6，状态进入 `CrashLoopBackOff`，Deployment 的滚动升级因新 Pod 永不就绪而无法完成，命令以 `error: timed out waiting for the condition` 结束 | `14-startup-without-probe.txt` |
| 15 | 加上启动探针之后，同一个应用不再被重启，新的 Pod 进入就绪状态，滚动升级最终完成。新的 ReplicaSet 为 `webapp-f9856cb66`，它的两个 Pod 都是 `1/1` 且重启计数都是 0，升级以 `deployment "webapp" successfully rolled out` 结束 | `14-startup-with-probe.txt` |
| 16 | 启动探针成功之前，就绪探针完全没有被调用。整份日志中 `/readyz` 的第一次出现是在 `09:45:05`，也就是启动探针第一次返回 200 的同一秒 | `15-state-timeline.txt` |
| 17 | 启动探针成功之前，存活探针没有参与判定。慢启动窗口内 `/healthz` 连续 8 次返回 503（从 `09:44:25` 到 `09:45:00`），若这些失败由存活探针计数，按 `failureThreshold` 为 3 的配置早在 `09:44:35` 就应触发重启，而实测的重启计数全程为 0 | `15-state-timeline.txt`、`15-startup-probe-describe.txt` |

---

## 二、任务清单

| 编号 | 任务 | 完成 | 原始输出留在哪 |
|---|---|---|---|
| 1 | 记录七项基线（集群、Pod、Service 与 Deployment、端点列表、镜像标签、容器内进程、工作负载） | ✅ | `outputs/00-*.txt` |
| 2 | 生成三种探针清单的客户端模板并逐字段阅读 | ✅ | `outputs/02-dry-run-liveness.txt` |
| 3 | 应用只带存活探针的清单并确认就地更新 | ✅ | `outputs/03-*.txt` |
| 4 | 注入存活故障并等待容器被重启 | ✅ | `outputs/04-fault-inject-healthz.txt`、`outputs/05-restart-wait.txt` |
| 5 | 记录重启前后的 Pod 标识与容器标识 | ✅ | `outputs/05-identity-before.txt`、`outputs/05-identity-after.txt` |
| 6 | 查看事件、上一个容器的日志与退出码 | ✅ | `outputs/05-describe-liveness.txt`、`outputs/06-logs-previous.txt`、`outputs/07-exit-code.txt` |
| 7 | 应用同时带两种探针的清单 | ✅ | `outputs/09-apply-readiness.txt` |
| 8 | 只对一个 Pod 注入就绪故障并观察 `READY` 变为 `0/1` | ✅ | `outputs/10-po-after-fault.txt` |
| 9 | 确认该 Pod 离开端点列表并确认流量不再进入它 | ✅ | `outputs/11-endpoints-after-fault.txt`、`outputs/12-service-routing.txt` |
| 10 | 解除就绪故障并确认恢复 | ✅ | `outputs/13-*.txt` |
| 11 | 启动探针的两组对照实验 | ✅ | `outputs/14-startup-without-probe.txt`、`outputs/14-startup-with-probe.txt` |
| 12 | 用运行时长序列替代定时采样，作为时间参照 | ✅ | `outputs/15-state-timeline.txt` |
| 13 | 记录三种探针同时存在时的 `describe` 输出 | ✅ | `outputs/15-startup-probe-describe.txt` |

---

## 三、概念（机制）

> 阅读顺序建议：先读 3.1，弄清三种探针各自回答什么问题、以及它们作为容器字段在 API 里的位置；再读 3.2，掌握三者共用的字段清单；然后读 3.3，把三者各自引发的动作分别走一遍全流程；接着读 3.4 做三者对照；最后读 3.5 与 3.6，理解就绪状态如何影响端点列表、以及退出码为什么有两种取值。

### 3.1 三种探针各自是什么

三种探针在 API 里处于同一个位置，也就是 `spec.containers[]` 下面三个并列的字段，它们地位相同，可以同时存在于同一个容器上。本次三种探针并存时的字段路径与职责如下。

| 探针 | 字段路径 | 一句话定义 | 它回答的问题 | 连续失败达到阈值之后 kubelet 的动作 | 来源 |
|---|---|---|---|---|---|
| 存活探针 | `spec.containers[].livenessProbe` | 它是判断「容器是否还需要继续运行」的检查字段 | 这个容器还需要继续运行吗 | 终止容器主进程，并在同一个 Pod 内重新创建一个全新的容器 | 教材 4.1 节（p.155-161） |
| 就绪探针 | `spec.containers[].readinessProbe` | 它是判断「Pod 是否已经可以接收流量」的检查字段 | 这个 Pod 现在可以接收流量吗 | 不重启容器，只把 Pod 的 `Ready` 条件写成 `False`，控制平面据此把该地址移出端点列表 | 教材 5.5 节（p.247-253） |
| 启动探针 | `spec.containers[].startupProbe` | 它是判断「容器的主进程是否已经启动完成」的检查字段 | 这个容器的主进程启动完成了吗 | 只在启动阶段计时：在它第一次成功之前，另外两个探针都不会被执行；如果它在 `failureThreshold` 与 `periodSeconds` 的乘积之内始终没有成功，则终止容器并重新创建 | 我的补充，书本没有：Kubernetes 1.16 作为 alpha 引入，1.18 升为 beta，1.20 正式可用 |

三种探针共用同一套「它是什么」的答案，只有「谁创建它」这一条需要按模板层级展开说明。

| 问题 | 答案 | 依据 |
|---|---|---|
| 它是什么类型的 API 资源 | 三者都不是资源，没有 `kind`，也不能被单独列出，它们是 Pod 模板中容器下面的三个并列字段 | 教材 p.155 的表述是「可以为 pod 中的每个容器单独指定存活探针」，说明探针挂在容器上 |
| 它属于哪个层级 | 三者都属于命名空间级，它们随 Pod 定义存在于某个命名空间中，集群级不存在探针 | Pod 是命名空间级资源 |
| 谁创建它 | 三者都由你写在 Pod 模板里，然后由 Deployment 的模板传给 ReplicaSet，最后由 ReplicaSet 的模板传给每一个 Pod | 补充：三层模板逐层复制，因此修改任意一个探针字段都会触发滚动升级并生成新的 ReplicaSet |
| 它的生命周期与谁绑定 | 三者都与容器绑定：Pod 被重建时计时归零，容器被重启时三者的计时同样重新开始 | 补充，与教材 p.158「会创建一个全新的容器」配合理解 |
| 它不是什么 | 三者都不是 Service 的健康状态、不是监控系统的采集项、不是由控制平面执行的检查动作，也不是应用内部的自我检测 | 教材 p.155：必须从外部检查应用程序的运行状况，而不是依赖应用的内部检测 |

### 3.2 字段清单（三者共用）

三个探针的字段结构完全相同，只是名称不同。下表按「必填、由 API Server 补全默认值、由 kubelet 写入」三类分开标注。

| 字段 | 是否必须 | 含义 | 默认值由谁补全 |
|---|---|---|---|
| `httpGet.path` | 使用 HTTP 检查时必填 | 请求的路径，本次存活探针使用 `/healthz`，就绪探针使用 `/readyz` | 无默认值，不写则为空字符串 |
| `httpGet.port` | 使用 HTTP 检查时必填 | 容器内监听的端口，本次为 `8080`。它与 Service 端口无关 | 无默认值，不写则 API Server 拒绝清单 |
| `httpGet.scheme` | 否 | 协议，取 `HTTP` 或 `HTTPS` | 由 API Server 补全为 `HTTP` |
| `httpGet.httpHeaders` | 否 | 附加的请求头 | 由 API Server 补全为空列表 |
| `tcpSocket.port` | 使用 TCP 检查时必填 | 尝试建立连接的容器端口 | 无默认值 |
| `exec.command` | 使用命令检查时必填 | 在容器内执行的命令，退出码 0 判定成功 | 无默认值 |
| `initialDelaySeconds` | 否 | 容器创建之后等待多少秒才开始第一次探测。本次存活探针为 5，就绪探针为 2 | 由 API Server 补全为 `0`，教材 p.158 的 `delay=0s` 就是这个取值 |
| `periodSeconds` | 否 | 每隔多少秒探测一次。本次两种探针都是 5 | 由 API Server 补全为 `10`，教材 p.159 的 `period=10s` |
| `timeoutSeconds` | 否 | 单次探测的响应超时时间 | 由 API Server 补全为 `1` |
| `failureThreshold` | 否 | 连续失败多少次判定为失败。本次为 3 | 由 API Server 补全为 `3`，教材 p.159 的 `#failure=3` |
| `successThreshold` | 否 | 连续成功多少次判定为恢复 | 由 API Server 补全为 `1`；存活探针的该字段只允许取 1 |
| `terminationGracePeriodSeconds` | 否 | 探针导致的终止所使用的宽限期 | 由 API Server 补全，遵循 Pod 级设置 |

因此手写清单时应当省略的是 `scheme`、`httpHeaders`、`timeoutSeconds`、`successThreshold` 与 `failureThreshold` 等字段，只在需要偏离默认值时写出。今天刻意把 `periodSeconds` 写成 5，作用是把「第一次失败到容器被重启」的耗时从约 30 秒缩短到约 15 秒，便于在一个观察窗口内看到完整过程。

三个探针共用同一批字段，但它们对同一字段的用法不同。本次三种探针并存时的实际取值可以从 `15-startup-probe-describe.txt` 中逐项读到：

| 探针 | 检查路径 | `initialDelaySeconds` | `periodSeconds` | `timeoutSeconds` | `failureThreshold` | 最多容忍多久的失败 |
|---|---|---|---|---|---|---|
| 存活探针 | `/healthz` | 5 | 5 | 1 | 3 | 15 秒 |
| 就绪探针 | `/readyz` | 2 | 5 | 1 | 3 | 15 秒 |
| 启动探针 | `/healthz` | 未设置，默认为 0 | 5 | 1 | 12 | 60 秒 |

三个字段在三者身上的语义差异也需要注意：`initialDelaySeconds` 对存活探针与就绪探针的含义是「容器创建之后等待多久开始第一次探测」，对启动探针通常不设置；`successThreshold` 只对就绪探针有意义（启动探针与存活探针的该字段只允许取 1）；`failureThreshold` 与 `periodSeconds` 的乘积在启动探针上表示「最多允许应用启动多久」。

### 3.3 全流程工作链路

三种探针在「容器已经被创建、kubelet 开始按周期探测」之后才产生差异，因此它们的前五个阶段完全相同。下面先列出三者共有的前置阶段，再分别列出三者各自的后续动作。

**共有前置阶段**

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 1 | 你 | 对应的清单文件 | 执行 `kubectl apply` | Deployment 的 `spec.template` 被更新，`metadata.generation` 增加 | `kubectl get deploy webapp -o yaml` |
| 2 | Deployment 控制器（控制平面） | 更新后的 Pod 模板 | 创建一个新的 ReplicaSet，并把旧 ReplicaSet 的副本数量逐步调小 | 集群中出现一个新的 ReplicaSet | `kubectl get rs -o wide` |
| 3 | ReplicaSet 控制器（控制平面） | 新 ReplicaSet 的副本数量 | 创建 Pod 对象，它的容器段落里带有探针字段 | Pod 进入 `Pending` 状态 | `kubectl get po -w` |
| 4 | kube-scheduler（控制平面） | Pod 的资源需求与节点状态 | 为 Pod 选定节点并写入 `spec.nodeName` | `PodScheduled` 条件变为 `True` | `kubectl describe po` 的事件段 |
| 5 | kubelet（该节点） | Pod 清单 | 通过容器运行时创建容器并启动主进程 | 容器状态变为 `running`，`startedAt` 写入 | `kubectl describe po` 的 `State` 段落 |

#### 3.3.1 存活探针失败到容器被重启

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 6 | kubelet（该节点） | `initialDelaySeconds` 与 `periodSeconds` | 初始延迟到期之后，按周期向容器发起 HTTP GET | 容器日志中出现 `http method=GET path=/healthz` 行 | `kubectl logs` |
| 7 | 容器内的应用 | 收到 `/healthz` 请求 | 返回状态码 500 | 500 不属于 2xx 与 3xx，本次探测记作失败（教材 p.155） | 应用日志中的 `probe path=/healthz result=500` |
| 8 | kubelet（该节点） | 连续失败次数 | 累加失败次数并与 `failureThreshold` 比较 | Pod 事件出现 `Liveness probe failed` | `kubectl describe po` |
| 9 | kubelet（该节点） | 达到阈值的判断结果 | 终止容器主进程：先发送 SIGTERM，等待宽限期后发送 SIGKILL | 容器状态变为 `terminated`，退出码写入 `lastState` | `kubectl describe po` 的 `Last State` 段落 |
| 10 | kubelet（该节点） | 容器的终止结果 | 重新创建一个全新的容器，而不是在原容器内重启进程（教材 p.158） | `restartCount` 增加 1；Pod 的名称、uid 与 IP 地址保持不变（本次实测取值见 4.1 节） | `kubectl get po` 的 `RESTARTS` 一列 |

#### 3.3.2 就绪探针失败到地址被移出端点列表

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 6 | kubelet（该节点） | `initialDelaySeconds` 与 `periodSeconds` | 按周期向容器发起 HTTP GET，路径为 `/readyz` | 容器日志中出现 `http method=GET path=/readyz` 行 | `kubectl logs` |
| 7 | 容器内的应用 | 收到 `/readyz` 请求 | 返回状态码 500 | 本次探测记作失败 | 应用日志中的 `probe path=/readyz result=500 reason=injected-fault` |
| 8 | kubelet（该节点） | 连续失败次数 | 累加失败次数并与 `failureThreshold` 比较，同时把 Pod 的 `Ready` 条件写成 `False` 并上报 | Pod 事件出现 `Readiness probe failed`；`kubectl get po` 的 `READY` 一列由 `1/1` 变为 `0/1`，而 `RESTARTS` 保持为 `0` | `10-po-after-fault.txt` |
| 9 | Endpoints 控制器（控制平面） | 观察到的 Pod 的 `Ready` 条件 | 把未就绪的地址从 `Endpoints` 的 `addresses` 与 `EndpointSlice` 的就绪状态中移除 | 端点列表中的地址数量减少，本次由两个地址减少为一个地址 | `11-endpoints-after-fault.txt` |
| 10 | kube-proxy（每个节点） | 端点列表的变化 | 更新节点上的转发规则 | 新建的连接不再被转发到该 Pod，已有的连接不受影响 | `12-service-routing.txt` 中未就绪 Pod 的日志里没有任何业务请求行 |
| 11 | kubelet（该节点） | 探针在后续周期中重新成功 | 把 `Ready` 条件写回 `True` 并上报 | 地址重新回到端点列表，`READY` 恢复为 `1/1` | `13-fault-clear-readyz.txt` 与 `13-endpoints-after-recovery.txt` |

补充说明第 8 步至第 10 步里最容易想错的一环：**「Pod 是否就绪」这个判断由 kubelet 做出并写入 Pod 的 `status`，而「端点列表里有哪些地址」由控制平面的 Endpoints 控制器维护，转发规则由每个节点上的 kube-proxy 生效**。探针本身不直接修改端点列表，它只改变 Pod 的状态。这也解释了为什么从注入故障到流量真正改变去向之间存在一个探测周期的延迟。

#### 3.3.3 启动探针从第一次探测到交棒

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 6 | kubelet（该节点） | `startupProbe` 的 `periodSeconds` | 容器被创建之后立即开始探测（本次该字段未设置，取默认值 0） | 容器日志中出现 `/healthz` 的探测请求行，本次的返回值为 503 | `15-state-timeline.txt` 中 `09:44:25` 开始的行 |
| 7 | kubelet（该节点） | 启动探针的失败次数 | 累加失败次数并与 `failureThreshold`（本次为 12）比较 | 失败次数在阈值之内，容器不被重启；同时**存活探针与就绪探针都不被启动** | 同一份日志中，`/readyz` 在启动探针成功之前完全没有出现；重启计数全程为 0 |
| 8 | 容器内的应用 | 慢启动窗口结束之后的探测请求 | 返回状态码 200 | 启动探针成功，启动阶段结束 | 日志中 `09:45:05` 的 `probe path=/healthz result=200` |
| 9 | kubelet（该节点） | 启动探针的成功结果 | 停止执行启动探针，并开始执行存活探针与就绪探针 | 日志中同一秒出现第一条 `/readyz` 探测记录，两条探针从此刻起各自按自己的周期执行 | 同上的 `09:45:05` 两行 |

启动探针只负责「启动阶段」这一段，因此它成功之后就不再工作；如果它在 `failureThreshold` 与 `periodSeconds` 的乘积之内始终没有成功，kubelet 会终止容器并重新创建，容器随即进入与存活探针失败相同的重启流程。

### 3.4 三者对照

| 对比项 | 存活探针 | 就绪探针 | 启动探针 |
|---|---|---|---|
| 它回答的问题 | 这个容器还需要继续运行吗 | 这个 Pod 现在可以接收流量吗 | 这个容器的主进程启动完成了吗 |
| 检查失败之后的动作 | kubelet 终止并重新创建容器 | kubelet 只把 `Ready` 条件写成 `False`，容器继续运行 | 在启动阶段不执行其他动作，只在超过容忍时间之后终止容器 |
| 对 `RESTARTS` 一列的影响 | 持续增长 | 保持为 0 | 启动成功之前保持为 0；超过容忍时间后开始增长 |
| 对端点列表的影响 | 间接：容器重启期间该 Pod 会短暂不可用 | 直接：未就绪的地址被移出就绪地址列表 | 间接：启动期间 Pod 不可就绪，因此在启动阶段地址不会出现 |
| 对 Deployment 升级的影响 | 容器不断重启时新 Pod 无法进入稳定状态 | 未就绪的新 Pod 使滚动升级停滞（教材 p.436） | 容忍较长的启动时间，因此启动慢不再阻止升级 |
| 成功之后是否继续执行 | 继续执行，覆盖容器整个生命周期 | 继续执行，覆盖容器整个生命周期 | 停止执行，第一次成功之后永久退出 |
| 本次实测证据 | 重启计数由 0 变为 1 | `READY` 由 `1/1` 变为 `0/1` 而 `RESTARTS` 保持为 0 | `/readyz` 第一次出现与启动探针第一次成功同在 `09:45:05` |
| 引入版本 | Kubernetes 1.0 | Kubernetes 1.0 | 1.16 alpha、1.18 beta、1.20 正式可用（补充） |
| 什么时候应当使用它 | 应用可能出现死锁、僵死、内存耗尽等无法自行恢复的状态 | 应用启动之后需要预热，或者需要依赖外部服务才能提供服务 | 应用启动耗时较长，或者启动耗时在不同环境下波动较大 |

### 3.5 就绪状态与端点列表

就绪探针的结果最终落在两个对象上：一个是 Pod 自身的 `status.conditions` 中的 `Ready` 条件，另一个是该 Service 对应的端点列表。前者由 kubelet 写入，后者由控制平面依据前者维护，两者之间的连接与控制顺序在 3.3.2 节已经列出。

`Endpoints` 与 `EndpointSlice` 两个对象的口径不同，这一点在本次实测中直接体现出来：

| 对象 | 输出内容 | 含义 |
|---|---|---|
| `kubectl get endpoints webapp -o wide` | `10.244.0.17:8080` | `addresses` 字段只包含就绪的地址，因此未就绪的 Pod 不出现在这里 |
| `kubectl get endpointslices -o wide` | `10.244.0.16,10.244.0.17` | `endpoints` 列表包含全部地址，每一个地址带有 `conditions.ready` 字段表示它是否就绪 |
| 版本提示 | `Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice` | 本集群为 v1.37.0，新代码应当读取 `EndpointSlice` |

### 3.6 退出码：137 与 2 分别对应哪个分支

教材 p.158 与 p.160 给出的结论是「退出码 137 表示进程被外部信号终止，137 等于 128 加 9，9 是 SIGKILL 的信号编号」。本次实测得到的是 `2`，两者并不矛盾，它们分别对应终止流程的两个分支。

| 分支 | 触发条件 | 观测到的退出码 | 依据 |
|---|---|---|---|
| 宽限期耗尽之后被强制终止 | 主进程不响应 SIGTERM，kubelet 等待 `terminationGracePeriodSeconds`（默认 30 秒）超时之后发送 SIGKILL | 137 | 教材 p.158、p.160 |
| 主进程在收到 SIGTERM 之后自行结束 | 主进程对 SIGTERM 的处置导致它立刻结束 | 本次为 `2`，原因为 `Error` | `07-exit-code.txt` 与 `05-describe-liveness.txt` 的 `Last State` 段落 |

本次容器在最后一次探测失败的同秒结束（`08:54:41` 与日志最后一行 `08:54:47` 处于同一时间窗），因此没有走到 SIGKILL 这个分支。补充说明（书本没有这一条）：容器内的主进程是 PID 1，Linux 内核对 PID 1 有一层保护，没有安装处理函数的终止类信号会被丢弃；Go 运行时在没有调用 `signal.Notify` 的情况下收到 SIGTERM 时，走的是「恢复默认处置并重新向自己发送」这条路径，这条路径在 PID 1 上失效，运行时随后以退出码 2 结束进程。要确认这条解释，可以做两个补充实验：在应用里用 `signal.Notify` 接收 SIGTERM 并优雅退出，观察退出码是否变成 0；或者把 `terminationGracePeriodSeconds` 设为 0，观察退出码是否变成 137。

---

## 四、实测逐字段解析

### 4.1 重启前后的 Pod 标识（`05-identity-before.txt` 与 `05-identity-after.txt`）

| 字段 | 重启之前 | 重启之后 | 结论 |
|---|---|---|---|
| `metadata.uid` | `6fc68957-44b9-4979-aaf0-66216732356c` | 相同 | Pod 对象没有被重建 |
| `status.podIP` | `10.244.0.14` | 相同 | 沙箱没有被重建，网络命名空间被复用 |
| `status.containerStatuses[0].containerID` | `containerd://b0331821…` | `containerd://53273ab2…` | 容器是全新的 |
| `status.containerStatuses[0].restartCount` | `0` | `1` | kubelet 记录了一次重启 |

### 4.2 就绪故障期间的 `kubectl get po -w` 输出（`10-po-after-fault.txt`）

| 输出行 | 解读 |
|---|---|
| `webapp-7f78498c55-kst78  1/1  Running  0  21s` | 注入之前的状态，两个 Pod 都就绪 |
| `webapp-7f78498c55-kst78  0/1  Running  0  36s` | 注入之后经过连续三次失败，`Ready` 条件变为假。注意 `RESTARTS` 仍然是 0 |
| 最终 `kubectl get po -o wide` 一行 | `kst78` 为 `0/1`，`lt8fj` 为 `1/1`，两个 Pod 的重启计数都是 0 |

### 4.3 流量验证（`12-service-routing.txt`）

| 观察项 | 取值 | 结论 |
|---|---|---|
| 20 次请求的响应中 `uptime_seconds` | 全部为 `62` 或 `63` | 所有请求都由同一个容器处理 |
| 未就绪 Pod `kst78` 的日志 | 只有 `/healthz` 返回 200 与 `/readyz` 返回 500 两类记录，没有 `/state` | Service 没有把请求转发给它 |
| 就绪 Pod `lt8fj` 的 `/state` 请求行数 | `20` | 20 次请求全部落入这个 Pod |

### 4.4 启动探针的两组对照（`14-startup-without-probe.txt` 与 `14-startup-with-probe.txt`）

| 对比项 | 没有启动探针 | 有启动探针 |
|---|---|---|
| 慢启动窗口 | `SLOW_START_SECONDS=40` | `SLOW_START_SECONDS=40` |
| 存活探针在何时开始探测 | 容器被创建 5 秒之后立即开始，不受启动进度的限制 | 启动探针成功之后才开始；本次启动探针在 40 秒的慢启动窗口结束之后的第一个探测周期内成功 |
| 容器是否被重启 | 是，观察窗口内重启计数达到 6 | 否，新 ReplicaSet 的两个 Pod 的重启计数都是 0，取值为 `webapp-f9856cb66-bsq9l` 与 `webapp-f9856cb66-kdhqt` |
| `STATUS` 一列的取值 | 在 `Running` 与 `CrashLoopBackOff` 之间切换 | `Running`，两个 Pod 的 `READY` 都是 `1/1` |
| Deployment 的升级结果 | `error: timed out waiting for the condition`，新 Pod 永远不就绪，因此旧 Pod 无法被替换 | `deployment "webapp" successfully rolled out`，升级状态依次经过「1 out of 2 new replicas have been updated」、「1 old replicas are pending termination」与成功三行 |

### 4.5 启动探针生效期间的完整时间线（`15-state-timeline.txt`）

| 时刻（UTC） | 主进程已运行 | 日志行 | 解读 |
|---|---|---|---|
| `09:44:21` | 0 秒 | `webapp v6 正在监听 :8080` | 主进程启动，开始计时 |
| `09:44:25` | 4 秒 | `probe path=/healthz result=503 reason=still-starting uptime=4s` | 启动探针第一次探测，应用正处于模拟的慢启动窗口，返回 503。此处记录的间隔与启动探针的 `periodSeconds=5` 一致 |
| `09:44:30` 至 `09:45:00` | 9 秒至 39 秒 | 同样格式的 7 行，全部为 503 | 启动探针持续探测。整个窗口内重启计数为 0 |
| `09:45:05` | 44 秒 | `probe path=/healthz result=200 uptime=44s`，紧接着出现 `probe path=/readyz result=200 uptime=44s` | 慢启动窗口在 40 秒结束，启动探针成功；就绪探针从同一秒才开始执行 |
| `09:45:10` 至 `09:45:50` | 49 秒至 89 秒 | `/healthz` 与 `/readyz` 各一行，全部返回 200 | 启动探针停止工作，存活探针与就绪探针各自按 5 秒周期继续执行 |

这份日志给出三条结论：

| 编号 | 结论 | 判断依据 |
|---|---|---|
| 1 | 启动探针成功之前，就绪探针完全没有被调用 | 整份日志中 `/readyz` 只从 `09:45:05` 开始出现，而在此之前 `/healthz` 已经被探测了 8 次 |
| 2 | 启动探针成功之前，存活探针没有参与判定 | 慢启动窗口内的 8 次 503 如果由存活探针计数，按 `failureThreshold` 为 3 的配置早在 `09:35` 附近的第三次失败时就应重启容器，而实测重启计数始终为 0 |
| 3 | 三段探针的参数在一次 `kubectl describe po` 中逐项可读 | `15-startup-probe-describe.txt` 中 `Liveness` 为 `delay=5s timeout=1s period=5s #success=1 #failure=3`，`Readiness` 为 `delay=2s timeout=1s period=5s #success=1 #failure=3`，`Startup` 为 `delay=0s timeout=1s period=5s #success=1 #failure=12` |

---

## 五、易错点

| 编号 | 易错点 | 正确做法 |
|---|---|---|
| 1 | 把 `initialDelaySeconds` 设置得比应用的启动耗时更短 | 先测量启动耗时再设置该字段。教材 p.158 指出取值过小会让容器在能够正确响应请求之前就被重启，本次对照实验把这一条直接演示了出来 |
| 2 | 健康检查端点要求身份认证 | 探针请求不携带任何凭证，要求认证的端点会让检查永远失败 |
| 3 | 两个探针指向同一个路径 | 一次故障会同时影响重启与流量两件事，两类后果无法分开观察。本次把存活探针指向 `/healthz`、就绪探针指向 `/readyz` |
| 4 | 在容器内的命令里访问 Service 名称来调用自己 | 容器内部访问自己的进程应当使用 `localhost` 与容器端口；Service 名称只在集群内的其他 Pod 中可用 |
| 5 | 认为探针由控制平面执行 | 探针由 Pod 所在节点上的 kubelet 执行，因此控制平面不可用时已经运行的容器仍会被继续探测 |
| 6 | 认为重启是「在原来的容器里重新启动进程」 | 教材 p.158 明确写道会创建一个全新的容器，因此容器可写层中的改动会丢失 |
| 7 | 把实验用的故障注入类比为生产做法 | `/admin/fault` 是本次实验的辅助端点，生产应用不得暴露可以远程改变运行状态的开关 |
| 8 | 认为注入的故障会一直存在并造成无限重启 | 本次故障是进程内状态，容器被重建之后即清零，因此只重启一次。教材第 4 章把「返回 500」写死在源码里，才会出现无限循环 |
| 9 | 用 `kubectl get endpoints` 的输出去判断「Pod 是否存在」 | 该输出只列出就绪地址，Pod 仍然存在但未就绪时不会出现在其中。要查看全部地址应当读取 `EndpointSlice` |

---

## 六、面试问答卡

| 编号 | 问题 | 答题要点 |
|---|---|---|
| 1 | 存活探针与就绪探针有什么区别 | 两者回答的问题不同：存活探针回答「容器还需要继续运行吗」，失败时 kubelet 终止并重新创建容器，Pod 的名称与 IP 不变，只有重启计数增加；就绪探针回答「Pod 现在可以接收流量吗」，失败时容器不被重启，只把 `Ready` 条件置为假，控制平面据此把地址移出端点列表。本次实测的两组数据分别是重启计数由 0 变 1，以及 `READY` 由 `1/1` 变 `0/1` 而 `RESTARTS` 保持 0 |
| 2 | 探针由哪个组件执行，检查机制有哪三种 | 由 Pod 所在节点上的 kubelet 执行。三种机制是 HTTP GET（返回 2xx 或 3xx 判定成功）、TCP 连接（能够建立连接判定成功）与命令执行（退出码为 0 判定成功）。`kubectl describe po` 的事件来源列写的是 `kubelet`，这一点可以现场核对 |
| 3 | `initialDelaySeconds` 设置得过小会怎样，启动探针如何解决 | 过小会让应用尚未启动完成就被判定为失败，容器被反复重启，本次实测重启计数达到 6 并进入 `CrashLoopBackOff`，同时 Deployment 的升级因新 Pod 永不就绪而超时。启动探针把启动阶段单独计时，在它成功之前另外两个探针不执行，因此存活探针可以配置得更激进以快速发现运行期故障。需要注意启动探针是 Kubernetes 1.16 之后才有的字段 |
| 4 | 健康检查端点为什么不能要求身份认证 | 探针请求由 kubelet 发起，不携带任何凭证。要求认证的端点会永远返回未授权状态，从而被判定为失败，容器会被反复重启 |
| 5 | 为什么本集群上应当读取 `EndpointSlice` 而不是 `Endpoints` | v1 的 `Endpoints` 在 v1.33 之后已经废弃，`kubectl get endpoints` 会直接打印废弃警告。`EndpointSlice` 用 `conditions.ready` 标识每个地址的就绪状态，因此它同时包含就绪与未就绪的地址，本次实测中两者输出的地址数量不同 |

---

## 七、十分钟速记卡

| 项目 | 内容 |
|---|---|
| 一句话定义 | `livenessProbe` 是「容器是否还需要继续运行」的检查字段，失败时 kubelet 重建容器；`readinessProbe` 是「Pod 是否已经可以接收流量」的检查字段，失败时只把地址移出端点列表；`startupProbe` 是「主进程是否启动完成」的检查字段，它成功之前另外两个探针都不执行 |
| 必记字段 | `httpGet.path`、`httpGet.port`、`initialDelaySeconds`（默认 0）、`periodSeconds`（默认 10）、`timeoutSeconds`（默认 1）、`failureThreshold`（默认 3）、`successThreshold`（默认 1） |
| 全链路摘要 | 你提交清单 → Deployment 控制器建新 ReplicaSet → ReplicaSet 控制器建 Pod → 调度器绑定节点 → kubelet 创建容器并启动主进程 → kubelet 按周期探测 → 连续失败达到阈值 → 存活探针失败时 kubelet 终止容器并在同一个 Pod 内重建，就绪探针失败时 kubelet 把 `Ready` 置为假、控制平面把地址移出端点列表 |
| 当天实测硬结论 | ① 探针由 kubelet 执行；② 重启前后 uid `6fc68957-…` 与 IP `10.244.0.14` 不变，容器标识由 `containerd://b0331821…` 变为 `containerd://53273ab2…`；③ 本次退出码为 `2`，教材的 `137` 对应宽限期耗尽后被 SIGKILL 的分支；④ 就绪失败时 `READY` 为 `0/1` 且 `RESTARTS` 为 `0`；⑤ 端点列表由两个地址减少为一个地址；⑥ 20 次请求全部进入就绪的 Pod；⑦ 没有启动探针时重启计数达到 6 且升级超时，加上之后重启计数保持 0；⑧ 启动探针成功之前 `/readyz` 完全不被调用，它的第一次出现与 `/healthz` 第一次返回 200 同为 `09:45:05` |
| 出现异常的排查顺序 | 先执行 `kubectl get po -o wide` 判断属于哪一类：`READY` 为 `0/1` 而 `RESTARTS` 为 0 表示就绪问题；`RESTARTS` 在增长表示存活问题；`STATUS` 为 `CrashLoopBackOff` 表示进程无法稳定运行。然后执行 `kubectl describe po` 查看 `Liveness`、`Readiness`、`Startup` 三段参数与事件，最后执行 `kubectl logs <Pod 名称> --previous` 查看上一个容器的日志 |
| 最容易答错的点 | ① 把容器重启当成 Pod 重建（错题本 K22）；② 认为退出码固定是 137；③ 认为就绪探针失败会重启容器；④ 认为探针由控制平面执行；⑤ 认为未就绪的 Pod 会从 `EndpointSlice` 中消失 |
| 自测问题 | ① 只凭 `READY` 与 `RESTARTS` 两列，如何区分「不健康但未重启」与「正在反复重启」；② 启动探针成功之后，它的计时器还会继续工作吗；③ 把 `periodSeconds` 由 10 改成 5，会改变哪些观测结果；④ 为什么本次注入的故障在容器重启之后消失；⑤ `EndpointSlice` 与 `Endpoints` 输出的地址数量为什么不同 |

---

## 八、待补充

| 项目 | 状态 |
|---|---|
| 启动探针实验的完整时间线 | 已补入 4.4 节。需要说明的是，本次的观察窗口是在滚动升级完成之后才启动的，因此没有采到 `READY` 由 `0/1` 变为 `1/1` 的那一行；若要采到这一行，应当在 `kubectl apply` 之后立即启动 `kubectl get po -w`，而不是等 `kubectl rollout status` 返回 |
| 退出码的两个补充实验（`signal.Notify` 版本与 `terminationGracePeriodSeconds: 0` 版本） | 未执行，列为本主题的后续验证项 |
