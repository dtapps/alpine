# Alpine + Chromium 基础镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security) ![基础镜像](https://img.shields.io/badge/base-alpine-0d597f?logo=alpinelinux&logoColor=white) ![浏览器](https://img.shields.io/badge/browser-chromium-4285f4?logo=googlechrome&logoColor=white) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![时区](https://img.shields.io/badge/timezone-Asia%2FShanghai-success) ![镜像大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_size) ![arm64 大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_size_arm64) ![Chromium 版本](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_version) ![镜像摘要](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_digest_short)

基于 Alpine 自建的 Chromium 镜像。镜像由 CNB 流水线自动构建并推送到制品库，供其它项目作为「容器内跑无头浏览器」的基础镜像（截图、PDF 导出、页面渲染、E2E 测试等）。

> **本文档位置**：Alpine 基础镜像与 Chromium 镜像现在同仓库维护（`dtapp/alpine`），两套 Dockerfile 与流水线各自独立，但 **Chromium 以本仓库构建的 Alpine 基础镜像为基座**。本目录是 Chromium 镜像的分册文档，索引见 [index.md](index.md)；Alpine 基础镜像的文档在 [`docs/alpine/`](../alpine/index.md)。 下文命令里的镜像地址已更新为合并后的 `docker.cnb.cool/dtapp/alpine/chromium`。

## 镜像里有什么

- 基座：本仓库的 Alpine 基础镜像 `docker.cnb.cool/dtapp/alpine:<Alpine 版本>`（CI 按 `version` 选基座标签、读出实际版本后再取该版本标签的 digest 构建；`latest` 由每天 `00:05` 的基座构建产出）。Dockerfile 的默认基座是官方 `alpine:${ALPINE_VERSION}`，只用于不依赖私有仓库的本地构建
- 继承自基座：`ca-certificates`、`curl`、`drill`、`git`、`netcat-openbsd`、`tzdata`；容器内可直接用 `curl` / `nc` / `drill` 探活、用 `git` 拉代码。仍不含 `bind-tools`（`dig`）、`vim`、`python` 与应用代码
- APK 源：CNB 侧覆写为腾讯云的 `main` + `community`（`chromium` 在 community）；GitHub 侧沿用官方默认的 `main` + `community`，不换源
- 浏览器主程序：`chromium`（Alpine 官方包，二进制位于 `/usr/bin/chromium`）
- Chromium 运行所需图形/渲染依赖：`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig` —— 这些由 `chromium` 的 `so:` 依赖**自动带入**，不需要显式声明；显式写出来不增体积、删掉也不减体积
- 显式 `apk add` 的只有闭包里没有的那几个：`chromium`、`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`
- 字体：`font-freefont` + `fontconfig`，只覆盖拉丁与常见符号。**镜像不含任何 CJK 字形，截中文网页一定是豆腐块**；需要中文请用 `--build-arg WITH_CJK=1` 自行构建（+88.8 MiB），或在派生镜像里 `apk add font-noto-cjk`
- 预置非 root 用户 `chrome`（UID/GID `10001`、家目录 `/home/chrome`）与 `WORKDIR /work`；默认 `USER` 仍是 root
- 时区固定为 `Asia/Shanghai`（`/etc/localtime` 与 `/etc/timezone` 均已写入）
- 构建末尾清理 `/var/cache/apk`、`/tmp`、`/root/.cache`、`/var/tmp`

注意：本镜像**只提供浏览器与它继承/安装的依赖**。`curl`、`drill`、`git`、`netcat-openbsd` 来自 Alpine 基座，可以直接在容器内探活、拉代码；仍不装 `bind-tools`（`dig`）、`vim`、`python`，也不带任何应用代码。镜像体积比纯 alpine 基础镜像大一个量级（数百 MB），属于预期。

Dockerfile 位于 `.cnb/docker/Dockerfile.chromium`；`-headless` 只是本地派生用的配方 `.cnb/docker/Dockerfile.headless`，CI 不发布。

### 为什么基础版本必须跟着 Alpine 走

`chromium` 在 Alpine 的 **community** 仓库，而 community 只维护到「下一个 stable 发布」，所以每个分支里的 chromium 会**冻住**：

