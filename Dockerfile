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
    && echo "Asia/Shanghai" > /etc/timezone \
    &&rm -rf /var/cache/apk/* /tmp/* /var/tmp/* $HOME/.cache

# 设置时区
RUN apk add --no-cache tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# 安装 Go 和 Chromedp
RUN apk add --no-cache go \
    && export GOPROXY=https://goproxy.cn \
    && go get -u github.com/chromedp/chromedp
    
# 清除缓存
RUN rm -rf /var/cache/apk/* /tmp/* /var/tmp/* $HOME/.cache