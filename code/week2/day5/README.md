# Day 5 · 滚动升级与回滚（在不中断服务的前提下发布新版本）

> 目标：把一个正在运行的 Deployment 从 `webapp:v6` 升级到 `webapp:v7`，在升级过程中从一个固定的 Service 地址连续发起请求，
> 用「请求全部得到应答、版本标识逐步切换」这一组数据证明服务没有中断；随后执行回滚，观察控制器如何把旧版本的 ReplicaSet 重新扩容回来；
> 最后制造一次失败的升级，观察控制器如何保留可用的旧版本并停止推进。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 5 节、`docs/k8s_in_action/05-Deployment与StatefulSet.md`、
> 教材 9.3.2 节（p.417-422，升级 Deployment）、9.3.3 节（p.422-426，回滚 Deployment）、
> 9.3.4 节（p.426-429，控制滚动升级速率）、9.3.5 节（p.429-431，暂停滚动升级）、9.3.6 节（p.431-436，阻止出错版本的滚动升级）。
> 笔记落点：`notes/week2/day5.md`
> 起点资产：Deployment `webapp`（副本数量为 2、镜像 `webapp:v6`、带存活探针与就绪探针）、Service `webapp`（选择器为 `app=webapp`）、
> ConfigMap `webapp-config`、Secret `webapp-secret`、镜像 `webapp:v4` 至 `webapp:v6`。
> 今日新增资产：镜像 `webapp:v7`、两份 Deployment 清单、`outputs/` 目录中的实测记录。

---

## 一、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `go-webapp/main.go` | 应用源码。与 v6 相比新增了一个 `/version` 端点，并在 `/state` 输出的末尾增加了一行版本标识；Day 3 的配置来源报告与 Day 4 的三个探针端点保持原样 | 已提供 |
| `go-webapp/go.mod` | 模块声明，与 Day 4 完全相同 | 已提供 |
| `go-webapp/Dockerfile` | 多阶段构建、非 root 用户 uid 10001，与 Day 4 完全相同 | 已提供 |
| `deploy.rollout.skeleton.yaml` | 滚动升级清单的填空骨架，`strategy`、`minReadySeconds`、`revisionHistoryLimit`、`progressDeadlineSeconds` 四个字段以及镜像标签留空 | 已提供 |
| `deploy.rollout.yaml` | 滚动升级与回滚实验实际使用的 Deployment 清单 | 你自己编写，从骨架另存 |
| `deploy.recreate.skeleton.yaml` | `Recreate` 策略对照实验的填空骨架 | 已提供 |
| `deploy.recreate.yaml` | `Recreate` 策略对照实验实际使用的 Deployment 清单 | 你自己编写，从骨架另存 |
| `outputs/` | 命令的原始输出记录 | 你自己记录 |

---

## 二、动手之前必须先记录的基线