| 分支     | chromium            | 最后更新                               | 分支支持到                                  |
|----------|---------------------|----------------------------------------|---------------------------------------------|
| 3.20     | `131.0.6778.108`    | 2024-12（已 EOL，浏览器 CVE 无从修起） | 2026-04                                     |
| 3.21     | `136.0.7103.113`    | 2025-05                                | 2026-11                                     |
| 3.22     | `142.0.7444.59`     | 2025-11                                | 2027-05                                     |
| 3.23     | `149.0.7827.53`     | 2026-06                                | 2027-11                                     |
| **3.24** | **`155.0.8059.84`** | 2026-10                                | 2028-06（当前唯一 main + community 双支持） |

要浏览器 CVE 修得掉，基础分支就得跟着走；定时任务每天传 `version=latest`，镜像跟着上游 Alpine 分支走，分支内冻住的 chromium 版本也随之更新到当前分支的最新。

## 标签

镜像地址：`docker.cnb.cool/dtapp/alpine/chromium`

标签与 Alpine 基础镜像同一套契约，**一次构建最多产出 5 个名字**：

- 多架构 manifest list（amd64 + arm64）：`<alpine 版本>`、`<major.minor>`、`latest`
- 单平台：`<alpine 版本>-linux-{amd64,arm64}`

示例（假设基座实际版本是 `3.24.3`）：

```text
chromium:3.24.3
chromium:3.24
chromium:latest
chromium:3.24.3-linux-amd64
chromium:3.24.3-linux-arm64
```

标签里的版本**不是入参**：脚本从基座容器里读 `/etc/alpine-release`，把 `dtapp/alpine:latest` 解析成 `3.24.3` 这种确定值。`version` 入参只决定选哪个基座标签（`latest` / `3.24` / `3.24.3`）。`latest` 与 minor 只在 `dtapp/alpine` 的同名标签已指向同一 digest 时提升，所以 Chromium 永远不会跑到基座前面。

