# Day 4 · 存活探针与就绪探针（让应用具备自动重启与自动摘除流量的能力）

> 目标：为同一个 Deployment 依次加上存活探针、就绪探针与启动探针，并在一次 Pod 的生命周期之内，
> 分别观察到「探针失败之后 kubelet 重启容器」与「探针失败之后 kubelet 把 Pod 从端点列表中移除」这两种不同的后果。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 4 节、`docs/k8s_in_action/02-Pod与副本机制.md` 的探针小节、
> 教材第 4 章 4.1 节（p.155-161，存活探针）与第 5 章 5.5 节（p.247-253，就绪探针）。
> 笔记落点：`notes/week2/day4.md`
> 起点资产：Deployment `webapp`（Day 3 结束时使用镜像 `webapp:v5`）、Service `webapp`（选择器为 `app=webapp`）、
> ConfigMap `webapp-config` 与 Secret `webapp-secret`。
> 今日新增资产：镜像 `webapp:v6`、三份 Deployment 清单、`outputs/` 目录中的实测记录。

---

## 一、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `go-webapp/main.go` | 应用源码。与 v5 相比新增了 `/healthz`、`/readyz`、`/state`、`/admin/fault` 四个端点，配置读取逻辑保持不变 | 已提供 |
| `go-webapp/go.mod` | 模块声明，与第 1 周的发布包完全相同 | 已提供 |
| `go-webapp/Dockerfile` | 多阶段构建、非 root 用户 uid 10001，与第 1 周的发布包完全相同 | 已提供 |
| `deploy.liveness.skeleton.yaml` | 只加存活探针的 Deployment 填空骨架，字段名齐全，取值留空 | 已提供 |
| `deploy.liveness.yaml` | 只加存活探针的 Deployment 清单文件 | 你自己编写，从骨架另存 |
| `deploy.readiness.skeleton.yaml` | 同时加存活探针与就绪探针的 Deployment 填空骨架 | 已提供 |
| `deploy.readiness.yaml` | 同时加存活探针与就绪探针的 Deployment 清单文件 | 你自己编写，从骨架另存 |
| `deploy.startup.skeleton.yaml` | 三种探针并存的 Deployment 填空骨架，用来演示启动探针 | 已提供 |
| `deploy.startup.yaml` | 三种探针并存的 Deployment 清单文件 | 你自己编写，从骨架另存 |
| `outputs/` | 命令的原始输出记录 | 你自己记录 |

---

## 二、动手之前必须先记录的基线