| 项目 | 命令 | 输出文件 | 为什么要先记录 |
|---|---|---|---|
| 节点容器与节点状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes -o wide` | `outputs/00-baseline-cluster.txt` | 节点容器被重新启动时，节点上的全部容器都会随之重建，Pod 的名称与地址都会变化。今天的实验以「升级前后 ReplicaSet 的副本数量」和「连续请求是否全部得到应答」为依据，节点状态必须在这一刻固定下来 |
| 现有的 Deployment、ReplicaSet、Pod | `kubectl get deploy,rs,po -o wide --show-labels` | `outputs/00-baseline-workload.txt` | 升级之前必须知道已经存在几个 ReplicaSet、它们的名称分别是什么。没有这份基线，升级之后看到一个陌生的 ReplicaSet 名称就无法判断它是本次升级产生的还是之前遗留的 |
| Deployment 的 `strategy` 字段默认取值 | `kubectl get deploy webapp -o yaml`，或者执行 `kubectl get deploy webapp -o jsonpath='{.spec.strategy}{"\n"}'` | `outputs/00-baseline-strategy.txt` | 计划文件要求记录两个速率参数的默认取值。这份取值是后面「显式写入与默认取值是否产生差异」这一判断的对照基线 |
| 当前的版本历史 | `kubectl rollout history deploy/webapp` 与 `kubectl get deploy webapp -o jsonpath='{.metadata.generation}{"\n"}'` | `outputs/00-baseline-history.txt` | 回滚的可选目标由 ReplicaSet 决定，而 `generation` 的取值记录的是 Pod 模板被修改过多少次。两份取值放在一起，才能说明「回滚目标」与「模板修改次数」之间的关系 |
| 镜像标签 | `docker images webapp --format '{{.Repository}}:{{.Tag}} {{.Size}}'` | `outputs/00-baseline-images.txt` | 记录构建之前的标签集合，用于确认新构建出来的镜像确实使用了 `v7` 这个标签，并且节点内部的镜像库中也存在它 |
| Service 与端点列表 | `kubectl get svc webapp -o wide` 与 `kubectl get endpoints webapp -o wide` | `outputs/00-baseline-endpoints.txt` | 今天的连续访问实验全程访问 Service 的地址，因此这个地址在整个实验期间必须保持不变。端点列表的取值用于说明「地址不变、后端的 Pod 在替换」这件事 |

---

## 三、步骤与命令

> 下面每一步都写成「执行什么 → 输出到哪里 → 观察什么」的形式。属于补充而非书本原文的步骤在备注列中标出。
>
> 记录规则一共三条。第一条：本表中列出的每一个输出文件都放在本目录下的 `outputs/` 目录中，文件名前缀编号与步骤编号一致。
> 第二条：一次性完成的命令用重定向保存，例如执行 `kubectl get rs -o wide > outputs/06-rs-after-upgrade.txt 2>&1`，把标准输出与标准错误一起写入文件。
> 第三条：需要持续观察的命令无法用重定向完整保存，应当把观察到的关键片段粘贴进对应的文件，并在文件开头写一行说明这段输出对应的起止时刻。

| 步骤 | 命令 | 输出文件（位于 `outputs/`） | 观察什么 | 备注 |
|---|---|---|---|---|
| 1. 构建 v7 并导入节点 | 在 `go-webapp/` 目录中执行 `docker build -t webapp:v7 .`，然后执行 `kind load docker-image webapp:v7` | `01-build-and-load.txt` | 构建输出的最后一行给出镜像标识；导入命令输出中包含 `Image: "webapp:v7" with ID ... loaded` | 补充：教材使用 Docker Hub 上的现成镜像，本次从本地构建。与 Day 4 的差别只有 `/version` 一个端点，因此两次实验的现象不会互相影响 |
| 2. 记录基线 | 按第二节的表格逐项执行 | `00-*.txt` | 六份基线文件全部生成，其中 `00-baseline-strategy.txt` 中可以看到 `maxSurge` 与 `maxUnavailable` 的默认取值 | 补充：第 1 周的教训是知识空白类错误最多，因此观察类实验一律先记录基线 |
| 3. 填写骨架并做客户端校验 | 从 `deploy.rollout.skeleton.yaml` 另存为 `deploy.rollout.yaml` 并填写全部尖括号，其中 `image` 先保持 `webapp:v6`，然后执行 `kubectl apply --dry-run=client -f deploy.rollout.yaml` | `03-dry-run.txt` | 校验命令不报错；`strategy` 段落的结构符合预期；客户端校验不会补全默认值，因此输出中的取值就是你在文件里写的取值 | |
| 4. 第一次 apply：只修改策略字段 | `kubectl apply -f deploy.rollout.yaml`，然后执行 `kubectl get rs -o wide`、`kubectl get deploy webapp -o yaml`、`kubectl rollout history deploy/webapp` | `04-apply-strategy-only.txt`、`04-rs-after-strategy.txt`、`04-history-after-strategy.txt` | ReplicaSet 的数量与名称是否发生变化；`metadata.generation` 是否增加；版本历史中是否新增一条记录 | 补充：这一步把「策略字段」与「Pod 模板」拆成两次变更，因此它可以回答「修改哪些字段会触发滚动升级」这个问题。教材 p.413 至 p.418 只描述了修改 Pod 模板这一条路径 |
| 5. 启动连续访问 | 在另一个终端窗口中执行 `kubectl run curl-loop --image=curlimages/curl:8.10.1 --restart=Never -it --rm -- sh -c 'while :; do printf "%s " "$(date +%H:%M:%S)"; curl -s -o /tmp/b -w "http=%{http_code} " --max-time 2 http://webapp:8080/version; echo "body=$(cat /tmp/b 2>/dev/null)"; sleep 0.2; done'` | `05-continuous-access.txt` | 每一行输出包含时刻、HTTP 状态码与响应正文。升级开始之前，这些行的状态码应当全部是 404，因为 v6 没有 `/version` 这个端点 | 补充：`curlimages/curl` 这个镜像在 Day 4 已经使用过。`http=000` 表示连接未能建立，它是「服务中断」的唯一判定依据。循环在没有按 Ctrl-C 之前不会停止，因此应当在第 8 步之后再终止它 |
| 6. 第二次 apply：把镜像改为 v7 | 把 `deploy.rollout.yaml` 中的 `image` 改为 `webapp:v7`，然后执行 `kubectl apply -f deploy.rollout.yaml`，紧接着执行 `kubectl rollout status deploy/webapp` | `06-apply-v7.txt`、`06-rollout-status.txt` | 升级状态依次出现「等待新的副本被创建」「等待旧副本被终止」「成功完成」三类输出 | 教材 p.417 至 p.419 给出了同样的观察顺序 |
| 7. 采集升级过程中的中间状态 | 在这次升级开始之前，先在另一个终端窗口中执行 `kubectl get rs -w -o wide`，升级结束之后再终止它；另外在升级过程中执行一次 `kubectl get po -o wide` 与 `kubectl get deploy webapp -o yaml` | `07-rs-watch.txt`、`07-po-midflight.txt`、`07-deploy-midflight.txt` | 新 ReplicaSet 的 `DESIRED` 一列由 0 逐步增加到 2；旧 ReplicaSet 的 `DESIRED` 一列由 2 逐步减少到 0；同一时刻两个 ReplicaSet 的副本数量之和最多等于 `replicas` 加上 `maxSurge`；`kubectl get deploy webapp -o yaml` 的 `status` 段落中 `updatedReplicas`、`replicas`、`availableReplicas` 三个字段在过程中并不相等 | 补充：教材 p.426 至 p.429 用插图描述这个过程。本次用 `kubectl get rs -w` 的连续输出替代定时采样，因此不需要执行等待命令就能采到中间状态 |
| 8. 终止连续访问并统计结果 | 在步骤 5 的终端窗口中按 Ctrl-C 终止循环，然后统计输出：先执行 `grep -c 'http=000' 05-continuous-access.txt`，再执行 `grep -c 'version=v6' 05-continuous-access.txt` 与 `grep -c 'version=v7' 05-continuous-access.txt` | 追加写入 `05-continuous-access.txt` 的末尾 | `http=000` 的行数为 0，说明整个升级过程中每一个请求都得到了应答；`version=v7` 的行数从 0 开始增长，说明新版本的 Pod 正在逐步接管流量 | 补充：这三条统计就是「服务没有中断」这一结论的全部证据。如果 `http=000` 的行数不为 0，那么必须结合步骤 6 的输出重新判断是升级引起的还是客户端本身的问题 |
| 9. 查看版本历史并执行回滚 | 依次执行 `kubectl rollout history deploy/webapp`、`kubectl rollout undo deploy/webapp`、`kubectl rollout status deploy/webapp` | `09-history-before-undo.txt`、`09-undo.txt`、`09-rollout-status-after-undo.txt` | 回滚命令的输出中包含 `deployment.apps/webapp rolled back`；执行完成之后 `kubectl get rs -o wide` 中原来已经缩容到 0 的那个 ReplicaSet 的 `DESIRED` 一列重新变成 2 | 教材 p.422 至 p.425 给出了 `kubectl rollout undo` 的用法与回滚结果 |
| 10. 确认回滚之后的镜像与版本历史 | 执行 `kubectl describe deploy webapp` 并查看 `Image` 一行，再执行 `kubectl get po -o wide` 与 `kubectl exec deploy/webapp -- wget -q -O- http://localhost:8080/version` | `10-describe-after-undo.txt`、`10-version-after-undo.txt` | `Image` 一行回到 `webapp:v6`；`/version` 端点返回的状态码是 404，因为 v6 没有这个端点，这一点反过来证明了回滚已经生效；Pod 的名称与地址与升级之前不同，因为回滚过程中新建了 Pod | 补充：回滚的目标是「恢复 Pod 模板」，而不是「把原来的 Pod 找回来」。教材 p.423 说明每个 ReplicaSet 保存了一个完整的版本，因此回滚的实现方式是让旧 ReplicaSet 重新扩容 |
| 11. 观察 revision 编号的变化 | 执行 `kubectl rollout history deploy/webapp` | `11-history-after-undo.txt` | 历史列表中新增了一条记录，而不是把原来那条记录的编号退回 | 补充：`kubectl rollout undo` 本身也是一次 Pod 模板修改，因此它会占用一个新的 revision 编号 |
| 12. 参数组合实验 | 依次修改 `maxSurge` 与 `maxUnavailable` 的取值并执行 `kubectl apply`，每次升级在另一个终端窗口中执行 `kubectl get po -w` | `12-surge-unavailable-combos.txt` | 每一种组合下 Pod 总数的最大值与最小值。三种推荐组合分别是 `maxSurge=1 maxUnavailable=0`、`maxSurge=0 maxUnavailable=1` 与 `maxSurge=100% maxUnavailable=0` | 补充：教材 p.426 至 p.429 用 3 个副本的例子解释这两个参数。本次的副本数量是 2，因此百分数取值的取整方向可以直接通过 Pod 总数观察到 |
| 13. 制造一次失败的升级 | 执行 `kubectl set image deploy/webapp webapp=webapp:does-not-exist`，然后执行 `kubectl rollout status deploy/webapp --timeout=30s`，再执行 `kubectl get po -o wide` 与 `kubectl describe po <新 Pod 的名称>` | `13-failed-upgrade-status.txt`、`13-failed-upgrade-po.txt`、`13-failed-upgrade-describe.txt` | `kubectl rollout status` 在超时之后以非零状态返回并给出 `error: timed out waiting for the condition`；新 Pod 的 `STATUS` 一列为 `ErrImagePull` 或 `ImagePullBackOff`；旧版本的 Pod 仍然处于 `1/1 Running`，因此服务本身仍然可用 | 教材 p.431 至 p.436 描述了「出错版本的滚动升级被阻止」这一行为 |
| 14. 从失败的升级中恢复 | 执行 `kubectl rollout undo deploy/webapp`，然后执行 `kubectl rollout status deploy/webapp`、`kubectl get po -o wide` 与 `kubectl describe deploy webapp` | `14-recover.txt` | 升级重新完成；全部 Pod 回到 `1/1 Running`；`Image` 一行回到可用的标签 | 教材 p.424 与 p.436 |
| 15. 对照实验：`Recreate` 策略 | 从 `deploy.recreate.skeleton.yaml` 另存并填写，执行 `kubectl apply -f deploy.recreate.yaml`，同时在另一个终端窗口中保持步骤 5 的连续访问 | `15-recreate-access.txt`、`15-recreate-po.txt` | 连续访问的输出中出现 `http=000` 的行；`kubectl get po` 的输出中曾经出现「可用的 Pod 数量为 0」的时间窗 | 补充：`Recreate` 策略会先删除全部旧 Pod 再创建新 Pod，因此它必然产生一段不可用的时间。这一步与步骤 8 构成一组对照，用来证明「滚动升级没有中断」这个结论确实来自策略本身 |
| 16. 收尾：把 Deployment 恢复成滚动升级 | 把 `deploy.rollout.yaml` 中的 `image` 写回 `webapp:v7`、策略写回 `RollingUpdate`，执行 `kubectl apply -f deploy.rollout.yaml`，最后执行 `kubectl get deploy,rs,po -o wide` | `16-final-state.txt` | Deployment 处于可用状态，Pod 数量等于期望副本数量 | |

