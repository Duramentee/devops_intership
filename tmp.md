# tmp

## Shell 主域复习
for f in $(ls /data); do 
    cp $f /backup/; 
done
当 /data 里存在含空格的文件名（例如 a b.txt）时会怎么坏？
shell在真正执行命令之前会先经过预处理阶段, 会走IFS分词, glob分词以及通配符展开
后面的我都不会了


for f in "/data*"; do
    cp -- "$f" /backup/
done




