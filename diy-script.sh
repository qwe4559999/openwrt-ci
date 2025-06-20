#!/bin/bash

set -e  # 遇到错误立即退出

echo "开始配置 SYSU minieap..."

# 清理可能存在的冲突包
rm -rf package/feeds/packages/minieap
rm -rf feeds/packages/net/minieap
rm -rf package/minieap

# 克隆 SYSU 适配版本
git clone --depth 1 https://github.com/Undefined443/openwrt-minieap-sysu.git package/minieap

# 验证克隆结果
if [ ! -d "package/minieap" ] || [ ! -f "package/minieap/Makefile" ]; then
    echo "错误：SYSU minieap 克隆失败"
    exit 1
fi

echo "SYSU minieap 源码验证："
ls -la package/minieap/
echo "Makefile 内容检查："
head -20 package/minieap/Makefile

# 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a

echo "SYSU minieap 配置完成！"
