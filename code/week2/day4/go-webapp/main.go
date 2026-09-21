// webapp v6：在 v5 的基础上增加三个 HTTP 端点，用来配合第 2 周 Day 4 的探针实验。
//
// 与 v5 相比，本次修改只集中在端点部分：Day 3 报告配置来源的那段逻辑完全保留，
// 因此 Day 3 观察到的配置注入行为在 v6 中保持不变，两天实验之间不会互相干扰。
//
// 新增的三个端点各自承担的职责如下：
//  1. /healthz：供存活探针（livenessProbe）与启动探针（startupProbe）调用。
//     这个端点在正常情况下返回状态码 200，在故障被注入之后返回状态码 500，
//     在「模拟慢启动」的时间窗之内返回状态码 503。
//  2. /readyz：供就绪探针（readinessProbe）调用。
//     这个端点在正常情况下返回状态码 200，在故障被注入之后返回状态码 500，
//     在「模拟慢启动」的时间窗之内同样返回状态码 503。
//  3. /admin/fault：实验用的故障注入开关。
//     它接受 target 与 state 两个查询参数，把 /healthz 或者 /readyz 的返回值在 200 与 500 之间来回切换。
//
// 之所以要提供 /admin/fault 这个开关，而不是像教材第 4 章那样把「返回错误状态码」写死在源码里，
// 原因是：写死在源码里意味着每改变一次行为都要重新构建镜像、重新导入节点、再重建 Pod，
// 而探针要观察的对象是「同一个容器的状态变化引发的 kubelet 动作」，
// 重建 Pod 会把 RESTARTS 计数、Pod 名称与 Pod 的 IP 地址全部重置，
// 这样一来「失败之前」与「失败之后」两组现象就不在同一个观测对象上，对照关系被破坏。
// 有了这个开关之后，注入故障与解除故障都发生在正在运行的那个容器内部，
// 因此可以在一个 Pod 的生命周期之内完整看到「探针失败 → kubelet 采取动作 → 探针恢复 → kubelet 动作停止」这条链路。
//
// 还需要补充说明的一点是：这个端点纯粹是实验用的辅助手段，
// 真实的应用不应该对外暴露任何可以远程改变运行状态的开关，否则任何能够访问该端口的人都可以让应用下线。
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 下面三个位置分别对应第 2 周 Day 3 实验中的三个配置来源，本次实验原样保留：
//  1. GREETING 既以环境变量方式注入，又以文件方式挂载，因此它可以同时出现在两个位置上；
//  2. config.conf 只以文件方式挂载，用于确认「ConfigMap 中的一个键就是一个文件」这一行为；
//  3. DB_PASSWORD 只以环境变量方式注入，用于确认 Secret 的注入结果。
const (
	greetingEnvKey   = "GREETING"
	greetingFilePath = "/etc/webapp/GREETING"
	configFilePath   = "/etc/webapp-file/config.conf"
)

// listenAddress 单独提取成常量，是为了让日志里打印的监听地址与真正用于监听的地址来自同一个字面量，
// 避免出现「日志写 8080、代码监听 8082」这种日志与行为不一致的情况。
const listenAddress = ":8080"

// processStartedAt 记录进程启动的时刻。
// 「启动很慢」这个现象必须相对于进程启动时刻来度量：探针的计时起点是容器被创建的时刻，
// 而容器被创建完成之后进程几乎立刻启动，两者之间的时间差可以忽略，
// 因此把计时起点记为进程启动时刻不会改变结论。
var processStartedAt = time.Now()

// faultState 保存两个健康检查端点当前是否处于人为注入的故障状态。
// 探针发出的请求由 kubelet 发起，故障注入请求由实验者发起，两类请求分别来自不同的协程，
// 因此这份共享状态必须由互斥锁保护，否则并发读写会构成数据竞争。
type faultState struct {
	mu      sync.Mutex
	healthz bool
	readyz  bool
}

// fault 保存进程范围内的故障状态。它由 /admin/fault 端点写入，由两个探针端点读取。
var fault faultState

// set 修改故障状态。
// 参数 target 允许取 healthz、readyz 两个值之一，或者取 both 表示两个端点一起修改；
// 参数 down 为 true 表示把该端点改成失败状态，为 false 表示恢复正常状态。
func (f *faultState) set(target string, down bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if target == "healthz" || target == "both" {
		f.healthz = down
	}
	if target == "readyz" || target == "both" {
		f.readyz = down
	}
}

// snapshot 一次性读取两个端点的故障状态。
// 之所以要一次性读取而不是分两次读取，是为了保证日志中记录的这一行状态描述对应同一个时刻，
// 否则在两次读取之间发生故障注入，日志里就会出现「healthz 正常、readyz 异常」这种无法解释的组合。
func (f *faultState) snapshot() (bool, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.healthz, f.readyz
}

