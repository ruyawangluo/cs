#!/bin/bash
# 启动脚本 - 智能版
# 支持用户输入各种格式，自动提取脚本地址

echo "=============================="
echo "  私有仓库脚本远程执行工具"
echo "=============================="
echo ""

# 输入 GitHub Token
read -s -p "请输入 GitHub Token: " TOKEN
echo ""

# 输入脚本地址（支持多种格式）
echo "支持以下任意格式："
echo "  1. https://raw.githubusercontent.com/用户/仓库/分支/脚本.sh"
echo "  2. https://github.com/用户/仓库/blob/分支/脚本.sh"
echo "  3. 用户/仓库/分支/脚本.sh"
echo "  4. 含命令的完整语句（自动提取URL）"
echo ""
read -p "请输入脚本地址: " INPUT
echo ""

# ============ 智能匹配提取 URL ============

# 1. 优先匹配 raw.githubusercontent.com 开头、.sh 结尾的URL
SCRIPT_URL=$(echo "$INPUT" | grep -oE 'https://raw\.githubusercontent\.com/[a-zA-Z0-9/_.-]+\.sh' | head -1)

# 2. 没找到，尝试匹配 github.com URL 并转换为 raw 格式
if [ -z "$SCRIPT_URL" ]; then
    GH_URL=$(echo "$INPUT" | grep -oE 'https://github\.com/[a-zA-Z0-9/_.-]+\.sh' | head -1)
    if [ -n "$GH_URL" ]; then
        # github.com → raw.githubusercontent.com，去掉 /blob/
        SCRIPT_URL=$(echo "$GH_URL" | sed 's|github.com|raw.githubusercontent.com|; s|/blob/|/|')
    fi
fi

# 3. 还没找到，检查是否是纯路径（以 .sh 结尾）
if [ -z "$SCRIPT_URL" ]; then
    if echo "$INPUT" | grep -qE '\.sh$'; then
        # 去掉可能的命令前缀和多余字符，只保留路径部分
        CLEAN=$(echo "$INPUT" | sed 's|.*raw.githubusercontent.com/||; s|.*github.com/||; s|^||; s|blob/||')
        SCRIPT_URL="https://raw.githubusercontent.com/${CLEAN}"
    fi
fi

# ============ 检查是否成功提取 ============

if [ -z "$SCRIPT_URL" ]; then
    echo "错误：无法从输入中识别脚本地址"
    echo "请确认地址以 .sh 结尾"
    exit 1
fi

echo "已识别脚本地址："
echo "  ${SCRIPT_URL}"
echo ""
echo "正在获取并执行脚本..."
echo ""

curl -s -H "Authorization: token ${TOKEN}" "${SCRIPT_URL}" | bash