| 项目 | 命令 | 输出文件 | 为什么要先记录 |
|---|---|---|---|
| 节点容器与节点状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes -o wide` | `outputs/00-baseline-cluster.txt` | 节点容器处于 `Exited` 状态时全部容器会随之重启，`RESTARTS` 计数与 Pod 的 IP 地址都会变化。今天的实验全程依赖 `RESTARTS` 这一列的取值，因此这一组取值必须在实验之前固定下来 |
| 现有的 Deployment、Pod、Service | `kubectl get deploy,po,svc -o wide --show-labels` | `outputs/00-baseline-workload.txt` | 确认当前只有 Deployment `webapp` 的标签是 `app=webapp`。如果 Day 3 创建的 `webapp-vol` 也带着 `app=webapp` 标签，它同样会进入 Service `webapp` 的端点列表，端点数量的对照关系就不再唯一 |
| 现有的端点列表 | `kubectl get endpoints webapp -o wide` | `outputs/00-baseline-endpoints.txt` | 这是「就绪探针把 Pod 移除出端点列表」这条结论的对照基线。没有这份基线，端点地址减少时无法判断是探针造成的还是 Pod 被删除造成的 |
| 镜像标签与体积 | `docker images webapp --format '{{.Repository}}:{{.Tag}} {{.Size}}'` | `outputs/00-baseline-images.txt` | 记录构建之前的镜像标签，用于确认新构建出来的镜像确实使用了 `v6` 这个标签 |
| 容器内的进程列表 | `kubectl exec deploy/webapp -- ps aux` | `outputs/00-baseline-procs.txt` | 记录探针实验之前容器内的进程数量，重启之后这个列表会换成一个新的进程号，是「容器被重建而不是原地重启进程」的一个旁证 |

---

## 三、步骤与命令

> 下面每一步都写成「执行什么 → 输出到哪里 → 观察什么」的形式。属于补充而非书本原文的步骤在备注列中标出。
>
> 记录规则一共三条。第一条：本表中列出的每一个输出文件都放在本目录下的 `outputs/` 目录中，文件名前缀编号与步骤编号一致，因此只看文件名就能定位它属于哪一步。第二条：一次性完成的命令用重定向保存，例如执行 `kubectl get po -o wide > outputs/05-po-snapshot.txt 2>&1` 把标准输出与标准错误一起写入文件。第三条：需要持续观察的命令（例如 `kubectl get po -w`）无法用重定向完整保存，应当把观察到的关键片段粘贴进对应的文件，并在文件开头写一行说明这段输出对应的起止时刻。

| 步骤 | 命令 | 输出文件（位于 `outputs/`） | 观察什么 | 备注 |
|---|---|---|---|---|
| 1. 构建镜像并导入节点 | `docker build -t webapp:v6 .`（在 `go-webapp/` 目录中执行），然后执行 `kind load docker-image webapp:v6` | `01-build-and-load.txt` | 构建输出最后一行显示镜像的标识；导入命令输出包含 `Image: "webapp:v6" with ID ... loaded` | 补充：教材使用 Docker Hub 上的现成镜像，本次从本地构建 |
| 2. 创建只带存活探针的清单 | 从 `deploy.liveness.skeleton.yaml` 另存为 `deploy.liveness.yaml` 并填写全部尖括号，然后执行 `kubectl apply --dry-run=client -f deploy.liveness.yaml` | `02-dry-run-liveness.txt` | 校验命令不报错；输出中可以看到探针字段被补全之后的完整结构，以及客户端模板不会包含 `status` 段落 | |
| 3. 就地更新 Deployment | `kubectl apply -f deploy.liveness.yaml`，然后依次执行 `kubectl rollout status deploy/webapp` 与 `kubectl get rs -o wide` | `03-apply-liveness.txt`、`03-rollout-status.txt`、`03-rs-after-liveness.txt` | 升级状态输出显示滚动更新完成；ReplicaSet 列表中可以看到一个新的 ReplicaSet 被创建（这一步顺带预演 Day 5 的滚动升级） | |
| 4. 注入存活故障 | `kubectl exec <Pod 名称> -- wget -q -O- "http://localhost:8080/admin/fault?target=healthz&state=down"` | `04-fault-inject-healthz.txt` | 命令输出 `healthz_fault=true`，说明故障已经生效 | 补充：教材第 4 章把「返回 500」写在应用源码里，本次改为运行期注入 |
| 5. 观察容器被重启 | 在一个终端持续执行 `kubectl get po -w`，同时执行 `kubectl describe po <Pod 名称>` 与 `kubectl get po <Pod 名称> -o wide` | `05-po-before-restart.txt`、`05-identity-before.txt`、`05-restart-wait.txt`、`05-po-after-restart.txt`、`05-identity-after.txt`、`05-describe-liveness.txt`、`05-po-watch.txt` | `RESTARTS` 一列从 0 开始增长；`describe` 输出的事件中出现 `Liveness probe failed` 与 `Killing container` 两类事件；Pod 的名称与 IP 地址保持不变 | 教材 p.157 与 p.158 展示了同样的两组输出 |
| 6. 查看上一个容器的日志 | `kubectl logs <Pod 名称> --previous > outputs/06-logs-previous.txt 2>&1` | `06-logs-previous.txt` | 日志结尾出现连续的 `probe path=/healthz result=500` 行，说明重启的直接原因就是探针失败 | 教材 p.157「获取崩溃容器的应用日志」 |
| 7. 记录退出码与容器身份 | `kubectl get po <Pod 名称> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'`，然后执行 `kubectl get po <Pod 名称> -o jsonpath='{.metadata.uid}{" "}{.status.podIP}{" "}{.status.containerStatuses[0].containerID}{" "}{.status.containerStatuses[0].restartCount}{"\n"}'` | `07-exit-code.txt`、`07-pod-identity.txt` | 退出码输出为 `137`，等于 128 加 9，也就是 SIGKILL 的信号编号；后一条命令的输出中 uid 与 Pod 的 IP 地址与重启之前相同，而容器标识与重启计数已经变化 | 教材 p.158 与 p.160；后一条命令用于验证错题本 K22 的结论 |
| 8. 解除存活故障 | `kubectl exec <Pod 名称> -- wget -q -O- "http://localhost:8080/admin/fault?target=healthz&state=up"`，然后执行 `kubectl get po <Pod 名称>` | `08-fault-clear-healthz.txt`、`08-po-restarts-final.txt` | 故障状态输出 `healthz_fault=false`；`RESTARTS` 一列停止增长，容器不再被杀掉 | |
| 9. 创建同时带两种探针的清单并应用 | 从 `deploy.readiness.skeleton.yaml` 另存并填写，然后执行 `kubectl apply -f deploy.readiness.yaml`，再执行 `kubectl rollout status deploy/webapp` | `09-apply-readiness.txt`、`09-rollout-status.txt` | `kubectl get po` 的 `READY` 一列稳定为 `1/1`，`RESTARTS` 一列为 `0` | |
| 10. 只对一个 Pod 注入就绪故障 | 先执行 `kubectl get po -o wide` 记录两个 Pod 的名称与 IP 地址，再对其中一个执行 `kubectl exec <Pod 名称> -- wget -q -O- "http://localhost:8080/admin/fault?target=readyz&state=down"` | `10-po-before-fault.txt`、`10-fault-inject-readyz.txt`、`10-po-after-fault.txt` | `kubectl get po` 中只有被注入的那个 Pod 的 `READY` 一列变成 `0/1`，`RESTARTS` 一列仍然保持为 `0` | |
| 11. 确认 Pod 离开端点列表 | `kubectl get endpoints webapp -o wide`，必要时再执行 `kubectl get endpointslices -o wide`（集群版本 v1.37.0 中 v1 的 Endpoints 已经废弃） | `11-endpoints-after-fault.txt` | 端点列表中只剩另一个 Pod 的 IP 地址与端口，被注入故障的 Pod 的地址已经消失 | 教材 p.435 用同一机制解释了滚动升级为什么被阻止 |
| 12. 确认流量不再进入故障 Pod | 执行 `kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- sh -c 'for i in $(seq 1 20); do curl -s http://webapp:8080/state \| head -1; done'` | `12-service-routing.txt` | 20 次响应全部来自仍然就绪的那个 Pod，故障 Pod 的 `uptime_seconds` 不会出现在结果中 | |
| 13. 解除就绪故障 | 执行 `kubectl exec <Pod 名称> -- wget -q -O- "http://localhost:8080/admin/fault?target=readyz&state=up"`，然后执行 `kubectl get po -o wide` 与 `kubectl get endpoints webapp -o wide` | `13-fault-clear-readyz.txt`、`13-endpoints-after-recovery.txt` | `READY` 一列在一到两个探测周期之内恢复到 `1/1`，端点列表中重新出现该 Pod 的地址 | |
| 14. 演示启动探针 | 从 `deploy.startup.skeleton.yaml` 另存并填写，先注释掉整个 `startupProbe` 段落并应用，观察重启循环；再恢复 `startupProbe` 段落并应用，观察容器不再被杀掉 | `14-startup-without-probe.txt`、`14-startup-with-probe.txt` | 第一次输出中 `RESTARTS` 持续增长、`STATUS` 在 `Running` 与 `CrashLoopBackOff` 之间切换；第二次输出中 `RESTARTS` 保持为 `0`，`READY` 在 45 秒左右变成 `1/1` | 补充：书本写作时还没有启动探针这个字段 |
| 15. 记录容器时间线 | 执行 `kubectl exec <Pod 名称> -- wget -q -O- http://localhost:8080/state` 读取运行时长；定时采样改为读取应用日志，因为日志中每一行已经带有时间戳与运行时长，例如 `kubectl logs <Pod 名称> \| grep -E "probe path|正在监听"` | `15-state-timeline.txt`、`15-startup-probe-describe.txt` | `uptime_seconds` 连续增长说明容器没有重启；反复返回很小的数值说明容器正在经历重启循环；日志中 `/readyz` 第一次出现的时刻与启动探针第一次成功的时刻相同 | 补充：用日志替代定时采样可以避免执行 `sleep` 之类的等待命令，同时每一行都自带时间戳 |

