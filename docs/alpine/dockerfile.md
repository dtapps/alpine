# Dockerfile 解析

> 一百来行（六成是注释）、六个构建参数、一个 `FROM`、一个 `RUN`：装包、写时区、清缓存全部压在同一层里（CNB 侧同一层里还会换成腾讯云源），每一段都在为「体积最小 + 构建快 + 可追溯」让路。

## 结构总览

```text
ARG ALPINE_VERSION=latest              → 基座引用，默认跟随上游 latest-stable
FROM alpine:${ALPINE_VERSION}          → 直接站在官方镜像上
ARG ALPINE_VERSION / IMAGE_VERSION / VCS_REF / BUILD_DATE / BASE_DIGEST / APK_INDEX_DIGEST
                                       → FROM 之后重新声明，供装包层与 LABEL 使用
ENV TZ / LANG / LC_ALL                 → 时区与本地化
USER root                              → 有意保留 root，理由写在注释里
RUN  换源（仅 CNB）+ 装包 + 写时区 + 清缓存 → 唯一的一层
LABEL org.opencontainers.image.*（9 个）→ OCI 元数据（放最后，避免污染缓存键）
```

GitHub 侧不换源（官方源在境外最快），`RUN` 里只有装包、写时区、清缓存；其余内容与 CNB 侧一致。结果是「官方 alpine + 1 层」。没有多阶段构建、没有 `scratch`、没有自研二进制，这也是镜像可以被放心当基座的前提。

