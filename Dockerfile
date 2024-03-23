FROM alpine:20240315

# 更改为腾讯云的镜像源并更新
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tencent.com/g' /etc/apk/repositories \
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

# 获取 chromedp
RUN go get -u -v github.com/chromedp/chromedp

# 清除缓存
RUN rm -rf /var/cache/apk/* /tmp/* /var/tmp/* $HOME/.cache