// 实验 3：内存吞噬器 —— 用来在 -m 限制下触发内核 OOM Killer
//
// 关键点：make() 只是分配虚拟内存，必须**逐个字节写**才能真正落页（否则 OOM 不触发）
// 每涨 8 MiB 打印一行，这样日志会精确停在"死前最后一个成功的动作"上
package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	const chunk = 8 << 20 // 8 MiB

	var chunks [][]byte
	for i := 1; i <= 64; i++ {
		buf := make([]byte, chunk)
		for j := range buf { // 触碰每个字节 → 真正占用物理内存
			buf[j] = byte(i)
		}
		chunks = append(chunks, buf)
		fmt.Printf("allocated %d MiB (pid %d)\n", i*8, os.Getpid())
		_ = os.Stdout.Sync()
		time.Sleep(300 * time.Millisecond)
	}
	fmt.Println("survived: 512 MiB allocated without OOM")
	_ = chunks
}
