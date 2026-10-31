# 快速上手

> 从制品库拉到本地、在容器里把无头浏览器跑通（版本、截图、冒烟）、再把它当成其它镜像的 `FROM` 基座——三步走完，再决定深读哪一篇。

## 镜像里有什么

| 项目     | 值                                                                                                                                             |
|----------|------------------------------------------------------------------------------------------------------------------------------------------------|
| 镜像地址 | `docker.cnb.cool/dtapp/alpine/chromium`                                                                                                        |
| 基础     | 官方 `alpine:latest`（`ALPINE_VERSION` 默认跟随上游，可钉具体补丁版本）                                                                        |
| 平台     | linux/amd64、linux/arm64（多架构 manifest list + 单平台标签并存）                                                                              |
| 变体     | 默认（中性基座）、`-cjk`（带中文字体）、`-headless`（内置无头参数 + tini），命名规则见[镜像与标签](images-and-tags.md)                         |
| 浏览器   | `chromium`，二进制在 `/usr/bin/chromium`；3.24 上是 `155.0.8059.84-r0`，精确版本读 `/usr/share/alpine-chromium/VERSION`                        |
| 依赖     | 显式只装 6 个包（`chromium`、`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`），GTK/Pango/GLib 那 9 个由 `so:` 依赖自动带入 |
| 字体     | `font-freefont` + `fontconfig`，**不含任何 CJK 字形**；要中文用 `-cjk` 变体，见下文「中文页面 / 截图出现方块」                                 |
| 证书     | `ca-certificates`，HTTPS 页面可正常访问                                                                                                        |
| 时区     | `Asia/Shanghai`（`/etc/localtime`、`/etc/timezone` 均已写入，`TZ` 也已导出）                                                                   |
| 用户     | 默认 root；已预置 `chrome`（UID/GID 10001），下游写一行 `USER chrome` 即可切换                                                                 |
| 工作目录 | `/work`，属主 `chrome`                                                                                                                         |
| 体积     | `apk add chromium` 的闭包是 184 个包 / 761 MiB installed（约 303 MiB 下载），具体见 commit 元数据                                              |

镜像内容由 `.cnb/docker/Dockerfile.chromium` 决定，逐段解析见 [Dockerfile 解析](dockerfile.md)。

三点先说清楚，避免后面踩坑：

- **镜像里没有任何排障工具**：不装 `curl`、不装 `netcat-openbsd`（`nc`）、不装 `bind-tools`（`dig`/`nslookup`），也没有 `vim`、`python`、任何应用代码。它是「能跑无头 Chromium 的基座」，不是排障工具箱；探活、抓包请在宿主机侧做，或基于本镜像派生一层再加。
- **体积比纯 alpine 大一个数量级属于预期**：Chromium 本体加 GTK 图形栈就是这个量级，不是构建出错。
- **镜像不内置启动参数**：无头参数由你在运行时给。基础镜像（不带后缀的默认变体）用环境变量 `CHROMIUM_USER_FLAGS` 追加，`-headless` 变体则把一套默认值直接写进镜像。理由见 [Dockerfile 解析](dockerfile.md)。

## 拉取镜像

```bash
# 默认标签，随每天 01:30（Asia/Shanghai）的定时构建更新
docker pull docker.cnb.cool/dtapp/alpine/chromium:latest

# 版本标签只在手动构建时填了 version 才存在
docker pull docker.cnb.cool/dtapp/alpine/chromium:3.24

# 中文页面 / 截图用带字体的变体
docker pull docker.cnb.cool/dtapp/alpine/chromium:latest-cjk

# 在 amd64 机器上取 arm64 的单平台镜像
docker pull --platform linux/arm64 docker.cnb.cool/dtapp/alpine/chromium:latest
```

`latest` 是移动标签，今天拉到的和上周拉到的 digest 不同。需要固定产物时见下文「按 digest 固定拉取」。