层数从原来的 4 层降到 1 层不是单纯「合并省事」，取舍写在 [为什么只有一个 RUN](#为什么只有一个-run) 一节；版本策略写在下面的「ARG ALPINE_VERSION」一节。

## ARG ALPINE_VERSION：默认 latest

```dockerfile
ARG ALPINE_VERSION=latest
FROM alpine:${ALPINE_VERSION}
```

- 默认值就是 `latest`，意思很直接：**基座跟随上游 latest-stable，定时任务每天重建就能吃到新补丁、甚至新小版本**。这是一个刻意的选择，不是偷懒——基础镜像的价值有一半在「别人不用自己盯上游」。
- 声明在 `FROM` **之前**，才能被 `FROM` 行引用。写在 `FROM` 之后就只能给 `RUN` 用，改不了基础镜像。
- 用 ARG 而不是把版本直接写进 `FROM`，是为了让「换基础版本」变成一次构建参数，而不是一次代码改动：默认跟随，需要时钉住，两种用法共用同一行。

四种传法对应四种意图（CI 的 `version` 入参白名单与此一致，见 [构建](build.md)）：

| 写法                        | 行为                                  | 什么时候用         |
|-----------------------------|---------------------------------------|--------------------|
| `latest`（默认）            | 每次构建取当时的最新稳定版            | 定时任务、日常刷新 |
| `3.25`                      | 跟随该分支的最新补丁，同 tag 产出会漂 | 想跟补丁但限大版本 |
| `3.25.1`                    | 钉住某个 patch，基座内容不再自动变化  | 需要稳定基线       |
| `3.25.1@sha256:<64 位 hex>` | 位级复现，内容由 digest 决定          | 审计、事故复盘     |

默认跟随上游的代价是「基座会漂」，所以**可追溯与可复现不能靠 Dockerfile 里的版本号，得靠下游三样东西**：①commit 元数据里的 `image_digest`（按 digest 拉取，这是唯一能指回某一份产物的手段）；②镜像 label 里的 `org.opencontainers.image.base.digest`；③commit 元数据里的 `alpine_version` / `base_digest` / `built_at`。它们合起来能回答「那一次构建用的是哪份 alpine、发生在什么时候」，比在文件里写死一个版本号更准确——写死只保证「没升级」，不保证「拉到的还是同一份」。注意标签名虽然就是版本号（如 `3.25.1`），但**每天重建会覆盖同名标签**，所以标签不是复现凭据，见 [镜像与标签](images-and-tags.md)。

要临时钉住时不必改文件，传参即可：

```bash
docker build -f .cnb/docker/Dockerfile.alpine --build-arg ALPINE_VERSION=3.25.1 -t alpine:local .
```

传一个 Docker Hub 上不存在的 tag（例如 `3.99`）会在 `FROM` 阶段直接失败，不会进入后面的 `RUN`；这是最省时间的失败方式。

## 六个 ARG 与 OCI LABEL

```dockerfile
ARG ALPINE_VERSION
ARG IMAGE_VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z
ARG BASE_DIGEST=unknown
ARG APK_INDEX_DIGEST=0
```

- `FROM` 之前声明的 `ARG` 在构建阶段不可见，必须重新声明一次才能拿来填 `LABEL` 或进装包层。这是 Dockerfile 的既有语义，容易漏。
- 五个元数据参数都有安全的默认值：本地随手构建不会因为缺少参数而报错，`dev` / `unknown` / 纪元时间一眼能看出「不是流水线产物」。
- `BASE_DIGEST` 是**当次 `alpine:latest` 的 index digest**，由构建脚本 `imagetools inspect` 解析后传进来。它存在的理由只有一个：`latest` 每天都在动，光有 `base.name="alpine:latest"` 说明不了「这次到底用了哪一份」，加上 digest 才能事后精确指回。本地手搓构建时它会停在 `unknown`，不影响构建。
- `APK_INDEX_DIGEST` 是**装包层的缓存击穿点**：构建脚本先在基座容器里 `apk update`，再对 `/var/cache/apk/APKINDEX.*` 求 `sha256` 传进来。它通过 `echo` 进 `RUN` 的命令文本，索引不变时缓存命中，任何包升级都会让这一层重跑。本地不传时默认 `0`，行为与改造前一致。
- `BUILD_DATE` 语义是**源码时间**，不是「构建时刻」：默认值取 `1970-01-01T00:00:00Z`，CI 里显式传 `git log -1 --format=%cI`（最后一次提交时间）。这样「同一份源码 + 同样的参数」得到同样的镜像 config，`docker image inspect` 的 `created` 字段与 `org.opencontainers.image.created` 标签才可比对；写 `$(date)` 会让每次构建的 config digest 都不同，可复现性当场失效。构建那一刻的时间只写进 `.cnb/annotation.json` 的 `built_at`，**不进镜像**——进镜像就等于把「构建机器上什么时候跑的」烧进产物，而这个信息对镜像使用者没有意义，对可复现性却是致命的。

LABEL 写的是 9 个 OCI 标准键，并且**放在文件最后**：`created` / `revision` / `version` 每次构建都会变，放在 `RUN` 之前会让装包层的缓存键跟着每次提交一起变。好处是可以直接读，不需要解析构建日志：

```bash
docker image inspect alpine:local --format '{{json .Config.Labels}}'
```

| 标签                                   | 取值来源         | 指向什么                        |
|----------------------------------------|------------------|---------------------------------|
| `org.opencontainers.image.source`      | 常量             | 本镜像所在的 CNB 仓库           |
| `org.opencontainers.image.url`         | 常量             | 同上（项目主页）                |
| `org.opencontainers.image.revision`    | `VCS_REF`        | 哪个提交构建的                  |
| `org.opencontainers.image.created`     | `BUILD_DATE`     | 源码时间（最后一次提交）        |
| `org.opencontainers.image.version`     | `IMAGE_VERSION`  | 本产物的版本标签（如 `3.25.1`） |
| `org.opencontainers.image.description` | 常量             | 一句话内容摘要                  |
| `org.opencontainers.image.licenses`    | 常量             | `MIT`                           |
| `org.opencontainers.image.base.name`   | `ALPINE_VERSION` | **基座**是哪个 alpine 引用      |
| `org.opencontainers.image.base.digest` | `BASE_DIGEST`    | **基座**当次的 index digest     |

两个容易搞反的点：

- `source` / `url` 指的是**本镜像**的存放位置（`https://cnb.cool/dtapp/alpine`），不是 Docker Hub 上的 alpine 官方仓库。
- 反过来，`base.name` / `base.digest` 指**基座**，也就是 `FROM` 用的那个 `alpine:${ALPINE_VERSION}` 和它当次的 digest，跟本镜像放在哪没有关系。`base.name` 会原样写成 `alpine:latest`（因为默认就是跟随 latest），真正把「哪一份」钉住的是 `base.digest`。

这套分工正是「基座浮动、产物可追溯」的落点：`latest` 可以天天动，但每个产物都自带「我基于哪个 digest 的 alpine」；事后要按 digest 拉回某一份产物时，`base.digest` 能告诉你当时上游长什么样。

buildx 的 attestation（`--provenance`）里也有这些信息，但它不写进 image config，`docker inspect` 读不到，下游工具链也不一定认。所以「能落成 LABEL 的就落成 LABEL」，attestation 只作为补充。

## 唯一的 RUN：换源、装包、写时区、清缓存

CNB 侧：

```dockerfile
RUN set -eux; \
    echo "apk-index: ${APK_INDEX_DIGEST}"; \
    sed -i 's@dl-cdn.alpinelinux.org@mirrors.cloud.tencent.com@g' /etc/apk/repositories; \
    apk add --no-cache \
        ca-certificates curl drill git netcat-openbsd tzdata; \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
    echo "Asia/Shanghai" >/etc/timezone; \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/* /root/.cache
```

GitHub 侧去掉 `sed` 那一行，直接 `apk add`：GitHub runner 在境外，直连官方源最快，官方镜像默认的 `repositories` 已经包含 `main` + `community`。

| 写法                        | 为什么                                         |
|-----------------------------|------------------------------------------------|
| `echo "apk-index: ..."`     | 把索引指纹写进本层命令文本，值变则缓存失效     |
| `sed` 只替换主机名          | 保留基座自带的两行；上游增删仓库时不用跟着改   |
| `set -eux`                  | 任一条失败即中断；`-x` 让日志留下完整命令      |
| `main` + `community` 各一行 | 本层包都在 `main`，基座保留 `community` 给下游 |
| `apk add --no-cache`        | 自带索引拉取，不需要 `apk update`              |
| 同层装完就删                | 跨层 `rm` 只产生 whiteout，数据照样分发        |

`echo "apk-index: ${APK_INDEX_DIGEST}"` 是缓存键的一部分，不是日志装饰：值一变，BuildKit 就认为这一层要重跑。CI 在构建前用独立容器算好这个值（见 [构建](build.md#缓存与索引指纹)），所以装包层不会因为「命中缓存」而永远装到同一批包。

`apk update` 不在 `RUN` 里，是这一版最容易被问的地方：它的作用是先取一遍 `APKINDEX`，但 `apk add --no-cache` 自己就会取索引，而且用完即弃、不落盘。先 `apk update` 再 `apk add`，等于把同一批索引下载两遍——在「构建快」这个目标上纯属自找开销。CI 需要索引指纹时，会在**另一个一次性容器**里跑 `apk update`，不影响镜像层。源配置写错的症状也不会因此变难查：`apk add` 报的第一个错就带着出错仓库的 URL，源不可达时会先打 `WARNING`、全部源都失败才退出（见 [APK 源与网络](mirrors.md)），所以看日志要留意 `WARNING` 而不是只看退出码。

`sed` 不匹配时就地跳过，文件保持官方源，构建仍能完成；这是刻意留的降级路径，而不是让换源失败拖垮整个构建。

## 包选择清单

| 包                | 安装     | 净增     | 为什么需要                            |
|-------------------|----------|----------|---------------------------------------|
| `ca-certificates` | 0.20 MiB | 0.20 MiB | HTTPS 校验的基础，`curl` 与下游都依赖 |
| `curl`            | 0.27 MiB | 5.06 MiB | 调 HTTP/HTTPS 接口、探活              |
| `drill`           | 0.06 MiB | 0.40 MiB | DNS 排查，`dig` 的轻量替代            |
| `git`             | 6.71 MiB | 7.63 MiB | 克隆代码、拉取依赖                    |
| `netcat-openbsd`  | 0.04 MiB | 0.16 MiB | `nc -zv host port` 探端口             |
| `tzdata`          | 0.43 MiB | 0.43 MiB | `Asia/Shanghai` 时区数据              |

单位 MiB；「安装」是该包自身的安装体积，「净增」是把它的依赖闭包一起装进来后镜像增加的量（数据来自 Alpine v3.24 官方 APKINDEX，取数 2026-10-31）。基线 `alpine:3.24.3` 自身安装约 8.02 MiB（压缩 3.53 MiB），六个包净增合计约 13.9 MiB。基座现在跟随上游，小版本升级后这些数字会有小幅变化，但不影响量级与取舍判断。

六个包的选择标准是同一句话：**进容器就能定位问题、拉代码**。HTTP、端口、DNS 三条链路各有一个工具，再加 git、证书与时区，覆盖了绝大多数「服务连不上」「代码拉不下来」的排查路径。

注意「安装」和「净增」差得远的那一行：`curl` 自身只有 0.27 MiB，但它拖来了 `libcurl`、`nghttp2-libs`、`brotli-libs`、`zstd-libs`、`libidn2`、`libunistring` 一串依赖，实际代价 5.06 MiB。评估「要不要加某个包」时只看单包体积会严重低估，必须看闭包。

`--no-cache` 让装完的 `.apk` 文件不留在 `/var/cache/apk`，等价于「装完立刻清」；这也正是 `apk update` 没有存在必要的原因之一。

## 为什么是 drill 而不是 bind-tools

旧版本装的是 `bind-tools`（`dig`、`host`、`nslookup`），现在换成 `drill`。原因只有一个：体积。

| 方案         | 含依赖净增 | 提供的命令                 |
|--------------|------------|----------------------------|
| `drill`      | 0.40 MiB   | `drill`（语法接近 `dig`）  |
| `bind-tools` | 7.13 MiB   | `dig`、`host`、`nslookup`  |
| 不装         | 0          | 只剩 busybox 的 `nslookup` |

`bind-tools` 的依赖闭包有 17 个包，占旧镜像体积的 34%，而这些依赖里大部分是 `dnssec`、`geoip` 之类做权威解析才需要的东西——一个用来「查一下域名解析对不对」的基础镜像显然不需要。

三个必须写清楚的前提：

- **`drill` 不是 `dig` 的同名替代**。命令名就是 `drill`，`dig` 不存在。任何写死 `dig +short example.com` 的脚本、健康检查、CI 步骤，换到本镜像上都会 `command not found`。排查用法要写成 `drill example.com`，要只看解析出来的地址就从 `ANSWER SECTION` 里过滤。
- **busybox 自带的 `nslookup` 解决不了全部场景**。它够用来判断「解析得到 / 解析不到」，但没有 `dig`/`drill` 那样的记录类型选择、追踪整个解析链、看 TTL 与 authority 段的能力。要区分「DNS 配错」和「DNS 上游慢」，还是得有 drill。
- **真要 `dig` 就换回 `bind-tools`**，代价约多 6.6 MiB（其独立闭包 7.13 MiB，其中一部分依赖已由 `curl` 引入）。这一步相当于把镜像体积增加近一半，加之前先问一句「这个容器里真的需要按 `dig` 语法出输出吗」。

另外 `netcat-openbsd` 是刻意保留的：busybox 自带 `nc`，但不支持 `-z`，`nc -zv host port` 这条最常用的端口探活命令会直接失败。为 0.16 MiB 省掉一个每天都在用的排查手段不划算。

## ENV：时区与本地化

```dockerfile
ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
```

- `TZ` 只对「主动读这个环境变量」的程序生效（glibc/musl 的 `tzset()`、Java、Go 的部分实现都读）。它不能替代 `tzdata`：musl 的 `tzset()` 仍然要去 `/usr/share/zoneinfo` 找时区文件。所以 `ENV TZ`、`ln -sf .../Asia/Shanghai /etc/localtime`、`/etc/timezone` 三者是配套的，缺一个就会有一部分程序按 UTC 走。
- `ln -sf` 里 `-s` 建符号链接、`-f` 在目标已存在时覆盖（基础镜像自带的 `/etc/localtime` 是普通文件）。`/etc/timezone` 是纯文本时区名，给按名字读时区的程序用。
- 写时区必须和装 `tzdata` 同层：`ln -sf` 的目标由 `tzdata` 提供，同一层里顺序天然正确；跨层且顺序写反，只会得到一个悬空符号链接——`date` 照旧输出 UTC，命令一条都不报错，属于最难查的一类问题。
- `LANG` / `LC_ALL` 写成 `C.UTF-8` 而不是 `en_US.UTF-8`：musl 只支持 `C.UTF-8`。写 `en_US.UTF-8` 不会报错、只会静默不生效，然后某个程序在遇到非 ASCII 字符时给出莫名其妙的行为。基础镜像不去假装自己有完整 locale，比装一整套 locale 数据（几十 MiB）更符合「体积小」的目标。

## USER root 这一取舍

镜像不创建非 root 用户，并且显式写了 `USER root`。显式写出来的意义是「这是一个决定，不是遗漏」：读 Dockerfile 的人不用去猜是不是忘了降权。

理由：它是**基础调试镜像**，进容器就要能 `apk add`、改配置、连端口；一上来套 `USER`，第一件事就卡在权限上，与用途冲突。

代价是明确的：任何以它为基座的生产镜像默认 root。所以这件事在 [SECURITY](../../SECURITY.md) 里被写成「已知取舍」而不是漏洞，正确做法是下游自己补：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
RUN adduser -D -u 10001 app
USER app
```

另外两件「不做」的事写在同一段注释里：不设 `WORKDIR`（基础镜像设了会被所有下游继承，等于替别人决定工作目录），不设 `ENTRYPOINT` / `CMD` / `HEALTHCHECK`（同样是替下游决定启动方式，基础镜像只提供工具与运行时）。用户要什么由下游镜像自己声明。

## 为什么只有一个 RUN

旧版本是四个 `RUN`：换源、装包、tzdata、清理。分成多层的好处是缓存粒度——层的缓存键由「本层指令 + 上层内容」算出，改时区只重建它之后的层，装包层继续命中缓存。这个好处在理论上是真的，在这个仓库的实际情况里却不成立：

- **改动的频率不对称**。这个 Dockerfile 一年改几次，改的内容基本都是包列表或源；「只想调时区、不动包列表」这种场景没有发生过。为几乎不存在的缓存收益付出四层的代价，方向就反了。
- **多一层就多一次索引往返**。每层的 `apk` 调用都要为 `/etc/apk/repositories` 里的仓库取一次 `APKINDEX`。四层就是四轮；合成一层后只剩一轮。索引是纯网络往返，在 CI 上是实打实的秒级开销。
- **装包本身很快**。六个包净增合计约 13.9 MiB，压缩后更小，全部装完只需要数秒。真正拖时间的是「下载索引」和「拉基础镜像」，不是解包这些包。留着一个专门装 `tzdata` 的层，省下的那点解包时间还不够它自己多一轮索引的开销。
- **层数本身就是成本**。每层有独立的 metadata（层的 config、diff id、tar 头），层数越多，镜像清单越大、拉取时的请求数越多；对「一天被拉很多次」的基础镜像，这是复利成本。

所以现在的取向是：**一次 `RUN` 把事做完**。代价是「改包列表会连带重建时区」，但时区那几条命令是纯本地操作，重跑没有网络开销，可以忽略。

跨轮次缓存也建立在这个单层结构上：CI 把 APK 索引指纹作为 `APK_INDEX_DIGEST` 传进来并 `echo` 在本层，索引不变时整层命中，任何包升级时整层重跑。这样「单层」不再意味着「每次都必须重装」，也不再意味着「缓存命中后装不到新包」。机制见 [缓存实现](../cache-implementation.md)。

## 清理为什么必须与安装同层

机制：Docker 每个 `RUN` 产出一层只读增量，层只增不减。在后一层 `rm` 掉前一层写进去的文件，只是在后一层记一条 whiteout，前一层的数据照样随镜像分发，体积一两不少。

「清理必须单独放在最后一层」这个旧结论只对了一半——放在最后一层确实避免了「新层被清掉」的荒谬情况，但只要清理和安装不在同一层，被删的东西就还在镜像里。正确的规则是把两件事绑在同一个 `RUN` 里：

- **同一个层里装完就删**才有意义。本镜像主要靠 `apk add --no-cache` 让缓存根本不落盘，末尾的 `rm -rf` 是兜底，负责 `/tmp`、`/root/.cache`、`/var/tmp` 这类零散残留。
- **新增 `RUN` 要么并入这一层，要么自带同层清理**。这是 [CONTRIBUTING](../../CONTRIBUTING.md) 里写明的规则。单独加一个「清理层」不再是允许的做法，因为它清不掉任何东西。

本地确认层结构：

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .   # 默认跟随上游 latest
docker history alpine:local
```

要钉住基座时再传参：`--build-arg ALPINE_VERSION=3.25.1`（或带 digest）。

`docker history` 里除了基础镜像自带的层，只应该多出一层，它同时包含换源、装包与清理。如果多出了第二层，说明清理或某个步骤被拆了出去。

## 新增包的标准

来自 [CONTRIBUTING](../../CONTRIBUTING.md) 的硬性规则：新增包要在 PR 里说明「解决什么场景」「增加多少体积」，能 `--no-cache` 的不留缓存。

先量体积再谈必要性（以已装的 `curl` 为例，换成待评估的包名即可）：

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .
docker run --rm alpine:local apk info -s curl
docker image ls alpine:local
```

- `apk info -s <pkg>` 给出该包安装后占用的字节数，是「这个包值不值」的直接依据。
- 单包体积不等于镜像增量，依赖闭包才是；`apk add --simulate` 或本页的净增列可以看出真实代价。
- `docker image ls` 的 `SIZE` 是本地占用，与制品库里按平台统计的压缩体积口径不同，报数据时说明用哪个（后者见 [构建元数据](metadata-and-badges.md)）。

改完 Dockerfile 的验证命令：

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .
docker run --rm alpine:local sh -c 'cat /etc/apk/repositories; command -v curl nc drill git nslookup'
docker run --rm alpine:local sh -c 'cat /etc/timezone; readlink -f /etc/localtime; date +%Z'
docker image inspect alpine:local --format '{{json .Config.Labels}}'
```

倒数三条命令依次验证：源是 `main` + `community` 两行（CNB 主机是腾讯云，GitHub 是官方）、五个工具都在（注意是 `drill`，不是 `dig`）；时区三件套配套生效；`LABEL` 字段填对。

Dockerfile 由 `dockerfmt` 格式化，改完跑 `make format-docker`；CI 不校验格式，但 diff 里的格式噪音会拖慢评审（见 [格式化](formatting.md)）。

## 相关文档

- [文档索引](index.md)
- [APK 源与网络](mirrors.md)
- [快速上手](getting-started.md)
- [构建](build.md)