### 选做：暂停与恢复

| 步骤 | 命令 | 观察什么 | 备注 |
|---|---|---|---|
| 17. 暂停滚动升级 | 执行 `kubectl rollout pause deploy/webapp`，然后把 `image` 改为 `webapp:v6` 并执行 `kubectl apply -f deploy.rollout.yaml` | 新 ReplicaSet 被创建出来，但它的副本数量一直保持为 0，因为控制器在暂停状态下不推进升级 | 教材 p.429 至 p.431 把暂停作为金丝雀发布的手段：先让少量流量进入新版本，确认无误之后再恢复 |
| 18. 恢复滚动升级 | 执行 `kubectl rollout resume deploy/webapp`，然后执行 `kubectl rollout status deploy/webapp` | 升级在恢复之后继续推进直到完成 | 暂停状态下 `kubectl rollout undo` 不生效，必须先执行 `resume` |

---

## 四、观察点与判断标准

| 现象 | 判断结论 | 判断依据 |
|---|---|---|
| 只修改 `strategy` 字段之后 ReplicaSet 的数量与名称都没有变化 | Pod 模板没有发生变化，因此控制器不创建新的 ReplicaSet，也不替换任何 Pod | 教材 p.414 与 p.418：ReplicaSet 由 Pod 模板的哈希值命名，模板不变则名称不变 |
| 修改 `image` 之后出现一个新的 ReplicaSet | Pod 模板发生了变化，控制器创建新的 ReplicaSet 并把升级工作交给它 | 教材 p.417 至 p.421 |
| 升级过程中两个 ReplicaSet 的副本数量之和最多等于 `replicas` 加上 `maxSurge` | `maxSurge` 控制的是超出期望副本数量的上限 | 教材 p.427 |
| 升级过程中处于可用状态的 Pod 数量最少等于 `replicas` 减去 `maxUnavailable` | `maxUnavailable` 是相对于期望副本数量的比例，不是绝对个数 | 教材 p.429 明确写出这一条限定条件 |
| 连续访问的输出中 `http=000` 的行数为 0 | 在整个升级期间每一个请求都得到了应答，服务没有中断 | 补充：`curl` 的退出方式与状态码共同给出结论，状态码 000 表示连接未能建立 |
| 失败升级期间新 Pod 处于 `ImagePullBackOff` 而旧 Pod 保持 `1/1 Running` | 控制器在无法推进升级时保留全部旧副本，因此可用性不受影响 | 教材 p.431 至 p.436 |
| 回滚之后 Pod 的名称与地址都发生变化 | 回滚的实现方式是让旧 ReplicaSet 重新创建 Pod，而不是恢复原来的 Pod 对象 | 补充：Pod 是一次性对象，删除之后无法恢复 |
| 回滚之后 `kubectl rollout history` 中新增一条记录 | 回滚本身也是一次 Pod 模板修改 | 补充 |
| `Recreate` 策略下连续访问出现 `http=000` | 该策略先删除全部旧 Pod 再创建新 Pod，因此必然产生不可用的时间窗 | 教材 p.414 |