`-cjk` / `-headless` 不再发布；需要中文字体或内置无头参数时，用 `WITH_CJK=1` / `Dockerfile.headless` 自行派生。两个平台现在都用 registry 缓存（`<镜像>:buildcache`）：装包层的缓存键里带 APK 索引指纹，索引不变才命中，任何包升级都会重跑 `apk add`，上游补丁照样进得来。旧标签的替代方案见 [镜像与标签](images-and-tags.md#旧标签怎么迁移)。

单平台标签由 `docker buildx imagetools create` 从同一份 manifest list 里取 digest 打出来，不是重新构建，digest 与多架构标签里的对应条目完全一致。详见 [镜像与标签](images-and-tags.md)。

## 拉取与使用

```bash
# 拉取并查看 Chromium 版本
docker pull docker.cnb.cool/dtapp/alpine/chromium:latest
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest chromium --version

# 想开箱即用（默认无头参数 + tini）就自行派生一个 headless 镜像，见「本地构建」

# 进入容器调试
docker run --rm -it docker.cnb.cool/dtapp/alpine/chromium:latest sh

# 需要特定 Alpine 版本时
docker pull docker.cnb.cool/dtapp/alpine/chromium:3.24
```

`version` 入参只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，填 Chromium 版本号会被脚本直接拒绝（校验在 `.cnb/scripts/build-chromium.sh` 开头）。它同时决定基座标签：`latest` 取 `dtapp/alpine:latest`，`3.24` 取 `dtapp/alpine:3.24`；基座标签不存在时构建直接失败，不会退回官方 alpine。

### 无头截图 / 导出 PDF

推荐组合，复制即用，只改最后一行：

```bash
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage \
      --hide-scrollbars --window-size=1440,900 \
      --font-render-hinting=none --force-color-profile=srgb" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

导出 PDF 只换命令行末尾的输出开关：

```bash
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage --hide-scrollbars" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --print-to-pdf=/work/page.pdf https://example.com
```

为什么不再每次都手写一大串参数——这套组合里除了输出开关和 URL，其余都是不变量：

- `--init`：给容器一个 PID 1 来收尸并转发 `SIGTERM`。基础镜像没有 `ENTRYPOINT`，`chromium` 直接当 PID 1 会累积僵尸进程。
- `--shm-size=1g`：容器默认 `/dev/shm` 只有 64 MiB，不给大就得靠 `--disable-dev-shm-usage` 落盘。
- `-e CHROMIUM_USER_FLAGS="..."`：Alpine 的启动器会把它接在 `/etc/chromium/*.conf` 的系统默认值之后，Puppeteer 也读得到，不必改镜像。
- `-v "$PWD/out:/work" -w /work`：镜像的 `WORKDIR` 已经是 `/work`，产物落在挂载卷里，不写进容器可写层。

嫌长就自行派生一个内置默认参数的镜像：用 `.cnb/docker/Dockerfile.headless` 基于已发布的 chromium 叠一层（`ENV CHROMIUM_USER_FLAGS` + `tini` 当 PID 1），之后 `docker run` 不带参数就是一次版本冒烟。构建命令见[本地构建](#本地构建)。临时换参数仍用 `-e CHROMIUM_USER_FLAGS="..."` 覆盖整串，全关掉用 `-e CHROMIUM_USER_FLAGS=""`。

`--headless` 在 Chromium 132 起**就是新版无头**，不要再写 `--headless=new`（等价但多余）；`--headless=old` 已经没了，旧无头被拆成独立的 `chrome-headless-shell`。

截中文网页时，默认镜像没有 CJK 字形，需要先自行构建 `WITH_CJK=1` 的镜像（见[本地构建](#本地构建)），再按上面的命令截图。

### 作为其它镜像的基础镜像

```dockerfile
FROM docker.cnb.cool/dtapp/alpine/chromium:latest
USER chrome
```

派生镜像不用再重复配置的东西：

- `CHROME_BIN=/usr/bin/chromium`、`CHROME_PATH=/usr/bin/chromium`、`PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium` 已指向启动器
- `PUPPETEER_SKIP_DOWNLOAD=1`：派生镜像里 `npm i puppeteer` 不会再下载一份浏览器；确实需要官方 Chromium 时，在派生镜像里覆盖这个变量
- 预置用户 `chrome`（UID/GID `10001`、家目录 `/home/chrome`），`WORKDIR` 已是 `/work`；默认仍是 root，写一行 `USER chrome` 即可切换
- Chromium 版本写在镜像内 `/usr/share/alpine-chromium/VERSION`，不起进程也能 `cat` 出来

用非 root 运行时注意：`-v "$PWD:/work"` 会把挂载点属主换成宿主用户，`chrome` 可能写不进去，需要先调整目录权限。

## 触发构建

两种方式，产物一致：

- 手动：仓库页面 → 流水线 → 点击「打包 Chromium 镜像（多架构 amd64 + arm64）」按钮。
  - `version`：留空（按 `latest` 处理），或填 `3.24` / `3.24.3` 这类已在本仓库基座 registry 存在的标签 —— 这是 **Alpine 版本**，不是 Chromium 版本；`3.24` 需要基座的 minor 标签，`3.24.3` 需要先以该版本构建过基座；
  - `expected_chromium_major`：留空 = 用 Dockerfile 的 `EXPECTED_CHROMIUM_MAJOR`（当前为空，即不校验）；填 `156` = 显式确认上游换了主版本；填 `any` = 跳过断言。它只影响「版本不符就构建失败」这条断言，**不能指定安装某个旧版 Chromium**——chromium 包由 Alpine 分支的仓库决定，仓库里只保留当前版本。
- 定时：每天 `01:05`（Asia/Shanghai）自动构建一次 `latest`。它排在基座构建（`00:05`）之后 1 小时，基座取 `dtapp/alpine:latest`；**定时任务没有按钮输入，两个输入都传不了**，等价于：
  - `version` = 空 → 基座取 `dtapp/alpine:latest`（00:05 产出，当前是 3.24 分支）；
  - `expected_chromium_major` = 空 → 不校验，跟随上游。定时任务因此不会因为上游换主版本变红；想主动盯版本，手动触发时填 `expected_chromium_major=<新主版本>`（或确认可用后填 `any`）。

单条流水线内用 `docker buildx` 一次构建 amd64 + arm64 并 `--push`，多架构 manifest list 由 buildx 直接产出；只构建一个中性镜像，单平台标签由 `imagetools create` 从清单里取 digest 打出，所以不存在「先构建、再等两条都完成、最后合并清单」的时序问题。

相关配置：

- `.cnb/workflows/build-chromium.yml` —— 手动按钮触发的流水线（事件名 `web_trigger_build_chromium`）；另有 `.cnb.yml` 里的定时任务，没有 push / PR 触发
- `.cnb/web_trigger.yml` —— 按钮名称、权限与两个输入项（`version`、`expected_chromium_major`）
- `.cnb.yml` —— `include` 列表与定时任务
- `.cnb/scripts/build-chromium.sh` —— 实际执行的构建与推送命令

`version` 的处理规则（见脚本开头）：去掉空白与不可打印字符，为空则回落为 `latest`，非 `latest` / 非 Alpine 版本号直接 `exit 1`。

`expected_chromium_major` 的处理规则：空 = 不传 `--build-arg`，用 Dockerfile 默认值（空，即不校验）；纯数字（如 `156`）= 覆盖断言；`any` = 跳过断言；其它值直接 `exit 1`。

两个平台都用 registry 缓存，但失效点是 APK 索引指纹而不是日期：构建前在基座容器里 `apk update` 并对 `APKINDEX` 求 `sha256`，索引不变就命中，任何包升级就重跑装包层。所以上游补丁不用等 Dockerfile 改动也能进镜像，没变化时又不会白装 761 MiB。机制见[缓存实现](../cache-implementation.md)。

## 构建产物元数据

构建成功后脚本会把本次产物信息写到 `.cnb/annotation.json`，再由 `cnbcool/annotations` 插件写入当前 commit 的元数据：

| key                           | 内容                                             | 来源                                              |
|-------------------------------|--------------------------------------------------|---------------------------------------------------|
| `chromium_image_digest`       | `sha256:...` 完整摘要                            | `docker buildx imagetools inspect`                |
| `chromium_image_digest_short` | 前 12 位，供徽章展示                             | 同上                                              |
| `chromium_image_size`         | amd64 单平台压缩后体积（config + 各 layer 合计） | 同上                                              |
| `chromium_image_size_arm64`   | arm64 单平台压缩后体积（算法同上）               | 同上                                              |
| `chromium_base_image`         | 本次构建的基座引用，如 `dtapp/alpine:3.24.3`     | 脚本解析出的基座版本标签                          |
| `chromium_base_digest`        | 基座多架构 index 的完整摘要                      | `docker buildx imagetools inspect`                |
| `chromium_version`            | 镜像内实际 Chromium 版本，如 `155.0.8059.84`     | 在 `<版本>-linux-amd64` 里跑 `chromium --version` |
| `chromium_built_at`           | UTC 构建时间                                     | `date -u`                                         |

`chromium_version` 是拿镜像里真实的二进制问出来的：标签只固定 Alpine 版本，同一个标签里的 chromium 会随上游补丁漂移，记下版本才能回答「这个 digest 里到底是哪个浏览器」。

体积按平台分别统计：多架构 manifest list 本身没有「总拉取体积」，`docker pull` 只会拉取宿主机对应架构的层，所以两个架构各记一个值才有意义。同一份 Dockerfile 下两者通常只差几个百分点，但空跑一次只查 amd64 会漏掉 arm64 基础包体积异常的情况。

读取方式：

- 页面：仓库 → Commit 列表 → 对应提交 → 元数据（只读）
- 徽章：`https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}`，未写入过的 key 显示灰色 `unknown`

这样「某次提交对应哪个镜像、里面是哪个 Chromium」可反查。注意元数据只挂在 commit 上，重跑同一提交会覆盖同名 key。

## 生成 Code Wiki

文档由 `cnbcool/codewiki` 生成，产物落在 `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 并入库知识库。

触发方式：

- 手动：流水线 → 「生成 Code Wiki」按钮，随时可按需重建
- 打 tag（`git push --tags`）时自动触发

之所以保留手动入口：本仓库不发版、日常不打 tag，只靠 `tag_push` 等于永不生成。两段流水线内容一致（`.cnb/workflows/codewiki.yml` 里的 `web_trigger_codewiki` 与 `tag_push`），改生成参数需同步两处。

## 本地构建

```bash
# 单架构，构建完留在本地（基础版本默认 latest，跟随上游）
docker build -f .cnb/docker/Dockerfile.chromium --build-arg ALPINE_VERSION=3.24.3 -t alpine-chromium:local .

# 可选：中文字体（CI 不发布，需要就自己构建）
docker build -f .cnb/docker/Dockerfile.chromium --build-arg ALPINE_VERSION=3.24.3 \
  --build-arg WITH_CJK=1 -t alpine-chromium:local-cjk .

# 可选：内置无头参数 + tini（基于上面的本地镜像叠一层；CI 不发布）
docker build -f .cnb/docker/Dockerfile.headless \
  --build-arg BASE_IMAGE=alpine-chromium:local -t alpine-chromium:local-headless .

# 多架构
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg ALPINE_VERSION=3.24.3 \
  -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
```

本地 `docker build` 不传 `CHROMIUM_BASE_IMAGE` 时，Dockerfile 的默认基座是官方 `alpine:${ALPINE_VERSION}`——这样不依赖私有仓库也能复现。要验证「以本仓库基座构建」的路径，先取基座 digest 再显式传入（名称与 digest 一起给，OCI 标签才对得上；下面假设基座已按 `3.24.3` 构建过，日常也可把两处 `3.24.3` 都换成 `latest`）：

```bash
BASE=docker.cnb.cool/dtapp/alpine:3.24.3
BASE_DIGEST=$(docker buildx imagetools inspect "$BASE" --format '{{.Manifest.Digest}}')
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg ALPINE_VERSION=3.24.3 \
  --build-arg CHROMIUM_BASE_IMAGE="$BASE@$BASE_DIGEST" \
  --build-arg CHROMIUM_BASE_NAME="$BASE" \
  --build-arg CHROMIUM_BASE_DIGEST="$BASE_DIGEST" \
  -t alpine-chromium:local .
```

多平台产物无法 `--load` 进本地 docker，需要 `--push` 推到仓库，或用 `--output type=oci,dest=out.tar` 落成 tar。

Dockerfile 里 `ARG EXPECTED_CHROMIUM_MAJOR=` 默认空 = 不校验（跟随上游）；填具体主版本才断言。上游在分支内换大版本时，带断言的构建会**显式失败**并打印实际版本。临时跳过用 `--build-arg EXPECTED_CHROMIUM_MAJOR=any`，或在按钮里填 `expected_chromium_major=any`；确认可用后再把断言值更新为新的主版本（见 [CONTRIBUTING.md](../../CONTRIBUTING.md)）。

Chromium 依赖较多，首次构建耗时明显长于纯 alpine 镜像；同一台机器重复构建会命中 BuildKit 层缓存。

## 改完配置后跑格式化

YAML、Markdown、Shell、Dockerfile 四类文件统一由 `make format` 处理：

```bash
make format          # 全部
make format-yaml     # 仅 YAML（.cnb 目录与 .cnb.yml）
make format-markdown # 仅 Markdown
make format-shell    # 仅 .cnb/scripts 下的 shell
make format-docker   # 仅 .cnb 下的 Dockerfile
```

需要本机已安装 `yamlfmt`、`markdownfmt`、`shfmt`、`dockerfmt`（Homebrew 或 `go install`，例如 `mvdan.cc/sh/v3/cmd/shfmt@latest`、`github.com/google/yamlfmt/cmd/yamlfmt@latest`）。

YAML 的格式化规则在 `.yamlfmt`（缩进 2 空格、保留空行、引号统一单引号），Shell 规则为 `shfmt -i 2 -ci -bn -s -ln bash`。

## 安全扫描

- `.scanignore` —— 对所有扫描能力生效的排除清单（gitignore 语义，`!` 前缀为重新纳入）。当前只排除 `.cnb/bug.png`、`.cnb/hi.gif` 两个二进制资源，其余配置与脚本刻意不排除，以便发现「误把密钥写进 `env`」这类改动。
- `.cnb/security/code_scan_config.yml` —— 通过 `ignoreFrom: .scanignore` 引用上述文件。

Chromium 体积大、依赖多，漏洞扫描结果里系统包的 CVE 会比纯 alpine 镜像多，需要按上游 Alpine 的修复节奏跟进（本仓库每天定时重建 `latest` 即为此）。

## 目录结构

```text
.                              # 仓库根：Alpine 基础镜像 + Chromium 镜像共存
├── .cnb.yml                 # 流水线入口：include 各 workflow + 两条定时任务
├── .cnb/
│   ├── docker/Dockerfile.alpine   # Alpine 基础镜像（curl / drill / git / nc / tzdata）
│   ├── docker/Dockerfile.chromium # ← 本篇：Chromium 镜像（基于 Dockerfile.alpine 的产物 + chromium + 渲染依赖）
│   ├── docker/Dockerfile.headless # 本地派生用：内置无头参数 + tini（CI 不发布）
│   ├── scripts/build-alpine.sh     # Alpine 基础镜像的构建脚本
│   ├── scripts/build-chromium.sh  # ← 本篇：Chromium 镜像的构建脚本
│   ├── workflows/                 # 各触发事件的流水线（build-alpine / build-chromium / ...）
│   ├── security/                  # 安全扫描配置
│   ├── settings.yml               # 仓库界面（issue 按钮图等）
│   └── web_trigger.yml            # 自定义按钮（两个镜像各一个）
├── docs/                    # 两个镜像的分册文档，结构对称
│   ├── alpine/              # Alpine 基础镜像（索引 index.md）
│   └── chromium/            # ← 本篇：Chromium 镜像（索引 index.md）
├── Makefile                 # make format（一次覆盖两个镜像）
├── .yamlfmt                 # yamlfmt 规则
├── .scanignore              # 安全扫描排除清单
├── LICENSE                  # MIT
├── CONTRIBUTING.md          # 贡献流程与硬性规则（两个镜像共用）
└── SECURITY.md              # 漏洞报告渠道与已知取舍（两个镜像共用）
```

## 常见问题

- 构建报「找不到基座 `…`」：基座标签不存在。先跑 build-alpine（`latest` 由每日 `00:05` 任务产出；填 `3.24` / `3.24.3` 时要以同一版本构建过基座），再重试。
- 构建报基础镜像拉取失败：`version` 只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，写成不存在的版本会在 `FROM` 阶段直接失败；填 Chromium 版本号会被脚本直接拒绝。也别退回老分支——3.20/3.21 的 chromium 已经冻在 131/136。
- 构建报「chromium 主版本与 `EXPECTED_CHROMIUM_MAJOR` 不符」：上游换大版本了，先跑一次无头渲染确认可用，再把断言值改成实际主版本（Dockerfile 默认空 = 不校验）；临时验证可以在按钮里填 `expected_chromium_major=<新主版本>` 或 `any` 覆盖断言。
- 启动报 `No usable sandbox!` / `Running as root without --no-sandbox is not supported`：容器内以 root 运行，必须加 `--no-sandbox`（或自行准备非 root 用户与 seccomp 配置）。
- 页面渲染崩溃、`/dev/shm` 相关报错：加 `--disable-dev-shm-usage`，并给容器 `--shm-size=1g`。
- 中文显示成方块：不是配置问题，主镜像本来就没有 CJK 字形（`font-freefont` 的 cmap 里汉字码位为 0）。用 `--build-arg WITH_CJK=1` 自行构建，或派生镜像里 `apk add font-noto-cjk`，`fc-list :lang=zh | head` 能验证。
- 容器退出后留了一堆僵尸进程 / `SIGTERM` 不生效：基础镜像没有 `ENTRYPOINT`，运行时加 `--init`，或用 `Dockerfile.headless` 自行派生一个自带 `tini` 的镜像。
- 定时任务的基座分支固定为 `latest`：定时任务没有按钮输入（等价留空 → `latest`），产物标签 `<alpine 版本>`、单平台标签与 `<minor>` / `latest` 照常每次更新；要换基座分支请手动点按钮并填 `version`。
- 改完 `.cnb/workflows/**` 记得同步 `include` 与 `web_trigger.yml` 里的事件名，否则按钮可能指向一个不存在的事件。

## 许可与贡献

- 许可证：[MIT](../../LICENSE)
- 贡献流程与硬性规则：[CONTRIBUTING.md](../../CONTRIBUTING.md)
- 漏洞报告渠道、已知取舍：[SECURITY.md](../../SECURITY.md)
- 深入文档（Dockerfile 逐段解析、APK 源、CI 流水线、标签契约、排错手册等）：[文档索引](index.md)
