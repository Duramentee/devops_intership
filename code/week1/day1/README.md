# Day 1 · shell 分词实验

验证：`for f in $(ls)` 会把含空格的文件名拆开，`for f in *` 不会。

```bash
bash split.sh
```

| 文件 | 说明 |
|---|---|
| `split.sh` | 两种循环写法的对比脚本 |
| `a b.txt` | 含空格的测试文件（文件名本身就是实验对象） |

预期现象：`for f in $(ls)` 打印成两行 `a`、`b.txt`；`for f in *` 打印成一行 `a b.txt`。
