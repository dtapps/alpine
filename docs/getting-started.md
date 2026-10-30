# 快速上手

> 从制品库拉到本地、在容器里把一个基础镜像该验的东西验一遍、再把它当成其它镜像的 `FROM` 基座——三步走完，再决定深读哪一篇。

## 镜像里有什么

| 项目     | 值                                                                   |
|----------|----------------------------------------------------------------------|
| 镜像地址 | `docker.cnb.cool/dtapp/alpine`                                       |
| 基础     | 官方 `alpine:latest`（跟随上游 latest-stable，构建时解析成具体版本） |
| 平台     | linux/amd64、linux/arm64（多架构 index + 派生的单平台标签）          |
| 预装     | `ca-certificates`、`curl`、`drill`、`netcat-openbsd`、`tzdata`       |
| 时区     | `Asia/Shanghai`（`/etc/localtime`、`/etc/timezone`、`TZ` 三者配套）  |
| 用户     | root，未创建非 root 用户（生产镜像由下游自行降权）                   |
| 入口     | 无 `ENTRYPOINT` / `CMD` / `HEALTHCHECK`，由下游镜像自己声明          |

基座默认跟随上游 `latest`，所以同一个标签隔几周再拉，里面的 alpine 版本可能已经从 `3.25.1` 变成 `3.25.2`——这是有意的，定时任务每天重建就是为了把上游补丁吃进来。「这一份到底是哪个版本」不会丢：版本标签名就是具体版本号（如 `3.25.1`），镜像 label 里还记着当时基座的 digest，commit 元数据里也有一份 `image_digest`。

镜像内容由 `.cnb/docker/Dockerfile` 决定，逐段解析见 [Dockerfile 解析](dockerfile.md)。注意 DNS 工具是 `drill` 而不是 `dig`：两者语法接近但命令名不同，`dig +short` 在这里会 `command not found`。

## 拉取镜像

```bash
# 移动标签，随每天 00:05 的定时构建前进（基座跟随上游 latest）
docker pull docker.cnb.cool/dtapp/alpine:latest

# 滚动 minor 标签，跟随该分支最近一次成功构建
docker pull docker.cnb.cool/dtapp/alpine:3.25

# 版本标签：就是 alpine 的实际版本号，每天重建会覆盖同名标签
docker pull docker.cnb.cool/dtapp/alpine:3.25.1

# 在 amd64 机器上取 arm64 的单平台镜像
docker pull --platform linux/arm64 docker.cnb.cool/dtapp/alpine:latest
```

三条标签都会动：`latest` 与 `3.25` 在冒烟通过后被提升，`3.25.1` 这种版本标签每天被重建结果覆盖（上游还是同一个 patch 时）。所以**标签只说明「这条线现在指向什么」，不承诺内容不变**；要固定某一份产物，只能用 digest，见下文「按 digest 固定拉取」。版本标签的好处是可读：`3.25.1` 一眼看出吃的是哪个 alpine，不用去猜日期。

标签只有三种：版本标签 `<alpine 版本>`（如 `3.25.1`）、滚动 `<major.minor>`（如 `3.25`）、`latest`；版本标签还有 `-linux-amd64` / `-linux-arm64` 两个派生形式。完整契约见 [镜像与标签](images-and-tags.md)。

## 运行容器

```bash
# 交互式 shell（基础镜像只有 busybox sh，没有 bash）
docker run --rm -it docker.cnb.cool/dtapp/alpine:latest sh

# 一次性命令
docker run --rm docker.cnb.cool/dtapp/alpine:latest date
```

`--rm` 让容器退出即删除。作为调试容器用时通常不需要挂载卷，需要看宿主机文件时再自行加 `-v`。

## 容器内自检

起一个容器，把该验的东西一次跑完：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c '
  cat /etc/alpine-release
  date
  date +%Z
  cat /etc/timezone
  cat /etc/apk/repositories
  command -v curl nc drill nslookup
