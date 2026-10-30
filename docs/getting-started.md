# 快速上手

> 从制品库拉到本地、在容器里把一个基础镜像该验的东西验一遍、再把它当成其它镜像的 `FROM` 基座——三步走完，再决定深读哪一篇。

## 镜像里有什么

| 项目     | 值                                                                  |
|----------|---------------------------------------------------------------------|
| 镜像地址 | `docker.cnb.cool/dtapp/alpine`                                      |
| 基础     | 官方 `alpine:${ALPINE_VERSION}`，默认 `latest`                      |
| 平台     | linux/amd64、linux/arm64（多架构 manifest list + 单平台标签并存）   |
| 预装     | `ca-certificates`、`curl`、`netcat-openbsd`、`bind-tools`、`tzdata` |
| 时区     | `Asia/Shanghai`（`/etc/localtime` 与 `/etc/timezone` 均已写入）     |
| 用户     | root，未创建非 root 用户                                            |

镜像内容由 `.cnb/docker/Dockerfile` 决定，逐段解析见 [Dockerfile 解析](dockerfile.md)。

## 拉取镜像

```bash
# 默认标签，随每天 00:05 的定时构建更新
docker pull docker.cnb.cool/dtapp/alpine:latest

# 版本标签只在手动构建时填了 version 才存在
docker pull docker.cnb.cool/dtapp/alpine:3.20

# 在 amd64 机器上取 arm64 的单平台镜像
docker pull --platform linux/arm64 docker.cnb.cool/dtapp/alpine:latest
```

`latest` 是移动标签，今天拉到的和上周拉到的 digest 不同。需要固定产物时见下文「按 digest 固定拉取」。

标签的完整清单与命名契约（`latest`、`<version>`、`latest-linux-amd64`、`<version>-linux-arm64` 等）在 [镜像与标签](images-and-tags.md)。

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
  ls -l /etc/localtime
  command -v curl nc dig nslookup
'
```

每一项对应镜像里的一段设计：

| 命令                              | 期望结果         | 验证什么                       |
|-----------------------------------|------------------|--------------------------------|
| `cat /etc/alpine-release`         | 形如 `3.21.3`    | 基础版本与预期一致             |
| `date +%Z`                        | `CST`            | `tzdata` 与时区链接已生效      |
| `cat /etc/timezone`               | `Asia/Shanghai`  | 依赖该文件识别时区的程序能读到 |
| `command -v curl nc dig nslookup` | 四个路径都有输出 | 预装工具都在                   |

网络能力单独验一遍（镜像的卖点就是「进容器能排查」，这三条命令分别覆盖 HTTPS、端口、DNS）：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c '
  curl -sSI https://mirrors.aliyun.com | head -1
  nc -zv mirrors.aliyun.com 443
  dig +short mirrors.aliyun.com | head -3
'
```

- `curl -sSI` 只取响应头：能拿到 `HTTP/1.1 200 OK` 说明出网与 CA 证书链都正常（`ca-certificates` 缺失时这里会报证书错误）。
- `nc -zv host port` 探端口，`-z` 不发数据、`-v` 打印结果，输出走 stderr 属正常。
- `dig +short` 拿解析结果，`bind-tools` 提供。

如果 `date` 显示的是 UTC 而不是 CST，说明容器跑的不是本镜像，或者本地 `-v /etc/localtime:...` 之类的挂载覆盖了镜像内的设置。

## 作为其它镜像的 FROM 基座

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest

COPY app /usr/local/bin/app
CMD ["/usr/local/bin/app"]
```

- 已经带了 CA 证书与 `curl`，下游不需要再装一遍。
- 下游自己 `docker buildx build --platform linux/amd64,linux/arm64` 时，buildx 会按目标平台从多架构 manifest list 里挑对应的层，不需要改 `FROM`。
- 默认用户是 root。生产镜像应当在自己的层里补 `USER`，理由见 [Dockerfile 解析](dockerfile.md) 与 [安全基线](security-baseline.md)。
- 制品库若是私有的，先 `docker login docker.cnb.cool` 再拉取。

## 按 digest 固定拉取

标签会移动，digest 不会。要「锁定某次构建的产物」，用 digest 而不是 tag。

取当前 `latest` 的 digest：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}'
```

完整值也可以从 commit 元数据里的 `image_digest` 读（见 [构建元数据](metadata-and-badges.md)），那是构建当时写下的值。

用 digest 拉取与引用：

```bash
docker pull docker.cnb.cool/dtapp/alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

```dockerfile
FROM docker.cnb.cool/dtapp/alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

两点注意：

- `imagetools inspect` 对 `latest` 给出的是多架构 index 的 digest，按它拉取时 docker 会挑当前平台对应的清单，这是正确用法。
- `latest-linux-amd64` 这类单平台标签的 digest 只对应那一个平台的镜像，拿去在 arm64 上拉会失败。

## 下一步读哪篇

| 你的目的                     | 先读                             |
|------------------------------|----------------------------------|
| 搞清楚镜像每一层是怎么来的   | [Dockerfile 解析](dockerfile.md) |
| 换 APK 源、排查装包慢        | [APK 源与网络](mirrors.md)       |
| 自己构建，或改构建脚本       | [构建](build.md)                 |
| 标签命名、manifest list 细节 | [镜像与标签](images-and-tags.md) |

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [镜像与标签](images-and-tags.md)
- [README](../README.md)