// uptime 返回进程从启动到当前时刻已经经过的时间。
func uptime() time.Duration {
	return time.Since(processStartedAt)
}

// slowStartSeconds 返回「模拟慢启动」的时间窗长度，单位是秒。
// 当环境变量 SLOW_START_SECONDS 没有被设置、取值不是整数或者取值小于零时，本函数返回 0，
// 返回 0 表示不模拟慢启动，也就是两个探针端点直接按照真实的故障状态返回结果。
func slowStartSeconds() int {
	raw := os.Getenv("SLOW_START_SECONDS")
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		log.Printf("环境变量 SLOW_START_SECONDS 的取值 %q 不是整数，本次按 0 处理", raw)
		return 0
	}
	if n < 0 {
		log.Printf("环境变量 SLOW_START_SECONDS 的取值 %d 小于零，本次按 0 处理", n)
		return 0
	}
	return n
}

// withinSlowStart 判断当前时刻是否仍处在模拟的慢启动时间窗之内。
// 这个函数返回 true 表示应用还没有「启动完成」，此时两个探针端点都会返回状态码 503。
func withinSlowStart() bool {
	n := slowStartSeconds()
	if n <= 0 {
		return false
	}
	return uptime() < time.Duration(n)*time.Second
}

// envOrMissing 与 os.Getenv 的区别在于是否区分「变量不存在」与「变量取值为空字符串」这两件事。
// 观察注入是否成功时必须区分这两种情况，否则一个取值为空的变量会被误判成注入成功。
func envOrMissing(key string) string {
	v, ok := os.LookupEnv(key)
	if !ok {
		return "<未注入>"
	}
	return fmt.Sprintf("%q", v)
}

// readIfExists 读取挂载进容器内的文件。
// 当文件不存在时，它返回带原因的说明字符串，这样在没有挂载卷的那一份 Deployment 中，
// 输出本身就直接说明了「文件方式没有生效」，不需要再执行别的命令去确认。
func readIfExists(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("<读取失败：%v>", err)
	}
	return fmt.Sprintf("%q", strings.TrimRight(string(data), "\n"))
}

// secretState 只报告敏感配置是否注入以及它的长度，不输出取值本身。
// 这样即便日志被收集到集中式日志系统，凭证也不会随之泄漏到日志里。
func secretState(key string) string {
	v, ok := os.LookupEnv(key)
	if !ok {
		return "<未注入>"
	}
	return fmt.Sprintf("已注入，长度=%d", len(v))
}

// report 生成同一条观测报告。
// 进程启动日志与根路径的响应共用它，因此「容器创建时刻的取值」与「之后每一次请求的取值」
// 可以直接逐行对照，不需要分别记住两套输出格式。
func report() string {
	var b strings.Builder
	fmt.Fprintf(&b, "env  GREETING    = %s\n", envOrMissing(greetingEnvKey))
	fmt.Fprintf(&b, "file GREETING    = %s\n", readIfExists(greetingFilePath))
	fmt.Fprintf(&b, "env  APP_ENV     = %s\n", envOrMissing("APP_ENV"))
	fmt.Fprintf(&b, "env  FOO-BAR     = %s\n", envOrMissing("FOO-BAR"))
	fmt.Fprintf(&b, "env  DB_PASSWORD = %s\n", secretState("DB_PASSWORD"))
	return b.String()
}

// rootHandler 返回配置来源报告，它与 Day 3 的行为完全一致。
func rootHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, report())
}

// configHandler 在每一次请求时都重新读取文件，因此它的返回值会跟随 ConfigMap 一起变化。
func configHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, readIfExists(configFilePath), "\n")
}

// stateHandler 输出进程已经运行了多少秒，以及两个探针端点当前的状态。
// 这个端点的作用是给实验者提供一条「不依赖探针结果」的时间参照：
// 当容器被反复重启时，uptime 会在每一次重启之后重新从小数值开始增长，
// 于是「uptime 一直很小」这件事本身就说明容器正在经历重启循环。
func stateHandler(w http.ResponseWriter, r *http.Request) {
	healthzDown, readyzDown := fault.snapshot()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "uptime_seconds=%d\n", int(uptime().Seconds()))
	fmt.Fprintf(w, "slow_start_seconds=%d\n", slowStartSeconds())
	fmt.Fprintf(w, "in_slow_start=%t\n", withinSlowStart())
	fmt.Fprintf(w, "healthz_fault=%t\n", healthzDown)
	fmt.Fprintf(w, "readyz_fault=%t\n", readyzDown)
}

