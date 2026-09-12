#!/bin/bash

# mission: 建 `touch "a b.txt"`，分别跑 `for f in $(ls)` 和 `for f in *` 打印 `$f`

echo '== for f in $(ls) =='
for f in $(ls); do
    echo "$f"
done

echo '== for f in * =='
for f in *; do
    echo "$f"
done