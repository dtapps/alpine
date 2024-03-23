FROM alpine:20240315

# 更改镜像源并更新
RUN apk add --no-cache curl \
    && curl -fsSL https://cdn.dtapp.net/linux/fix_source.sh -o /tmp/fix_source.sh \
    && sh /tmp/fix_source.sh \
    && rm -f /tmp/fix_source.sh \
    && apk update

# 安装 Chromium 浏览器和依赖项
RUN apk add --no-cache \
    chromium \
    nss \
    freetype \
    freetype-dev \
    harfbuzz \
    ca-certificates \
    ttf-freefont

# 设置时区
RUN apk add --no-cache tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# 安装 Go 编译器和 Git
RUN apk add --no-cache go git

# 设置 Go Modules 和 GOPROXY
RUN go env -w GO111MODULE=on \
    && go env -w GOPROXY=https://goproxy.cn,direct

# 获取并安装 chromedp
RUN go install github.com/chromedp/chromedp@latest

# 清除缓存
RUN rm -rf /tmp/*