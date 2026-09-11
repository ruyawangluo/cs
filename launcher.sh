#!/bin/bash
# 启动脚本

echo "=============================="
echo "  私有仓库脚本远程执行工具"
echo "=============================="
echo ""

# 输入 GitHub Token
read -s -p "请输入 GitHub Token: " TOKEN
echo ""

# 输入私有仓库脚本地址
read -p "请输入私有仓库脚本路径（如 用户名/仓库名/分支/脚本）: " SCRIPT_PATH
echo ""
echo "正在获取并执行脚本..."
echo ""

# 拼接完整 URL 并执行
SCRIPT_URL="https://raw.githubusercontent.com/${SCRIPT_PATH}"
curl -s -H "Authorization: token ${TOKEN}" "${SCRIPT_URL}" | bash
