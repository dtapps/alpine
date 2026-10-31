# Dockerfile 解析

> 两个 Dockerfile：主文件产出中性基座（换源 → 装包 → 环境变量 → 预置用户 → OCI 标签），`Dockerfile.headless` 在它之上叠一层，把默认无头参数与 tini 固化。每一段都对应一个具体的失败模式。

## 结构总览

```text
ARG ALPINE_VERSION=latest        → 构建参数：Alpine 版本（不是 Chromium 版本），默认跟随上游
FROM alpine:${ALPINE_VERSION}    → 官方 Alpine
RUN  换源                          → 第 1 层：改写 /etc/apk/repositories
RUN  装包 + 时区 + 字体缓存 + 版本断言 + 同层清理 → 第 2 层：体积全在这里
ENV  TZ / LANG / LC_ALL           → 环境变量：不占层体积
ENV  CHROME_BIN / PUPPETEER_*     → 环境变量：给下游工具链用
RUN  adduser chrome + /work       → 第 3 层：预置非 root 用户与挂载点
WORKDIR /work
LABEL …                           → OCI 元数据：不占层体积
```

`Dockerfile.headless` 再叠两层：`ENV CHROMIUM_USER_FLAGS` + `ENTRYPOINT ["/sbin/tini","--"]`。

镜像会到「数百 MB」量级，这是 Chromium 的依赖闭包带来的：Alpine 3.24 上 `apk add chromium` 实测 **184 个包 / 761 MiB installed**。具体数字看 commit 元数据里的 `chromium_image_size`（见 [构建元数据](metadata-and-badges.md)）。

## ARG ALPINE_VERSION：默认跟随上游，可钉具体版本

```dockerfile
ARG ALPINE_VERSION=latest
FROM alpine:${ALPINE_VERSION}
```

- 声明在 `FROM` **之前**才能被 `FROM` 引用；写在后面就只能给 `RUN` 用。
- 默认 `latest`，跟随上游最新稳定版；定时任务每天重建自动吃到新补丁。需要复现某次构建时，显式钉具体补丁版本（如 `--build-arg ALPINE_VERSION=3.24.3`）。
- 这个参数是 **Alpine 版本**，不是 Chromium 版本。Chromium 装哪个由该分支的软件包仓库决定。

关键机制：`chromium` 在 **community** 仓库，而 Alpine 的 community 只维护到「下一个 stable 发布」。所以每个分支的 Chromium 会**冻住**：

| 分支     | 仓库里的 chromium    | 最后更新                        | 分支支持到                                |
|----------|----------------------|---------------------------------|-------------------------------------------|
| 3.20     | 131.0.6778.108-r0    | 2024-12-07                      | 2026-04（已 EOL）                         |
| 3.21     | 136.0.7103.113-r0    | 2025-05-17                      | 2026-11                                   |
| 3.22     | 142.0.7444.59-r0     | 2025-11（143 被 revert 回 142） | 2027-05                                   |
| 3.23     | 149.0.7827.53-r0     | 2026-06-06                      | 2027-11                                   |
| **3.24** | **155.0.8059.84-r0** | 2026-10-20                      | **2028-06（唯一 main+community 双支持）** |

这就是为什么不能长期停在老分支：`alpine:3.21` 里的浏览器是 2025 年 5 月的版本，浏览器 CVE 只能等换分支才修得掉。

`apk` 装的 chromium **无法钉版本**——同一分支只保留最新一个 `-rN`，钉死 `chromium=155.0.8059.84-r0` 会在 `-r1` 发布当天构建失败。所以：

- 钉 **Alpine 分支/补丁版本**；
- 用 `EXPECTED_CHROMIUM_MAJOR` 断言主版本，漂移时构建直接失败；
- 把实际版本写进 `/usr/share/alpine-chromium/VERSION` 与 CI 元数据的 `chromium_version`。

需要字节级复现时，把 `FROM` 换成 digest 形式：

```dockerfile
FROM alpine:3.24.3@sha256:<digest>
```

本地覆盖版本：

```bash
docker build -f .cnb/docker/Dockerfile.chromium --build-arg ALPINE_VERSION=3.24.3 -t alpine-chromium:local .
```

构建老分支时要一起改断言，否则会被拦下：

```bash
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg ALPINE_VERSION=3.23 --build-arg EXPECTED_CHROMIUM_MAJOR=149 \
  -t alpine-chromium:local .
```

## STEP 1：换源

```dockerfile
RUN ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release) \
    && printf '%s\n' \
        "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/main" \
        "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/community" \
        "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" \
        "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" \
        >/etc/apk/repositories
```

