# Dockerfile 解析

> 六十来行，一个 `ARG`、一个 `FROM`、四个 `RUN`：换源、装包、写时区、清缓存，每一段都在为「体积最小 + 国内可构建」让路。

## 结构总览

```text
ARG ALPINE_VERSION=latest          → 构建参数，默认跟随上游最新
FROM alpine:${ALPINE_VERSION}      → 直接站在官方镜像上
RUN  换源 + apk update --no-cache   → 第 1 层：改 /etc/apk/repositories
RUN  apk add --no-cache 四个包      → 第 2 层：运行时工具
RUN  apk add --no-cache tzdata + 写时区 → 第 3 层：时区数据与配置
RUN  rm -rf 清理                    → 第 4 层：兜底清残留
```

结果是「官方 alpine + 4 层」。没有多阶段构建、没有 `scratch`、没有自研二进制，这也是镜像可以被放心当基座的前提。

## ARG ALPINE_VERSION

```dockerfile
ARG ALPINE_VERSION=latest
FROM alpine:${ALPINE_VERSION}
```

- 默认值 `latest`：不传参数时就是上游最新 Alpine。
- 声明在 `FROM` **之前**，才能被 `FROM` 行引用。写在 `FROM` 之后就只能给 `RUN` 用，改不了基础镜像。
- 用 ARG 而不是把版本写死，是为了让「换基础版本」变成一次构建参数，而不是一次代码提交。

本地覆盖：

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=3.20 -t alpine:local .
```

CI 覆盖：脚本里固定 `BUILD_ARGS="--build-arg ALPINE_VERSION=${INTERIOR_VERSION}"`，`INTERIOR_VERSION` 来自按钮输入 `version` 或定时任务的 `latest`。链路见 [CI 流水线](ci-pipeline.md)。

传一个 Docker Hub 上不存在的 tag（例如 `3.99`）会在 `FROM` 阶段直接失败，不会进入后面的 `RUN`；这是最省时间的失败方式。

## STEP 1：换源段

完整段是五组源 × `main`/`community` 共十行，下面节选前两组与收尾：

```dockerfile
RUN ALPINE_VER=$(cat /etc/alpine-release | cut -d'.' -f1,2) \
    && echo "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/main" >/etc/apk/repositories \
    && echo "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/community" >>/etc/apk/repositories \
    && echo "https://mirrors.cloud.tencent.com/alpine/v${ALPINE_VER}/main" >>/etc/apk/repositories \
    && echo "https://mirrors.cloud.tencent.com/alpine/v${ALPINE_VER}/community" >>/etc/apk/repositories \
    && apk update --no-cache
```

逐点说明（完整源列表与取舍见 [APK 源与网络](mirrors.md)）：

| 写法                                       | 为什么                                                               |
|--------------------------------------------|----------------------------------------------------------------------|
| `cut -d'.' -f1,2` 取 `/etc/alpine-release` | 文件是 `3.21.3`，仓库路径只要 `v3.21`；用标签 `latest` 拼不出 URL    |
| 第一行用 `>`、其余用 `>>`                  | `>` 覆写掉基础镜像自带的官方源内容，顺序完全由本段决定，不残留旧行   |
| `&&` 串联 + `\` 续行                       | 整段是一个 `RUN`，任何一行失败立即中断，不会产出「半个源列表」的层   |
| `apk update --no-cache`                    | 换完源立刻拉一遍索引，源配置的问题在这一层日志里就能看到；索引不落盘 |

`apk update` 的作用是让 apk 为 `/etc/apk/repositories` 里的每个仓库取一份 `APKINDEX`；`--no-cache` 让它用完即弃、不写进 `/var/cache/apk`。放在换源同一层的末尾，是「换完立刻验证」：URL 打错、路径少了 `v` 前缀、某个镜像站不可达，都会在这一层的构建日志里以报错或 `WARNING` 的形式出现，而不是留到某个下游 `apk add` 时才暴露。apk 对单个源不可达是容忍的（详见 [APK 源与网络](mirrors.md)），所以看日志要留意 `WARNING` 而不是只看退出码。

## STEP 2：包选择清单

```dockerfile
RUN apk add --no-cache \
    ca-certificates \
    curl \
    netcat-openbsd \
    bind-tools