---

## 五、易错点

| 编号 | 易错点 | 正确做法 |
|---|---|---|
| 1 | 把 `maxUnavailable` 当作绝对个数 | 该字段的取值是相对于期望副本数量的比例，只有写成整数时才表示绝对个数。教材 p.429 专门用一段说明这一条：期望副本数量为 3、`maxUnavailable` 为 1 时，更新过程中必须保持至少 2 个 Pod 可用，而不可用的 Pod 数量可以超过 1 |
| 2 | 认为修改 Deployment 的任意字段都会触发滚动升级 | 只有 Pod 模板发生变化时控制器才创建新的 ReplicaSet。修改 `replicas`、`strategy`、`minReadySeconds` 这类字段会就地更新，不会替换现有 Pod。步骤 4 与步骤 6 把这两种情况分开观察，就是为了得到这个结论 |
| 3 | 认为回滚会把 revision 编号退回或者删除新版本的 ReplicaSet | 回滚是一次新的模板修改，它占用一个新的 revision 编号，新版本的 ReplicaSet 会被缩容到 0 但保留下来，因此还可以再回滚回去 |
| 4 | 把 `revisionHistoryLimit` 留在默认取值 2 就去执行多次升级 | 默认取值只保留当前版本与上一个版本，更早的 ReplicaSet 会被清理，回滚目标随之减少。今天要经历升级、回滚与失败升级三步，因此必须把这个字段显式写成不小于 3 的取值 |
| 5 | 认为回滚等于把原来的 Pod 找回来 | 回滚的做法是恢复 Pod 模板并让旧 ReplicaSet 重新扩容，因此新产生的 Pod 拥有新的名称与新的地址 |
| 6 | 认为 `progressDeadlineSeconds` 到期之后控制器会自动回滚 | 该字段到期只会把 `Progressing` 条件写成 `False` 并停止推进升级，回滚必须由人显式执行 |
| 7 | 在失败的升级上直接执行 `kubectl rollout status` 并等待它返回 | 该命令的默认超时时间是 600 秒，因此必须显式指定 `--timeout=30s`，否则会长时间阻塞 |
| 8 | 使用 `--record` 参数记录变更原因 | 该参数已经被废弃，在新版本集群上不再产生 `CHANGE-CAUSE` 列的内容。正确做法是在执行 apply 之前执行 `kubectl annotate deploy webapp kubernetes.io/change-cause="升级到 v7"` |
| 9 | 把 `Recreate` 策略下的 `http=000` 当成实验环境问题 | 这一类连接失败正是该策略的行为特征：控制器必须先删除全部旧 Pod 才能创建新 Pod，因此出现不可用的时间窗是预期结果 |
| 10 | 在暂停状态下执行回滚 | 暂停状态下控制器不推进升级，回滚不会生效，必须先执行 `kubectl rollout resume` |