| 写法                                     | 为什么                                                                                            |
|------------------------------------------|---------------------------------------------------------------------------------------------------|
| `cut -d. -f1,2` 取 `/etc/alpine-release` | 文件是 `3.24.3`，仓库路径只要 `v3.24`；用标签拼不出 URL                                           |
| `printf` + `>` 覆写                      | 一次性写出完整源列表，不残留基础镜像自带的官方源                                                  |
| 只留两组（国内镜像 + 官方兜底）          | 原先五站十行会让 apk 在不同同步进度的仓库间混用，容易撞依赖版本冲突，也多打好几次网络请求         |
| 不再单独 `apk update`                    | `apk add --no-cache` 自己会拉索引；源不可达会在装包层立刻报错，多一个 update 层只是多一次索引下载 |

## STEP 2：包清单与版本断言

```dockerfile
RUN echo "cache-bust: ${CACHE_BUST}" \
    && apk add --no-cache chromium ca-certificates font-freefont fontconfig tzdata tini \
    && if [ "$WITH_CJK" = "1" ]; then apk add --no-cache font-noto-cjk; fi \
    …
```

（文件里为了 diff 可读是一个包一行；`if` 用来挂变体依赖。）

只显式要 6 个包，其余 9 个由 `chromium` 的 `so:` 依赖自动带入：

| 包                | 作用                                                     | 在 chromium 闭包里？             |
|-------------------|----------------------------------------------------------|----------------------------------|
| `chromium`        | 无头浏览器本体                                           | —                                |
| `ca-certificates` | 根证书，HTTPS 必需                                       | 否                               |
| `font-freefont`   | 拉丁/符号字体                                            | 否                               |
| `fontconfig`      | 字体发现与匹配，`fc-list`/`fc-match`/`fc-cache` 都在这里 | 是（显式保留以表达「必需能力」） |
| `tzdata`          | 时区数据                                                 | 否                               |
| `tini`            | PID 1 收尸 + 信号转发，23 KiB                            | 否                               |

自动带入、不再逐行声明的 9 个：`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig`。**它们不是被删掉的依赖**，而是 `apk` 本来就会装：显式写出来不增体积，删掉也不减体积。

> `fontconfig` 在上面两个清单里各出现一次，不是笔误：它确实在闭包内，显式写出来是为了把「字体发现与匹配是必需能力」标进依赖声明，而不是默认它能一直被间接带入。

### 体积在哪里，为什么「清理」不是体积手段

| 包                                | installed       | 从哪条链进来                                                            |
|-----------------------------------|-----------------|-------------------------------------------------------------------------|
| `chromium`                        | 313.6 MiB       | 本体                                                                    |
| `llvm22-libs`                     | 182.1 MiB       | `chromium → pipewire-libs → libcamera → mesa-gles → mesa → llvm22-libs` |
| `mesa`                            | 42.1 MiB        | 同上（软件 GL/llvmpipe）                                                |
| `icu-data-full`                   | 31.6 MiB        | chromium 直接依赖                                                       |
| `x265-libs` / `ffmpeg-libavcodec` | 20.4 / 19.4 MiB | `ffmpeg-libavformat`                                                    |

`llvm` 那 182 MiB 是 `so:` 链带进来的，删了浏览器起不来。可剥离内容基本为零：locale 是独立包 `chromium-lang`（49.5 MiB，**默认不装**），文档是 `chromium-doc`（2 KB），调试符号是 `chromium-dbg`（277 MiB，不装）。所以本层末尾的 `rm -rf` 只是兜底，真正的体积控制在「装什么」，不在「清什么」。

### 中文字体

`font-freefont` **不含任何 CJK 字形**：实测 12 个 `.otf` 的 `cmap` 里汉字/假名/谚文码位全部为 0，Chromium 自动带入的 `font-opensans` 也没有。所以主镜像渲染中文**一定是豆腐块**，不是「覆盖有限」。

要中文就构建 `-cjk` 变体（`WITH_CJK=1`，装 `font-noto-cjk`，+88.8 MiB）；只做简体截图的下游可以自己换更省的 `font-wqy-zenhei`（16.3 MiB，本仓库未内置）。

```bash
docker run --rm alpine-chromium:local-cjk sh -c 'fc-list :lang=zh | head -3'
```

### 版本断言与同层清理

```dockerfile
    && mkdir -p /usr/share/alpine-chromium \
    && chromium --version >/usr/share/alpine-chromium/VERSION \
    && cat /usr/share/alpine-chromium/VERSION \
    && if [ "$EXPECTED_CHROMIUM_MAJOR" != "any" ]; then
         case "$(awk '{print $2}' /usr/share/alpine-chromium/VERSION)" in
           "${EXPECTED_CHROMIUM_MAJOR}".*) ;;
           *) echo "❌ 主版本漂移"; exit 1 ;;
         esac
       fi \
    && rm -rf /var/cache/apk/* /tmp/* /var/tmp/* /root/.cache /root/.config/chromium
```