```

| 包                | 提供                      | 用途                                 |
|-------------------|---------------------------|--------------------------------------|
| `ca-certificates` | 系统 CA 证书包            | `curl` 走 HTTPS 的前提，下游也常依赖 |
| `curl`            | `curl`                    | 调 HTTP/HTTPS 接口、探活             |
| `netcat-openbsd`  | `nc`                      | `nc -zv host port` 探端口连通性      |
| `bind-tools`      | `dig`、`nslookup`、`host` | 区分「网络不通」与「DNS 解析错」     |

`--no-cache` 让装完的 `.apk` 文件不留在 `/var/cache/apk`，等价于「装完立刻清」，比「先装、再单独一层清」少一层、少一次拷贝。

四个包的选择标准是同一句话：**进容器就能定位问题**。HTTP、端口、DNS 三条链路各有一个工具，再加证书，覆盖了绝大多数「服务连不上」的排查路径。

## STEP 3：tzdata 为什么单独一层

```dockerfile
RUN apk add --no-cache tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" >/etc/timezone
```

先看层内：装 `tzdata` 与写时区**必须在同一个 `RUN`**。`ln -sf` 的目标 `/usr/share/zoneinfo/Asia/Shanghai` 由 `tzdata` 提供，同一层里 `&&` 顺序天然正确；一旦拆成两层且顺序写反，只会得到一个悬空符号链接——`date` 照旧输出 UTC，命令一条都不报错，属于最难查的一类问题。

再看层间：这一段整体与 STEP 2 的包列表**分成两个 `RUN`**，理由是缓存粒度。层的缓存键由「本层指令 + 上层内容」算出，时区配置和包列表分开后，改时区只重建它之后的两层，装包层继续命中缓存；改包列表也只影响自己及之后。合并成一层能少一层开销，但会让「只想调时区」的改动连带重装所有包。

`ln -sf` 里 `-s` 建符号链接、`-f` 在目标已存在时覆盖（基础镜像自带的 `/etc/localtime` 是普通文件）。`/etc/timezone` 是纯文本时区名，给按名字读时区的程序用；只写 `/etc/localtime` 不写它，会有一部分程序仍然按 UTC 处理。

## STEP 4：清理层为什么必须最后

```dockerfile
RUN rm -rf \
    /tmp/* \
    /var/cache/apk/* \
    /root/.cache \
    /var/tmp/*
```

机制：Docker 每个 `RUN` 产出一层只读增量，层只增不减。在后一层 `rm` 掉前一层写进去的文件，只是在后一层记一条 whiteout，前一层的数据照样随镜像分发，体积一两不少。

由此得到两条硬规则：

- **同一个层里装完就删**才有意义。本镜像主要靠 `apk add --no-cache` 让缓存根本不落盘，最后的清理层是兜底，负责 `/tmp`、`/root/.cache`、`/var/tmp` 这类零散残留。
- **新增 `RUN` 必须加在清理层之前**。加在它后面既不会被清掉，也让「清理在最后」这个约定失效——这是 [CONTRIBUTING](../CONTRIBUTING.md) 里写明的规则。

本地确认每层体积：

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest -t alpine:local .
docker history alpine:local
```

`SIZE` 列会显示清理层接近 0，而如果清理被挤到中间，它会显示为一个小值、后续层继续累加。

## root 用户这一取舍

镜像不创建非 root 用户。理由：它是**基础调试镜像**，进容器就要能 `apk add`、改配置、连端口；一上来套 `USER`，第一件事就卡在权限上，与用途冲突。

代价是明确的：任何以它为基座的生产镜像默认 root。所以这件事在 [SECURITY](../SECURITY.md) 里被写成「已知取舍」而不是漏洞，正确做法是下游自己补：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
RUN adduser -D -u 10001 app
USER app
```

## 新增包的标准

来自 [CONTRIBUTING](../CONTRIBUTING.md) 的硬性规则：新增包要在 PR 里说明「解决什么场景」「增加多少体积」，能 `--no-cache` 的不留缓存。

先量体积再谈必要性（以已装的 `curl` 为例，换成待评估的包名即可）：

```bash
docker build -f .cnb/docker/Dockerfile -t alpine:local .
docker run --rm alpine:local apk info -s curl
docker image ls alpine:local
```

- `apk info -s <pkg>` 给出该包安装后占用的字节数，是「这个包值不值」的直接依据。
- `docker image ls` 的 `SIZE` 是本地占用，与制品库里按平台统计的压缩体积口径不同，报数据时说明用哪个（后者见 [构建元数据](metadata-and-badges.md)）。

改完 Dockerfile 的验证命令：

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest -t alpine:local .
docker run --rm alpine:local sh -c 'cat /etc/apk/repositories; command -v curl nc dig nslookup; date'
docker run --rm alpine:local sh -c 'cat /etc/timezone; readlink -f /etc/localtime'
```

Dockerfile 由 `dockerfmt` 格式化，改完跑 `make format-docker`；CI 不校验格式，但 diff 里的格式噪音会拖慢评审（见 [格式化](formatting.md)）。

## 相关文档

- [文档索引](README.md)
- [APK 源与网络](mirrors.md)
- [快速上手](getting-started.md)
- [构建](build.md)
