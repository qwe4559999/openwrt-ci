#!/bin/bash

set -e  # 遇到错误立即退出

echo "开始配置 SYSU minieap..."

# 检查包管理器类型
if grep -q "CONFIG_USE_APK=y" .config 2>/dev/null || [ -f "include/package-apk.mk" ]; then
    echo "检测到 APK 包管理器，配置 APK 格式编译"
    PACKAGE_FORMAT="apk"
else
    echo "使用 OPKG 包管理器，配置 IPK 格式编译"
    PACKAGE_FORMAT="ipk"
fi

# 清理可能存在的冲突包
rm -rf package/feeds/packages/minieap
rm -rf feeds/packages/net/minieap
rm -rf package/minieap

# 清理 feeds 缓存
rm -rf feeds/packages.tmp
rm -rf tmp/

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

# 根据包管理器类型配置编译选项
if [ "$PACKAGE_FORMAT" = "apk" ]; then
    echo "配置 APK 包格式编译..."
    # 确保使用 APK 兼容的编译选项
    if [ -f "package/minieap/Makefile" ]; then
        # 检查是否需要修改 Makefile 以支持 APK
        if ! grep -q "PKG_FORMAT.*apk" package/minieap/Makefile; then
            echo "# APK package format compatibility" >> package/minieap/Makefile
        fi
    fi
else
    echo "配置 IPK 包格式编译..."
    # 使用传统的 IPK 编译配置
fi

# 创建 feeds 覆盖配置
mkdir -p feeds/packages/net/
ln -sf ../../../package/minieap feeds/packages/net/minieap

# 强制清理并重建 feeds.conf.default
if [ -f "feeds.conf.default" ]; then
    mv feeds.conf.default feeds.conf.default.bak
fi

if [ -f "feeds.conf.default.sample" ]; then
    cp feeds.conf.default.sample feeds.conf.default
else
    # 如果 sample 文件不存在，则创建一个基础的 feeds.conf.default
    echo "src-git packages https://git.openwrt.org/feed/packages.git" > feeds.conf.default
    echo "src-git luci https://git.openwrt.org/project/luci.git" >> feeds.conf.default
    echo "src-git routing https://git.openwrt.org/feed/routing.git" >> feeds.conf.default
    echo "src-git telephony https://git.openwrt.org/feed/telephony.git" >> feeds.conf.default
fi

# 添加自定义 feeds
echo "src-git nss_packages https://github.com/LiBwrt/nss-packages.git" >> feeds.conf.default
echo "src-git sqm_scripts_nss https://github.com/rickkdotnet/sqm-scripts-nss.git" >> feeds.conf.default

# 更新 feeds（排除可能冲突的包）
./scripts/feeds update -a
./scripts/feeds install -a -p luci
./scripts/feeds install -a -p routing
./scripts/feeds install -a -p telephony
./scripts/feeds install -a -p video
./scripts/feeds install -a -p nss_packages
./scripts/feeds install -a -p sqm_scripts_nss

# 排除默认的 minieap 包，确保使用 SYSU 版本
./scripts/feeds install -a -p packages -d minieap

# 强制安装本地 SYSU minieap
./scripts/feeds install -f minieap

echo "SYSU minieap 配置完成！"

# 添加磁盘管理和清理工具配置
echo "配置磁盘管理工具..."

# 添加磁盘管理相关包到配置
cat >> .config << EOF
# 磁盘管理工具
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_libfdisk=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_libparted=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_kmod-fs-ext4=y

# 系统监控和清理工具
CONFIG_PACKAGE_ncdu=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_tree=y
CONFIG_PACKAGE_lsof=y
CONFIG_PACKAGE_coreutils-du=y
CONFIG_PACKAGE_coreutils-find=y

# 文件系统工具
CONFIG_PACKAGE_dosfstools=y
CONFIG_PACKAGE_ntfs-3g=y
CONFIG_PACKAGE_ntfs-3g-utils=y

# 强制使用 SYSU minieap
CONFIG_PACKAGE_minieap=y
CONFIG_PACKAGE_luci-app-minieap=y
CONFIG_PACKAGE_luci-i18n-minieap-zh-cn=y

# 包管理器配置
CONFIG_USE_APK=y
CONFIG_PACKAGE_apk=y
CONFIG_PACKAGE_apk-tools=y
EOF

echo "包格式配置完成：$PACKAGE_FORMAT"

# 创建磁盘清理脚本
mkdir -p files/usr/bin
cat > files/usr/bin/disk-cleanup.sh << 'EOF'
#!/bin/sh

echo "开始磁盘清理..."

# 清理日志文件
find /var/log -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
find /tmp -type f -mtime +1 -delete 2>/dev/null || true

# 清理包管理器缓存
opkg clean 2>/dev/null || true

# 清理 Docker 数据（如果存在）
if command -v docker >/dev/null 2>&1; then
    docker system prune -af 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
fi