- 构建期跑一次 `chromium --version`：既写出可查的版本文件，也顺便证明二进制能起来（`--version` 在沙箱初始化之前就退出，root 下也能跑）。
- 主版本对不上就失败，避免「镜像内容悄悄换了但没人发现」。定时任务某天变红通常就是上游换大版本了。
- 清理必须和安装**同一个 `RUN`**：跨层 `rm` 只是 whiteout，前一层的数据照样随镜像分发。

## STEP 3：时区与本地化

```dockerfile
ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
```

`tzdata` + `ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime` + `/etc/timezone` 解决系统调用，但 Node / Python / glib 系程序读的是 `TZ` 环境变量——不给就会出现「`date` 是 CST、日志是 UTC」。

`LANG=C.UTF-8` 是 musl 的默认值，写出来是为了让上层应用看得见；`en_US.UTF-8` 在 musl 下拿不到 glibc 语义（排序、数字格式、翻译），不要为此装 glibc。真正影响页面语言的是 Chromium 的 `--lang`。

## STEP 4：下游工具链环境变量

```dockerfile
ENV CHROME_BIN=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1
```

- `/usr/bin/chromium` 是 Alpine 的包装脚本，转调 `/usr/lib/chromium/chromium` 并附加 `CHROMIUM_FLAGS`；指向它而不是真实二进制，`CHROMIUM_USER_FLAGS` 才生效。
- `PUPPETEER_SKIP_DOWNLOAD=1` 让派生镜像 `npm i puppeteer` 时不再下载一份浏览器（省约 300 MB 和一次网络）。想用官方 Chromium 的下游自行覆盖这个变量。

## STEP 5：预置用户与目录

```dockerfile
RUN addgroup -g 10001 chrome \
    && adduser -D -u 10001 -G chrome -h /home/chrome -s /sbin/nologin chrome \
    && mkdir -p /home/chrome /work \
    && chown chrome:chrome /home/chrome /work

WORKDIR /work
```

**默认 `USER` 仍然是 root**——容器内 root + `--no-sandbox` 是无头 Chromium 的常见组合，这个取舍没变（见下方「root 用户这一取舍」）。这里只是把下游写一行 `USER chrome` 需要的东西先备好。

`WORKDIR /work` 让输出/下载有统一落点：`docker run -v "$PWD/out:/work" -w /work` 不用每次指定工作目录。注意挂载会覆盖属主，非 root 用户写宿主机目录会 permission denied。

`/tmp` 在 Alpine 里已是 1777，`--disable-dev-shm-usage` 落盘没问题；`--read-only` 容器要自己 `--tmpfs /tmp:rw,size=1g`。

## STEP 6：OCI 元数据

```dockerfile
LABEL org.opencontainers.image.title="alpine-chromium" \
      org.opencontainers.image.source="https://cnb.cool/dtapp/alpine" \
      org.opencontainers.image.version="${ALPINE_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="docker.io/library/alpine:${ALPINE_VERSION}" \
      dev.alpine-chromium.cjk="${WITH_CJK}"
```

`created` / `revision` 由 CI 传 `--build-arg`，本地直接 `docker build` 时是 `unknown`。Chromium 的精确版本放不进 `LABEL`（构建期拿不到），所以落在 `/usr/share/alpine-chromium/VERSION`，并由 CI 写进 commit 元数据。

## 变体：同一份 Dockerfile 的三副面孔

| 变体        | 开关                           | 差异                                                                                          | 代价             |
|-------------|--------------------------------|-----------------------------------------------------------------------------------------------|------------------|
| default     | —                              | 中性基座，不含任何启动参数                                                                    | —                |
| `-cjk`      | `WITH_CJK=1`                   | 多 `font-noto-cjk`                                                                            | +88.8 MiB        |
| `-headless` | 独立文件 `Dockerfile.headless` | `ENV CHROMIUM_USER_FLAGS` + `ENTRYPOINT ["/sbin/tini","--"]` + `CMD ["chromium","--version"]` | ≈0（共用基础层） |

另外两个按需开关不进默认构建：`WITH_CHROMEDRIVER=1`（+17.5～28.4 MiB，配 Selenium）、`WITH_SWIFTSHADER=1`（+约 5 MiB，要 WebGL/Canvas）。

变体策略的理由：`-cjk` 只是多装一个包，用构建参数就够；`-headless` 要改 `ENTRYPOINT`/`CMD`，而这两个指令无法用 `ARG` 条件化，所以单独一份很短的 Dockerfile，`FROM` 同一批次的 default 镜像（CI 里用 digest 钉住）。

