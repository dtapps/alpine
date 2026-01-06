# ===================================================================
# 定义构建参数 (ARG)
# ===================================================================
ARG ALPINE_VERSION=latest

# 使用官方 Alpine 作为基础镜像（轻量、安全）
# Alpine 特点：体积小（约5MB）、安全、适合容器化部署
FROM alpine:${ALPINE_VERSION}

# ===================================================================
# STEP 1: 替换为自定义镜像源，加速软件包下载（国内用户必备）
# 默认源 dl-cdn.alpinelinux.org 在国内访问较慢，替换为自定义镜像可大幅提升构建速度
# ===================================================================
RUN ALPINE_VER=$(cat /etc/alpine-release | cut -d'.' -f1,2) && \
    echo "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/main" > /etc/apk/repositories && \
    echo "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories && \
    echo "https://mirrors.cloud.tencent.com/alpine/v${ALPINE_VER}/main" >> /etc/apk/repositories && \
    echo "https://mirrors.cloud.tencent.com/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories && \
    echo "https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/main" >> /etc/apk/repositories && \
    echo "https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories && \
    echo "https://mirrors.volces.com/alpine/v${ALPINE_VER}/main" >> /etc/apk/repositories && \
    echo "https://mirrors.volces.com/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories && \
    apk update --no-cache

# ===================================================================
# STEP 2: 安装运行时必需的基础组件（最小化依赖）
# 仅安装最核心的包，确保镜像尽可能轻量
# ===================================================================
RUN apk add --no-cache \
    tzdata \
    ca-certificates \
    curl \
    netcat-openbsd \
    bind-tools

# 注释：
# - tzdata: 设置时区
# - ca-certificates: 支持 HTTPS
# - curl: 调试 HTTP/HTTPS 接口（如 OTLP）
# - netcat-openbsd: 测试端口连通性（nc -zv host port）
# - bind-tools: DNS 查询（nslookup, dig）

# ===================================================================
# STEP 3: 设置中国上海时区（避免日志时间错乱、定时任务异常）
# ln -sf：创建符号链接，将系统默认时钟指向上海时区
# echo > /etc/timezone：写入时区标识（部分应用依赖此文件识别时区）
# ===================================================================
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# ===================================================================
# STEP 4: 清理所有临时文件与缓存（关键步骤！极大减少镜像体积）
# Alpine 的 APK 缓存默认保存在 /var/cache/apk/，必须手动清理
# 同时清除 /tmp 下可能残留的临时文件
# ===================================================================
RUN rm -rf \
    /tmp/* \
    /var/cache/apk/* \
    /root/.cache \
    /var/tmp/*