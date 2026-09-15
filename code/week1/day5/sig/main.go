// 实验 4：同一个程序，三种"对 SIGTERM 的态度" —— 用 MODE 切换
//
//	default  : 不装 handler，SIGTERM 走默认处置
//	graceful : 捕获 SIGTERM → 打印"正在善后" → 2s 后 exit(0)   ← 这才是"优雅关闭成功"
//	ignore   : 忽略 SIGTERM，继续睡 → docker stop 超时后被 SIGKILL（137）
//
// 为什么用 Go 写：它是静态二进制，PID 1 就是它自己，不经过 shell → 信号不会被吞
package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	mode := os.Getenv("MODE")
	if mode == "" {
		mode = "default"
	}
	fmt.Printf("[%s] started: pid=%d\n", mode, os.Getpid())

	// 心跳：日志能精确暴露"死在哪一秒"
	go func() {
		for i := 1; ; i++ {
			fmt.Printf("[%s] alive %ds\n", mode, i)
			time.Sleep(time.Second)
		}
	}()

	switch mode {
	case "graceful":
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGTERM)
		go func() {
			sig := <-ch
			fmt.Printf("[graceful] got %v -> 停止接收新连接\n", sig)
			time.Sleep(2 * time.Second) // 模拟：处理完在途请求
			fmt.Println("[graceful] 在途请求处理完 -> 刷盘/注销 -> exit(0)")
			os.Exit(0)
		}()
	case "ignore":
		signal.Ignore(syscall.SIGTERM)
		fmt.Println("[ignore] SIGTERM 已被忽略，我继续睡（等 SIGKILL）")
	case "default":
		fmt.Println("[default] 没装 handler，SIGTERM 用系统默认处置")
	}

	for { // 常驻前台（服务型进程就该这样）
		time.Sleep(time.Hour)
	}
}