## 无头启动参数为什么不写进主镜像

`--no-sandbox` 取决于是否 root，`--disable-dev-shm-usage` 取决于 `/dev/shm` 多大——只有跑容器的人知道。[CONTRIBUTING](../../CONTRIBUTING.md) 因此禁止把它们写进主镜像的 `ENTRYPOINT` 或包装脚本。

推荐做法是用环境变量追加。Alpine 的 `chromium-launcher.sh` 会 `source /etc/chromium/*.conf`，再把 `CHROMIUM_USER_FLAGS` 接在系统默认值之后：

```bash
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage \
      --hide-scrollbars --window-size=1440,900 \
      --font-render-hinting=none --force-color-profile=srgb" \
  -v "$PWD/out:/work" -w /work alpine-chromium:local \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

几个参数的事实（Chromium 132 起）：

- `--headless` **就是新版无头**；`--headless=new` 等价但多余，`--headless=old` 已失效（旧无头拆成独立的 `chrome-headless-shell`）。
- 新版无头会自动加 `--ozone-platform=headless`、`--use-angle=swiftshader`、`--no-first-run`。
- `--no-zygote` 只在配 `--no-sandbox` 时有意义，无头不需要；`--single-process` 是调试开关，会随机崩。两者都别用。
- `--disable-gpu` 在新版无头下基本冗余；要 WebGL/Canvas 就装 `chromium-swiftshader` 并去掉它。
- root + root 属主 HOME 时包装脚本会强塞 `--user-data-dir=$HOME/.config/chromium`，并发实例会撞 `SingletonLock`——显式传 `--user-data-dir=/tmp/xxx`。

想彻底省掉这串参数就用 `-headless` 变体（它已内置同样的值 + tini 当 PID 1 + 独立的 `--user-data-dir`），要清空默认值用 `-e CHROMIUM_USER_FLAGS=""`。

## root 用户这一取舍

镜像不把 `USER` 切换成非 root。理由是它服务于无头浏览器：容器内以 root 运行时 Chromium 的沙箱本来就用不了，启动必须显式带 `--no-sandbox`；先把用户固定成 root，等于把「谁来负责沙箱」留给使用方，而不是在镜像里做半吊子决定。

代价是明确的：任何以它为基座的生产镜像默认 root，所以 `SECURITY.md` 把它写成「已知取舍」而不是漏洞。正确做法是下游自己补：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine/chromium:latest
USER chrome          # 镜像已预置 uid/gid 10001、家目录 /home/chrome、WORKDIR /work
```

换成非 root 后，若宿主允许 unprivileged user namespace（或给容器 `--cap-add=SYS_ADMIN`），`--no-sandbox` 就可以去掉。`No usable sandbox!` 是另一回事：userns 与 SUID helper（Alpine 的 `chrome-sandbox` 是 4755）都不可用时才会出现。

## 新增包的标准

来自 [CONTRIBUTING](../../CONTRIBUTING.md) 的硬性规则：新增包要在 PR 里说明「解决什么场景」「增加多少体积」，能 `--no-cache` 的不留缓存。

先量体积再谈必要性：

```bash
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
docker run --rm alpine-chromium:local apk info -s chromium
docker image ls alpine-chromium:local
```

- 加「运行时才需要」的包（chromedriver、swiftshader、CJK 字体）优先做成 `WITH_*` 开关，别默认装。
- 需要编译的依赖不许进主镜像：用 `apk add --virtual .build-deps … && apk del .build-deps`（必须同一个 `RUN`）或多阶段构建。本镜像当前没有任何编译步骤，所以看不到 `--virtual`。
- `apk info -s <pkg>` 给出安装后占用，是「值不值」的直接依据。

## 改完怎么验证

```bash
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
docker run --rm alpine-chromium:local sh -c \
  'cat /etc/apk/repositories; chromium --version; date +%Z; echo $CHROME_BIN'
docker run --rm alpine-chromium:local sh -c \
  'cat /etc/timezone; readlink -f /etc/localtime; ls -l /usr/bin/chromium'
docker run --rm --shm-size=1g alpine-chromium:local \
  chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank
```

最后一条是渲染冒烟：不进网络、不写文件，能打印出 `about:blank` 的 DOM 就说明浏览器本体与图形依赖都还在。动了字体就再验一次 `fc-list :lang=zh`（`-cjk` 变体）。

Dockerfile 由 `dockerfmt` 格式化，改完跑 `make format-docker`；CI 不校验格式，但 diff 里的格式噪音会拖慢评审（见 [格式化](formatting.md)）。

## 相关文档

- [文档索引](README.md)
- [APK 源与网络](mirrors.md)
- [快速上手](getting-started.md)
- [构建](build.md)