---

## 四、观察点与判断标准

| 现象 | 判断结论 | 判断依据 |
|---|---|---|
| `READY` 为 `0/1` 而 `RESTARTS` 为 `0` | 就绪探针失败，容器没有被重启，只是被移出流量转发范围 | 就绪探针失败时 kubelet 只操作端点列表（教材 p.248） |
| `READY` 为 `1/1` 而 `RESTARTS` 持续增长 | 存活探针失败并且容器被反复重启；此时容器重启后立刻就能通过就绪检查，因此 `READY` 一列仍然是 `1/1` | 重启发生在同一个 Pod 内部，Pod 的名称与 IP 地址不改变（教材 p.158） |
| `RESTARTS` 为 `0`、`READY` 长期为 `0/1`，且 `STATUS` 一列显示 `Running` | 启动探针或就绪探针尚未成功，容器本身运行正常，只是被判定为不可用 | 启动探针成功之前存活探针与就绪探针都不会执行（补充） |
| `STATUS` 一列在 `Running` 与 `CrashLoopBackOff` 之间反复切换 | 容器反复退出并等待下一次重启，等待时间按照重启退避规则成倍增加 | `CrashLoopBackOff` 的含义是容器持续崩溃并且 kubelet 正在按退避间隔重试 |

---

## 五、易错点