---

## 六、与计划文件的对应关系

| `plan/week2/任务明细.md` Day 5 中的任务 | 本目录中对应的步骤 | 差异说明 |
|---|---|---|
| ① 执行 `kubectl get deploy webapp -o yaml`，记录 `strategy` 两个参数的默认取值 | 步骤 2 的 `00-baseline-strategy.txt` | 无差异 |
| ② 把镜像标签由 `webapp:v4` 改为 `webapp:v5` 并执行 `kubectl apply` | 步骤 3 至步骤 8，标签由 `webapp:v6` 改为 `webapp:v7` | 计划文件写作时 Day 4 尚未执行，当时的起点标签是 `v4`。当前集群中的起点标签是 `v6`，因此本次使用 `v7` |
| ③ 执行 `kubectl rollout history` 与 `kubectl rollout undo`，并用 `kubectl describe deploy` 确认镜像标签 | 步骤 9 至步骤 11 | 增加了「回滚之后 revision 编号如何变化」这一项观察 |
| ④ 调整 `maxSurge` 与 `maxUnavailable` 的组合并记录 Pod 总数 | 步骤 12 | 无差异 |
| ⑤ 制造一次失败的升级，观察 `kubectl rollout status` 的处理方式并执行回滚 | 步骤 13 至步骤 14 | 补充了 `--timeout=30s`，原因是该命令的默认超时时间是 600 秒 |
| 自检：解释一次升级过程中 `kubectl get rs` 的副本数量为什么会先增加后减少 | 步骤 7 与步骤 12 的输出，以及笔记中的「十分钟速记卡」 | 无差异 |
