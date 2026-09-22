// webapp v5：在 v4 的基础上增加「从 ConfigMap 读取配置」的能力。
//
// 与 v4 的差异只有一处：v4 把响应内容硬编码在源码中，v5 改为在启动时与每一次请求时
// 分别读取环境变量与挂载进容器内的文件，因此可以用同一条命令观察到两种注入方式的更新行为差异。
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
)

// 下面三个位置分别对应本日实验中的三种配置来源：
//  1. GREETING 既以环境变量方式注入，又以文件方式挂载，因此它同时出现在两个位置上，可以直接对比；
//  2. config.conf 只以文件方式挂载，用于观察「ConfigMap 中的一个键就是一个文件」这一行为；
//  3. DB_PASSWORD 只以环境变量方式注入，用于观察 Secret 的注入结果。
const (
	greetingEnvKey   = "GREETING"
	greetingFilePath = "/etc/webapp/GREETING"
	configFilePath   = "/etc/webapp-file/config.conf"
)

// envOrMissing 与 os.Getenv 的区别在于是否区分「变量不存在」与「变量取值为空字符串」两件事。
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

func rootHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, report())
	log.Printf("request accepted path=%s", r.URL.Path)
}

func configHandler(w http.ResponseWriter, r *http.Request) {
	// 这个处理函数在每一次请求时都重新读取文件。
	// 由于卷挂载的内容会被 kubelet 定期同步，因此这个端点的返回值会跟随 ConfigMap 一起变化，
	// 而在同一时刻，上面的环境变量仍然保持容器创建时的取值。
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, readIfExists(configFilePath), "\n")
	log.Printf("request accepted path=%s", r.URL.Path)
}

func main() {
	log.Printf("进程启动时刻的配置来源检查：\n%s", report())

	// 根路径用于观察环境变量与文件两种来源，/config 用于观察多行配置文件的内容。
	http.HandleFunc("/", rootHandler)
	http.HandleFunc("/config", configHandler)

	log.Println("webapp v5 正在监听 :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