// probeHandler 生成一个探针端点。
// 参数 name 用于日志与响应正文，参数 isFailed 用于判断该端点是否处于人为注入的故障状态。
// 两个探针端点共用这个函数，是为了保证它们的判定顺序完全一致：
// 先判断是否仍在慢启动时间窗之内，再判断是否被注入了故障，最后才返回成功。
func probeHandler(name string, isFailed func() bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if withinSlowStart() {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, "%s: 503 启动过程尚未结束，已运行 %d 秒，慢启动时间窗为 %d 秒\n",
				name, int(uptime().Seconds()), slowStartSeconds())
			log.Printf("probe path=%s result=503 reason=still-starting uptime=%ds",
				r.URL.Path, int(uptime().Seconds()))
			return
		}
		if isFailed() {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, "%s: 500 人为注入的故障正在生效\n", name)
			log.Printf("probe path=%s result=500 reason=injected-fault uptime=%ds",
				r.URL.Path, int(uptime().Seconds()))
			return
		}
		fmt.Fprintf(w, "%s: 200 正常\n", name)
		log.Printf("probe path=%s result=200 uptime=%ds", r.URL.Path, int(uptime().Seconds()))
	}
}

// writeFaultState 把当前的故障状态写回给调用者，供实验者确认注入是否已经生效。
func writeFaultState(w http.ResponseWriter) {
	healthzDown, readyzDown := fault.snapshot()
	fmt.Fprintf(w, "healthz_fault=%t\n", healthzDown)
	fmt.Fprintf(w, "readyz_fault=%t\n", readyzDown)
}

// faultAdminHandler 处理故障注入请求。
// 请求必须同时带有 target 与 state 两个查询参数：
// target 取 healthz、readyz 或者 both，state 取 down 或者 up；
// 任何一个参数缺失时，本处理函数只报告当前状态，不做任何修改。
func faultAdminHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	target := r.URL.Query().Get("target")
	state := r.URL.Query().Get("state")
	if target == "" || state == "" {
		fmt.Fprint(w, "缺少参数，本次未做任何修改。当前状态：\n")
		writeFaultState(w)
		return
	}
	var down bool
	switch state {
	case "down":
		down = true
	case "up":
		down = false
	default:
		http.Error(w, "参数 state 只接受 down 或者 up", http.StatusBadRequest)
		return
	}
	switch target {
	case "healthz", "readyz", "both":
	default:
		http.Error(w, "参数 target 只接受 healthz、readyz 或者 both", http.StatusBadRequest)
		return
	}
	fault.set(target, down)
	log.Printf("fault-changed target=%s state=%s uptime=%ds", target, state, int(uptime().Seconds()))
	fmt.Fprint(w, "修改已完成。当前状态：\n")
	writeFaultState(w)
}

// statusRecorder 包装 http.ResponseWriter，把写出的状态码记录下来。
// 有了这个记录，日志里就能直接看到「kubelet 发出的探针请求收到了哪一个状态码」，
// 不需要另外去猜探针失败的原因。
type statusRecorder struct {
	http.ResponseWriter
	status int
}

// WriteHeader 记录状态码，然后把它交给被包装的 ResponseWriter 继续处理。
func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Write 在没有显式调用 WriteHeader 的情况下补齐状态码 200。
// 这一个分支是必要的：Go 的标准库在只调用 Write 而没有调用 WriteHeader 时默认写出状态码 200，
// 如果这里不补齐，日志中记录的状态码就会是零值，与真实的响应不一致。
func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// logRequests 把所有请求的方法、路径与最终状态码写入标准输出。
// 探针的请求日志与普通请求的日志混在同一个输出流里，因此日志中会反复出现 /healthz 与 /readyz 这两个路径，
// 它们正是 kubelet 按照 periodSeconds 指定的间隔发起的探测请求。
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		log.Printf("http method=%s path=%s status=%d", r.Method, r.URL.Path, rec.status)
	})
}

func main() {
	log.Printf("webapp v6 启动，进程启动时刻的配置来源检查：\n%s", report())
	log.Printf("慢启动时间窗 SLOW_START_SECONDS=%d 秒", slowStartSeconds())

	mux := http.NewServeMux()
	// 根路径是一个兜底路由，它匹配所有没有被更具体规则匹配到的路径。
	// Go 的 ServeMux 在匹配时优先选择最长的模式，因此 /healthz、/readyz 这类更具体的路径不会被它抢走。
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/config", configHandler)
	mux.HandleFunc("/state", stateHandler)
	mux.HandleFunc("/healthz", probeHandler("/healthz", func() bool {
		healthzDown, _ := fault.snapshot()
		return healthzDown
	}))
	mux.HandleFunc("/readyz", probeHandler("/readyz", func() bool {
		_, readyzDown := fault.snapshot()
		return readyzDown
	}))
	mux.HandleFunc("/admin/fault", faultAdminHandler)

	log.Println("webapp v6 正在监听 " + listenAddress)
	if err := http.ListenAndServe(listenAddress, logRequests(mux)); err != nil {
		log.Fatal(err)
	}
}
