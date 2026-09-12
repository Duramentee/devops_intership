# 模块 05 · Deployment 与 StatefulSet（第 9~10 章）

> 目标：学会安全地升级应用、回滚，以及如何跑"有状态"应用。

## 一、核心概念（整体观）

### 1. 更新应用的两条路（p.398-412）

| 方式 | 做法 | 问题 |
|---|---|---|
| 先删旧再建新 | 直接换 Pod | 短暂不可用 |
| 先建新再删旧 | 新旧并存 | 需支持两版本并存，更费资源 |

`kubectl rolling-update` 之所以过时：升级由**客户端**执行，中途断网会卡在中间状态。Deployment 的升级由**运行在集群上的控制器**完成，断网也不怕。

### 2. Deployment（p.413-438）

- Deployment 是高阶资源：底层创建 ReplicaSet，Pod 实际由 RS 管理。
- 两种策略：`RollingUpdate`（默认，渐进替换全程可用）、`Recreate`（一次删旧建新，短暂不可用）。
- **回滚**：Deployment 保留旧 ReplicaSet 作历史版本，可 `rollout undo` 回到任意版本。
- 滚动升级速率：`maxSurge`（最多超多少）、`maxUnavailable`（最多缺多少），默认 25%。
- `minReadySeconds`：新 Pod 就绪后至少成功运行多久才算可用——是阻止错误版本铺开的**安全气囊**。
- **金丝雀发布**：`rollout pause` 暂停 → 观察少量流量 → `resume` 铺开。

### 3. StatefulSet：有状态应用（p.440-481）

- RS/Deployment 无法给每个副本独立存储（模板卷被所有副本共享同一个 PVC）。
- StatefulSet 专为"每个实例不可替代、需要稳定名字和状态"的应用（"宠物 vs 牛"类比）。
- 三个"稳定"：
  1. **稳定网络标识**：Pod 名 = StatefulSet 名 + 顺序索引（`kubia-0`、`kubia-1`），配合 **headless Service** 生成独立 DNS（如 `a-0.foo.default.svc.cluster.local`）。
  2. **稳定专属存储**：`volumeClaimTemplates` 为每个 Pod 自动建一个 PVC。
  3. **at-most-one 语义**：保证不会有两个同标识、绑同 PVC 的 Pod 同时运行。

## 二、关键细节

- 滚动升级流程：改模板（`kubectl set image`）→ 新建 RS 逐渐扩容，旧 RS 缩容到 0 → 旧 RS 保留作历史。
- 出错自动阻止：就绪探针失败 → 新 Pod 移出 Endpoint 不接流量；`maxUnavailable=0` 时不删旧 Pod，升级卡住。
- StatefulSet **顺序创建/缩容**：逐个启动（前一个 Running+Ready 才建下一个）；缩容先删最高索引，一次一个。
- StatefulSet 缩容**不删 PVC**（保护数据），再扩容新 Pod 挂回原 PVC。
- 节点失效：Pod 变 Unknown → 需手动 `--force --grace-period 0` 强制删除才会重建；别急着 force（可能两个同标识 Pod 同时写同一存储）。

## 三、命令速查

| 场景 | 命令 / 字段 | 说明 |
|---|---|---|
| 记录变更原因 | `kubectl create -f ... --record` | 否则 CHANGE-CAUSE 空 |
| 看升级进度 | `kubectl rollout status deployment <n>` | |
| 改镜像触发升级 | `kubectl set image deployment <n> <容器>=<新镜像>` | |
| 少量属性 | `kubectl patch deployment <n> -p ...` | 不触发 Pod 更新 |
| 回滚 | `kubectl rollout undo deployment <n>` | 回到上一版 |
| 回滚到指定版 | `kubectl rollout undo ... --to-revision=1` | |
| 看历史 | `kubectl rollout history deployment <n>` | |
| 历史版本数 | `revisionHistoryLimit` | 默认 2 |
| 速率 | `maxSurge` / `maxUnavailable` | 默认 25% |
| 最短可用时长 | `minReadySeconds` | 安全气囊 |
| 暂停/恢复 | `kubectl rollout pause / resume` | 金丝雀 |
| 超时 | `progressDeadlineSeconds` | 默认 10 分钟 |
| headless | `clusterIP: None` | StatefulSet 必备 |
| 卷模板 | `volumeClaimTemplates` | 每 Pod 专属 PVC |
| 访问单 Pod | `kubectl proxy` 后 `curl .../pods/kubia-0/proxy/` | |
| 查 SRV 记录 | `dig SRV <svc>.default.svc.cluster.local` | 伙伴发现 |
| 强制删 Pod | `kubectl delete pod kubia-0 --force --grace-period 0` | 慎用 |

## 四、易错点

1. 只改 ConfigMap/Secret **不会**触发 Deployment 升级（要新建并改模板引用）。
2. 别手动删旧 ReplicaSet——每个 RS 是一个历史版本，删了失去回滚能力。
3. `maxUnavailable` 是相对**期望副本数**的，不是绝对个数。
4. 只设就绪探针不设 `minReadySeconds` 有风险：一次探针成功就被视为可用。
5. 暂停状态下 `rollout undo` 不生效，要先 resume。
6. 镜像 tag 复用：非 latest 默认 `IfNotPresent`，同 tag 推新镜像可能不重新拉。
7. 别用 ReplicaSet 跑有状态应用（所有副本共享同一 PVC）。
8. StatefulSet 必须配 headless Service，否则没有稳定 DNS。

## 五、动手实践

1. 建 Deployment（v1 镜像），`kubectl set image` 升到 v2，`rollout status` 观察新旧 RS 数量变化。
2. 故意升级到一个会启动失败的镜像，观察滚动升级被卡住、旧 Pod 仍在线（服务不中断）。
3. `kubectl rollout undo` 回滚，`rollout history` 看版本。
4. 建 StatefulSet（headless Service + volumeClaimTemplates），观察 `kubia-0`、`kubia-1` 顺序创建、每个 Pod 独立 PVC。
5. `kubectl get pvc` 看每个 Pod 一个 PVC；缩容到 1，观察 PVC 还在；再扩回 2，新 Pod 挂回原 PVC。

## 六、自测题

1. Deployment 和 ReplicaSet 是什么关系？
2. `maxSurge` 和 `maxUnavailable` 各控制什么？默认值多少？
3. 为什么 `kubectl rolling-update` 过时了？Deployment 的升级谁在执行？
4. StatefulSet 保证的"三个稳定"是什么？各靠什么机制实现？
5. StatefulSet 缩容为什么**不删 PVC**？这样设计的好处和代价？
6. 节点失联时 StatefulSet 的 Pod 为什么不会自动重建？应该怎么处理？

> 回查：p.413-418、p.426-429、p.406-412、p.446-453、p.451、p.475-479。
