#!/bin/bash
# 从 /opt/vpsm/config.yaml 读取 systemKey 值

CONFIG_FILE="/opt/vpsm/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误：配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

SYSTEM_KEY=$(awk '/^[[:space:]]*(-[[:space:]]+)?systemKey:/ {print $2; exit}' "$CONFIG_FILE")

if [ -z "$SYSTEM_KEY" ]; then
    echo "错误：未找到 systemKey"
    exit 1
fi

echo "秘钥：$SYSTEM_KEY"