# 清理内核模块缓存
rm -rf /tmp/opkg-* 2>/dev/null || true

# 同步文件系统
sync

echo "磁盘清理完成！"
EOF

chmod +x files/usr/bin/disk-cleanup.sh

# 创建定时清理任务
mkdir -p files/etc/crontabs
echo "0 3 * * 0 /usr/bin/disk-cleanup.sh" > files/etc/crontabs/root

# 创建分区扩展脚本
cat > files/usr/bin/expand-overlay.sh << 'EOF'
#!/bin/sh

echo "开始扩展 overlay 分区..."

# 检查是否存在大分区
LARGE_PARTITION="/dev/mmcblk0p25"
if [ ! -b "$LARGE_PARTITION" ]; then
    echo "未找到大分区 $LARGE_PARTITION"
    exit 1
fi

# 获取分区信息
PARTITION_SIZE=$(blockdev --getsize64 $LARGE_PARTITION)
PARTITION_SIZE_GB=$((PARTITION_SIZE / 1024 / 1024 / 1024))

echo "发现分区 $LARGE_PARTITION，大小: ${PARTITION_SIZE_GB}GB"

# 检查是否已经挂载
if mount | grep -q "$LARGE_PARTITION"; then
    echo "分区已挂载，先卸载..."
    umount $LARGE_PARTITION 2>/dev/null || true
fi

# 格式化为 ext4
echo "格式化分区为 ext4..."
mkfs.ext4 -F $LARGE_PARTITION

# 创建挂载点
mkdir -p /mnt/overlay-ext

# 挂载分区
echo "挂载分区..."
mount $LARGE_PARTITION /mnt/overlay-ext

# 创建 overlay 目录结构
mkdir -p /mnt/overlay-ext/upper
mkdir -p /mnt/overlay-ext/work

# 备份当前 overlay 内容
echo "备份当前 overlay 内容..."
cp -a /overlay/* /mnt/overlay-ext/upper/ 2>/dev/null || true

# 更新 fstab
echo "更新 fstab 配置..."
grep -v "$LARGE_PARTITION" /etc/fstab > /tmp/fstab.new
echo "$LARGE_PARTITION /overlay ext4 defaults 0 0" >> /tmp/fstab.new
mv /tmp/fstab.new /etc/fstab

echo "overlay 扩展完成！重启后生效。"
echo "重启命令: reboot"
EOF

chmod +x files/usr/bin/expand-overlay.sh

# 创建自动分区配置脚本
cat > files/etc/init.d/auto-partition << 'EOF'
#!/bin/sh /etc/rc.common

START=19
USE_PROCD=1

start_service() {
    # 检查是否需要扩展 overlay
    LARGE_PARTITION="/dev/mmcblk0p25"
    
    if [ -b "$LARGE_PARTITION" ] && ! mount | grep -q "/overlay"; then
        # 检查分区大小
        PARTITION_SIZE=$(blockdev --getsize64 $LARGE_PARTITION 2>/dev/null || echo 0)
        PARTITION_SIZE_GB=$((PARTITION_SIZE / 1024 / 1024 / 1024))
        
        # 如果分区大于 10GB 且 overlay 空间小于 1GB，自动扩展
        OVERLAY_AVAIL=$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
        OVERLAY_AVAIL_MB=$((OVERLAY_AVAIL / 1024))
        
        if [ "$PARTITION_SIZE_GB" -gt 10 ] && [ "$OVERLAY_AVAIL_MB" -lt 1024 ]; then
            logger -t auto-partition "检测到大分区 ${PARTITION_SIZE_GB}GB，overlay 仅 ${OVERLAY_AVAIL_MB}MB，准备自动扩展"
            
            # 创建标记文件，避免重复执行
            if [ ! -f "/etc/overlay-expanded" ]; then
                /usr/bin/expand-overlay.sh
                touch /etc/overlay-expanded
                logger -t auto-partition "overlay 扩展完成，将在下次重启生效"
            fi
        fi
    fi
}
EOF

chmod +x files/etc/init.d/auto-partition

# 添加到启动服务
mkdir -p files/etc/rc.d
ln -sf ../init.d/auto-partition files/etc/rc.d/S19auto-partition

# 添加手动扩展说明文件
cat > files/etc/overlay-expand-guide.txt << 'EOF'
=== OpenWrt Overlay 扩展指南 ===

当前系统检测到大容量分区但 overlay 空间不足的情况。

自动扩展：
系统会在启动时自动检测并扩展 overlay 分区。

手动扩展：
1. 运行扩展脚本：
   /usr/bin/expand-overlay.sh

2. 重启系统：
   reboot

3. 验证扩展结果：
   df -h /overlay

注意事项：
- 扩展过程会格式化大分区，请确保数据已备份
- 扩展后需要重启才能生效
- 扩展是一次性操作，完成后不会重复执行

查看分区信息：
   lsblk
   fdisk -l
EOF

echo "分区扩展配置完成！"
echo "磁盘管理工具配置完成！"
