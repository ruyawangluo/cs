# cs

存放日常自用小脚本，用于远程执行。

## 脚本目录

| 脚本 | 说明 |
| --- | --- |
| launcher.sh | 私有仓库脚本远程执行入口 |
| fix-net.sh | DD 重装后重建网卡配置 |

## 远程执行

```bash
curl -fsSL https://raw.githubusercontent.com/ruyawangluo/cs/master/fix-net.sh -o /tmp/fix-net.sh && sudo bash /tmp/fix-net.sh
```

把脚本名换成目标文件即可，例如：

```bash
curl -fsSL https://raw.githubusercontent.com/ruyawangluo/cs/master/launcher.sh -o /tmp/launcher.sh && bash /tmp/launcher.sh
```