注意 `version`（也就是标签里的 `<version>`）是 **Alpine 版本**，不是 Chromium 版本：写 `3.24` 会拿到 `alpine:3.24` 上由该版本仓库决定的 Chromium，改不了 Chromium 主版本。当前 `3.24` 是唯一一个 main 与 community 双支持、支持期到 2028-06 的分支；`3.20` 已于 2026-04 EOL，仓库里冻在 Chromium 131，别拿它当默认。标签的完整清单与命名契约（三个变体 × 多架构 / 单平台）在 [镜像与标签](images-and-tags.md)。

## 快速开始：一条命令跑通截图

```bash
mkdir -p out
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage \
      --hide-scrollbars --window-size=1440,900 \
      --font-render-hinting=none --force-color-profile=srgb" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

`out/page.png` 出现在宿主机当前目录下。参数逐条解释：

| 参数                           | 为什么                                                                                                                |
|--------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `--init`                       | 基础镜像没有 `ENTRYPOINT`，`chromium` 会直接当 PID 1；`--init` 塞一个收尸进程，长期跑的容器不会攒僵尸                 |
| `--shm-size=1g`                | 默认 `/dev/shm` 只有 64MB，渲染重一点的页面直接崩                                                                     |
| `-e CHROMIUM_USER_FLAGS="..."` | 追加启动参数。Alpine 的 `chromium-launcher.sh` 会把它接在 `/etc/chromium/*.conf` 的系统默认值之后，Puppeteer 也吃得到 |
| `-v "$PWD/out:/work" -w /work` | `--screenshot` / `--print-to-pdf` 的路径是容器内路径，挂到 `/work` 才拿得到产物；`/work` 是镜像内置的工作目录         |
| `--virtual-time-budget=10000`  | 给页面最多 10 秒虚拟时间跑到稳态，再截图                                                                              |

`CHROMIUM_USER_FLAGS` 是这套方案里最省事的一环：**一次设好（写进 `docker-compose.yml`、派生镜像的 `ENV`、或部署脚本的 `.env`），后面每条命令都不用再拼参数**。镜像本身不内置参数，但留了这个入口。

几条参数事实，省得你反复试：

- `--no-sandbox` 是 root 下的硬要求，不加直接报 `Running as root without --no-sandbox is not supported`。
- `--headless` 在 Chromium 132+ 就是新版无头，不用再写 `--headless=new`；`--headless=old` 已经不存在（旧无头拆成了独立的 `chrome-headless-shell`）。
- `--disable-gpu` 在新版无头下基本冗余（GPU 栈本来就是 SwiftShader/ANGLE）。要真的用 WebGL/Canvas，装 `chromium-swiftshader`（构建参数 `WITH_SWIFTSHADER=1`，约 5 MiB）再把这条去掉。
- 并发跑多个实例时显式加 `--user-data-dir=/tmp/xxx`：root 且 HOME 属主是 root 时，包装脚本会强塞一个 `$HOME/.config/chromium`，多实例会撞 `SingletonLock`。

## 就想少敲参数：用 `latest-headless`

`-headless` 变体把这些默认值直接写进镜像：`ENV CHROMIUM_USER_FLAGS` 一套固定参数（含 `--user-data-dir=/tmp/chromium-headless`）、`ENTRYPOINT ["/sbin/tini","--"]` 收尸并转发信号、`CMD ["chromium","--version"]`。

```bash
# 不带参数 = 一次冒烟：直接打印 Chromium 版本
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest-headless

# 正常截图：参数已经在镜像里，命令行只剩业务部分
docker run --rm --shm-size=1g \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest-headless \
  chromium --screenshot=/work/page.png https://example.com

# 想覆盖默认值：注意是整体替换，不是追加
docker run --rm \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage --window-size=1920,1080 --user-data-dir=/tmp/chromium-b" \
  docker.cnb.cool/dtapp/alpine/chromium:latest-headless chromium --version

# 想清空默认值（完全自己控制参数）
docker run --rm -e CHROMIUM_USER_FLAGS="" \
  docker.cnb.cool/dtapp/alpine/chromium:latest-headless \
  chromium --headless --no-sandbox --dump-dom about:blank
```

两个要点：

- 覆盖是**整体替换**。默认值里的 `--user-data-dir=/tmp/chromium-headless` 也会一起丢掉，并发场景记得自己补回来。
- 变体已经用 `tini` 当 PID 1，不用再加 `--init`；但 `--shm-size=1g` 仍然建议给。
- 命令行参数仍然要带 `chromium` 这个词：镜像的 `ENTRYPOINT` 是 `tini --`，你写在 `docker run` 末尾的东西会被当作要执行的程序。

## 中文页面 / 截图出现方块

方块不是配置问题，是缺字形：**主镜像里没有任何 CJK 字形**。实测 `font-freefont` 的 12 个 `.otf`（FreeSans 4622 glyphs、FreeSerif 8087 glyphs）里，汉字 / 假名 / 谚文的 cmap 码位都是 0，Chromium 自动带入的 `font-opensans` 同样没有。所以中文页面渲染出来必然是豆腐块，不存在「覆盖有限、常见汉字还行」这回事。

解法是 `-cjk` 变体（构建参数 `WITH_CJK=1`，装 `font-noto-cjk`，比默认变体多 88.8 MiB installed，简繁日韩全覆盖）：

```bash
docker run --rm -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest-cjk \
  chromium --headless --no-sandbox --disable-dev-shm-usage \
  --screenshot=/work/page.png https://example.com
```

验证字体在不在，一条 `fc-list` 就够：

```bash
# -cjk 变体：应列出若干 Noto CJK 字体
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest-cjk fc-list :lang=zh | head

# 默认变体：输出为空，这就是方块的原因
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest fc-list :lang=zh | head
```

想数一下到底有多少条：`fc-list :lang=zh | wc -l`。

两个容易走偏的替代方案：

- `font-noto`（9.0 MiB）**不含 CJK**，别拿它当中文方案。
- `font-wqy-zenhei`（16.3 MiB，仅简体）比 `font-noto-cjk` 省很多，但本仓库**没有做对应变体**，需要你在派生镜像里自己 `apk add`。

字体缓存构建期已经 `fc-cache -f` 过；如果你又挂了自定义字体目录进去，进容器补一次 `fc-cache -fv`。

## 容器内自检（验证清单）

起一个容器，把该验的东西一次跑完：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c '
  cat /etc/alpine-release
  chromium --version
  cat /usr/share/alpine-chromium/VERSION
  echo $CHROME_BIN
  date +%Z
  cat /etc/timezone
  fc-list :lang=zh | wc -l
'
```

每一项对应镜像里的一段设计：

| 命令                                     | 期望结果                      | 验证什么                               |
|------------------------------------------|-------------------------------|----------------------------------------|
| `cat /etc/alpine-release`                | 形如 `3.24.3`                 | 基础版本与 `version` 入参一致          |
| `chromium --version`                     | `Chromium 155.0.8059.84`      | 浏览器本体可执行                       |
| `cat /usr/share/alpine-chromium/VERSION` | 同上，构建期写下的精确版本    | 不用启动浏览器也能查版本               |
| `echo $CHROME_BIN`                       | `/usr/bin/chromium`           | 下游工具链（Puppeteer 等）找得到浏览器 |
| `date +%Z`                               | `CST`                         | `tzdata` 与时区链接生效                |
| `cat /etc/timezone`                      | `Asia/Shanghai`               | 按名字读时区的程序能读到               |
| `fc-list :lang=zh`                       | 默认变体无输出，`-cjk` 有输出 | 中文字形是否具备（条数可接 `wc -l`）   |

光有版本号还不算「能跑」，再补一条渲染冒烟测试——不进网络、不写文件，能打印出 `about:blank` 的 DOM 就说明图形栈与字体链路都还在：

```bash
docker run --rm --shm-size=1g docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank
```

如果 `date +%Z` 显示的是 UTC 而不是 CST，说明容器跑的不是本镜像，或者本地 `-v /etc/localtime:...` 之类的挂载覆盖了镜像内的设置。

## 截图与导出 PDF

挂一个当前目录进去，产物直接落在宿主机：

```bash
mkdir -p out

# 整页截图（参数通过 CHROMIUM_USER_FLAGS 一次性设好）
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage --hide-scrollbars --window-size=1440,900 --font-render-hinting=none --force-color-profile=srgb" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com

# 导出 PDF
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --print-to-pdf=/work/page.pdf https://example.com
```

- `--screenshot` / `--print-to-pdf` 的路径必须是容器内路径，所以与 `-w /work` 配套写。
- `--disable-dev-shm-usage` 让 Chromium 改用 `/tmp` 而不是 `/dev/shm`；和 `--shm-size=1g` 一起给最省心。
- 中文显示成方块：换 `latest-cjk` 变体，不是加参数能解决的，见上文「中文页面 / 截图出现方块」。
- 非 root 运行时注意：`-v "$PWD/out:/work"` 会覆盖镜像里 `/work` 的属主，`USER chrome` 下写不进去，要提前 `chown` 或用 `--user` 传对 UID。

## 作为其它镜像的 FROM 基座

```dockerfile
FROM docker.cnb.cool/dtapp/alpine/chromium:latest

COPY app /usr/local/bin/app
USER chrome
CMD ["/usr/local/bin/app"]
```

- 已经带了浏览器与渲染依赖（`chromium`、GTK/Pango/GLib、字体、`ca-certificates`），下游不必再装一遍；缺的只是你的业务运行时（例如 Node.js 上的 puppeteer/playwright）。`CHROME_BIN` / `CHROME_PATH` / `PUPPETEER_EXECUTABLE_PATH` 已指向 `/usr/bin/chromium`，`PUPPETEER_SKIP_DOWNLOAD=1` 已设，`npm i puppeteer` 不会再自带一份浏览器；需要官方 Chromium 时下游自己覆盖这个变量。
- 想要开箱即用的参数与 tini，把 `FROM` 换成 `latest-headless`；要中文就换 `latest-cjk`。
- 下游自己 `docker buildx build --platform linux/amd64,linux/arm64` 时，buildx 会按目标平台从多架构 manifest list 里挑对应的层，不需要改 `FROM`。
- 默认用户是 root（容器内 root + `--no-sandbox` 是最常见组合）。生产镜像应当在自己的层里补 `USER chrome`，理由见 [Dockerfile 解析](dockerfile.md) 与 [安全基线](security-baseline.md)。
- 制品库若是私有的，先 `docker login docker.cnb.cool` 再拉取。

## 按 digest 固定拉取

标签会移动，digest 不会。要「锁定某次构建的产物」，用 digest 而不是 tag。

取当前 `latest` 的 digest：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --format '{{.Manifest.Digest}}'
```

完整值也可以从 commit 元数据里的 `chromium_image_digest` 读（见 [构建元数据](metadata-and-badges.md)），那是构建当时写下的值。

用 digest 拉取与引用：

```bash
docker pull docker.cnb.cool/dtapp/alpine/chromium@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

```dockerfile
FROM docker.cnb.cool/dtapp/alpine/chromium@sha256:0000000000000000000000000000000000000000000000000000000000000000
```

三点注意：

- `imagetools inspect` 对 `latest` 给出的是多架构 index 的 digest，按它拉取时 docker 会挑当前平台对应的清单，这是正确用法。
- 三个变体各有自己的 digest：固定 `-cjk` 就去取 `latest-cjk` 的 digest，别拿 `latest` 的。
- `latest-linux-amd64` 这类单平台标签现在**直接指向该架构的镜像清单**（由 `docker buildx imagetools create` 从 manifest list 派生），不再带 attestation。拿它统计体积可以直接对层求和，但**跨架构时仍然要用 `latest` 这类多架构标签**——单平台标签里只有那一个架构。

## 下一步读哪篇

| 你的目的                       | 先读                             |
|--------------------------------|----------------------------------|
| 搞清楚镜像每一层是怎么来的     | [Dockerfile 解析](dockerfile.md) |
| 换 APK 源、排查装包慢          | [APK 源与网络](mirrors.md)       |
| 自己构建，或改构建脚本         | [构建](build.md)                 |
| 标签命名、三个变体怎么选       | [镜像与标签](images-and-tags.md) |
| 浏览器起不来、截图是白屏或方块 | [排错手册](troubleshooting.md)   |

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [镜像与标签](images-and-tags.md)
- [README](../../README.md)