| 编号 | 易错点 | 正确做法 |
|---|---|---|
| 1 | 把 `initialDelaySeconds` 设置得比应用的启动耗时更短 | 先测量应用启动耗时，再把这个字段设置成大于该耗时的取值。教材 p.158 指出，取值过小会让容器在能够正确响应请求之前就被重启 |
| 2 | 健康检查端点要求身份认证 | 探针请求不会携带任何凭证，要求认证的端点会让检查永远失败。健康检查端点必须允许匿名访问 |
| 3 | 两个探针指向同一个路径 | 两个端点指向同一个路径时，一次故障会同时影响重启与流量两件事，两类后果无法分开观察；本次实验因此把存活探针指向 `/healthz`、把就绪探针指向 `/readyz` |
| 4 | 在容器内部的命令里访问 Service 名称 | 容器内部访问自己的进程必须使用 `localhost` 与容器端口；Service 名称与 Service 端口只在集群内的其他 Pod 中可用，在同一个容器内部解析 Service 名称会失败 |
| 5 | 认为探针由控制平面执行 | 探针的检查动作由 Pod 所在节点上的 kubelet 执行，因此控制平面不可用时已经运行的 Pod 仍然会被继续探测 |
| 6 | 认为重启是「在原来的容器里重新启动进程」 | 教材 p.158 明确写道：容器被强行终止时会创建一个全新的容器，而不是重启原来的容器。因此容器可写层中的任何改动都会丢失 |
| 7 | 对 Deployment 使用 `kubectl edit` 修改探针后忘记记录 | 修改会立即触发一次滚动更新并产生新的 ReplicaSet，实验记录中应当写明这一次修改发生在哪个时间点 |
| 8 | 把 `wget` 的返回码当成注入结果 | `wget -q -O-` 会把响应正文打印到标准输出，注入是否成功要看输出中的 `healthz_fault` 与 `readyz_fault` 两行取值，而不是看命令的退出码 |

---

## 六、与计划文件的对应关系

| `plan/week2/任务明细.md` Day 4 中的任务 | 本目录中对应的步骤 | 差异说明 |
|---|---|---|
| ① 为应用增加 `/healthz` 与 `/readyz` 两个端点 | 已由 `go-webapp/main.go` 提供 | 应用还额外提供了 `/state` 与 `/admin/fault` 两个端点，前者提供时间参照，后者用于在运行期切换探针的返回值 |
| ② 重新构建镜像并导入节点，版本标记为 `webapp:v5` | 步骤 1，版本标记改为 `webapp:v6` | `webapp:v5` 在 Day 3 已经被占用，因此今天使用 `v6` |
| ③ 编写带 `livenessProbe` 的 Deployment，观察 `RESTARTS` 增长 | 步骤 2 至步骤 8 | 故障通过 `/admin/fault` 端点注入，不需要为每一次行为改变重新构建镜像 |
| ④ 把 `/healthz` 的返回值改回 200 并重新构建镜像 | 步骤 8 | 改为调用 `/admin/fault?state=up` 解除故障，因此镜像只需要构建一次 |
| ⑤ 编写同时带两种探针的 Deployment，观察 `READY` 变为 `0/1` 而 `RESTARTS` 保持为 `0` | 步骤 9 至步骤 13 | 故障注入只作用于被调用的那一个 Pod，因此端点列表上可以直接看到「一个地址被移除、另一个地址保留」 |
| ⑥ 把 `initialDelaySeconds` 调整为过小的取值并记录退出码 | 步骤 14 的对照组，配合步骤 7 的退出码记录 | 使用启动探针与慢启动窗口构造同一个场景，观察到的退出码仍然是 137 |
| ⑦ 执行 `kubectl logs --previous` 查看上一个被终止的容器的日志 | 步骤 6 | 无差异 |