'
```

每一项对应镜像里的一段设计：

| 命令                                | 期望结果             | 验证什么                       |
|-------------------------------------|----------------------|--------------------------------|
| `cat /etc/alpine-release`           | 形如 `3.25.1`        | 基座版本（跟随上游时会变）     |
| `date +%Z`                          | `CST`                | `tzdata` 与时区链接已生效      |
| `cat /etc/timezone`                 | `Asia/Shanghai`      | 依赖该文件识别时区的程序能读到 |
| `cat /etc/apk/repositories`         | 四行，且都是 `/main` | 源配置没有被写坏               |
| `command -v curl nc drill nslookup` | 四个路径都有输出     | 预装工具都在                   |

网络能力单独验一遍（镜像的卖点就是「进容器能排查」，这三条命令分别覆盖 HTTPS、端口、DNS）：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c '
  curl -sSI https://mirrors.aliyun.com | head -1
  nc -zv mirrors.aliyun.com 443
  drill mirrors.aliyun.com | head -5
'
```

- `curl -sSI` 只取响应头：能拿到 `HTTP/1.1 200 OK` 说明出网与 CA 证书链都正常（`ca-certificates` 缺失时这里会报证书错误）。
- `nc -zv host port` 探端口，`-z` 不发数据、`-v` 打印结果，输出走 stderr 属正常。
- `drill <域名>` 打印解析结果与查询统计，由 `drill` 包提供；要只看解析出来的地址，用 `drill <域名> | sed -n '/ANSWER SECTION/,/^$/p'` 之类的过滤，而不是 `dig +short`。

如果 `date` 显示的是 UTC 而不是 CST，说明容器跑的不是本镜像，或者本地 `-v /etc/localtime:...` 之类的挂载覆盖了镜像内的设置。

## 作为其它镜像的 FROM 基座

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest

COPY app /usr/local/bin/app
CMD ["/usr/local/bin/app"]
```

- 已经带了 CA 证书与 `curl`，下游不需要再装一遍。
- 下游自己 `docker buildx build --platform linux/amd64,linux/arm64` 时，buildx 会按目标平台从多架构 index 里挑对应的层，不需要改 `FROM`。
- 本镜像不含 `ENTRYPOINT` / `CMD` / `HEALTHCHECK`，也没有 `WORKDIR`：下游继承到的是「一个干净的运行时 + 几个排查工具」，启动方式由下游自己声明。
- 默认用户是 root。生产镜像应当在自己的层里补 `USER`，理由见 [Dockerfile 解析](dockerfile.md) 与 [安全基线](security-baseline.md)。
- 制品库若是私有的，先 `docker login docker.cnb.cool` 再拉取。

## 按 digest 固定拉取

标签会移动，digest 不会。要「锁定某次构建的产物」，**只能用 digest**——标签名里没有日期，同名标签每天会被覆盖。

取当前 `latest` 的 digest：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}'
```

更可靠的办法是读 commit 元数据里的 `image_digest`（见 [构建元数据](metadata-and-badges.md)），那是构建当时写下的值。注意 `annotation.json` 每次构建都会被覆写、只保留最近一次，要长期留档就自己把 digest 抄到发布记录里。

用 digest 拉取与引用：

```bash
docker pull docker.cnb.cool/dtapp/alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

```dockerfile
FROM docker.cnb.cool/dtapp/alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

四点注意：

- 所有标签都会移动，`3.25.1` 也不例外：上游没发新 patch 时，今天和明天的 `3.25.1` 指向两次不同的构建。digest 是唯一不动的坐标。
- `imagetools inspect` 对 `latest` 给出的是多架构 index 的 digest，按它拉取时 docker 会挑当前平台对应的清单，这是正确用法；把它记下来，就是「今天这份」的凭据。
- `3.25.1-linux-amd64` 这类单平台标签是从版本标签**派生**的（`imagetools create` 指向同一份 digest，不重新构建），同样每天被覆盖；它只包含那一个平台的镜像，在 arm64 上直接拿它当基座并不合适。派生标签只挂在版本标签上，没有 `latest-linux-amd64`。
- 想知道某个产物是基于哪一份 alpine 构建的，读镜像 label 里的 `org.opencontainers.image.base.digest`；commit 元数据里的 `base_digest` / `alpine_version` 是同一份信息的独立记录（见 [构建元数据](metadata-and-badges.md)）。

## 下一步读哪篇

| 你的目的                     | 先读                             |
|------------------------------|----------------------------------|
| 搞清楚镜像那一层是怎么来的   | [Dockerfile 解析](dockerfile.md) |
| 换 APK 源、排查装包慢        | [APK 源与网络](mirrors.md)       |
| 自己构建，或改构建脚本       | [构建](build.md)                 |
| 标签命名、manifest list 细节 | [镜像与标签](images-and-tags.md) |

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [镜像与标签](images-and-tags.md)
- [README](../README.md)
