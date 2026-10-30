# Alpine + Chromium 基础镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security) ![基础镜像](https://img.shields.io/badge/base-alpine-0d597f?logo=alpinelinux&logoColor=white) ![浏览器](https://img.shields.io/badge/browser-chromium-4285f4?logo=googlechrome&logoColor=white) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![时区](https://img.shields.io/badge/timezone-Asia%2FShanghai-success) ![镜像大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_size) ![arm64 大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_size_arm64) ![Chromium 版本](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_version) ![镜像摘要](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_digest_short)

基于 Alpine 自建的 Chromium 镜像。镜像由 CNB 流水线自动构建并推送到制品库，供其它项目作为「容器内跑无头浏览器」的基础镜像（截图、PDF 导出、页面渲染、E2E 测试等）。

> **本文档位置**：Alpine 基础镜像与 Chromium 镜像现在同仓库维护（`dtapp/alpine`）， 两套 Dockerfile 与流水线互不干扰。本目录是 Chromium 镜像的分册文档，索引见 [index.md](index.md)；Alpine 基础镜像的文档在 [`docs/alpine/`](../alpine/index.md)。 下文命令里的镜像地址已更新为合并后的 `docker.cnb.cool/dtapp/alpine/chromium`。

## 镜像里有什么

- 基础镜像：`alpine:3.24.3`（`ALPINE_VERSION` 默认钉死**具体补丁版本**，不再用 `latest`）
- APK 源替换为国内镜像，cernet → 官方依次回退，国内拉包不必直连 `dl-cdn.alpinelinux.org`
- 浏览器主程序：`chromium`（Alpine 官方包，二进制位于 `/usr/bin/chromium`）
- Chromium 运行所需图形/渲染依赖：`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig` —— 这些由 `chromium` 的 `so:` 依赖**自动带入**，不需要显式声明；显式写出来不增体积、删掉也不减体积
- 显式 `apk add` 的只有闭包里没有的那几个：`chromium`、`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`
- 字体：`font-freefont` + `fontconfig`，只覆盖拉丁与常见符号。**镜像不含任何 CJK 字形，截中文网页一定是豆腐块**，中文请用 [`-cjk` 变体](#变体与标签)（+88.8 MiB）
- 预置非 root 用户 `chrome`（UID/GID `10001`、家目录 `/home/chrome`）与 `WORKDIR /work`；默认 `USER` 仍是 root
- 时区固定为 `Asia/Shanghai`（`/etc/localtime` 与 `/etc/timezone` 均已写入）
- 构建末尾清理 `/var/cache/apk`、`/tmp`、`/root/.cache`、`/var/tmp`

注意：本镜像**只提供浏览器与依赖**，不装 `curl`/`netcat-openbsd`/`bind-tools` 这类排障工具，也不带任何应用代码。镜像体积比纯 alpine 基础镜像大一个量级（数百 MB），属于预期。

Dockerfile 位于 `.cnb/docker/Dockerfile.chromium`，`-headless` 变体位于 `.cnb/docker/Dockerfile.headless`。

### 为什么基础版本必须跟着 Alpine 走

`chromium` 在 Alpine 的 **community** 仓库，而 community 只维护到「下一个 stable 发布」，所以每个分支里的 chromium 会**冻住**：

| 分支     | chromium            | 最后更新                               | 分支支持到                                  |
|----------|---------------------|----------------------------------------|---------------------------------------------|
| 3.20     | `131.0.6778.108`    | 2024-12（已 EOL，浏览器 CVE 无从修起） | 2026-04                                     |
| 3.21     | `136.0.7103.113`    | 2025-05                                | 2026-11                                     |
| 3.22     | `142.0.7444.59`     | 2025-11                                | 2027-05                                     |
| 3.23     | `149.0.7827.53`     | 2026-06                                | 2027-11                                     |
| **3.24** | **`155.0.8059.84`** | 2026-10                                | 2028-06（当前唯一 main + community 双支持） |

要浏览器 CVE 修得掉，基础分支就得跟着走；这也是 `ALPINE_VERSION` 默认钉在 `3.24.3` 而不是 `latest` 的原因。

## 变体与标签

镜像地址：`docker.cnb.cool/dtapp/alpine/chromium`

同一份构建脚本产出三个变体：

| 变体        | 额外内容                                 | 代价                        | 什么时候用                     |
|-------------|------------------------------------------|-----------------------------|--------------------------------|
| default     | 中性基座，不含任何启动参数               | —                           | 自己控制启动参数，或要最小体积 |
| `-cjk`      | 多一个 `font-noto-cjk`（简繁日韩全覆盖） | +88.8 MiB                   | 要截中文 / 日文 / 韩文网页     |
| `-headless` | 内置一套无头默认参数 + `tini` 当 PID 1   | ≈0（与 default 共用基础层） | 不想每次手写一大串参数         |

default 与 `-headless` 都**不含 CJK 字形**，`-cjk` 多出来的 88.8 MiB 就是买汉字字库。default 与 `-headless` 的压缩体积**相同**是预期行为（headless 只改 `ENV` / `ENTRYPOINT` / `CMD`，层共用，digest 不同）。验证：

```bash
# default 应无输出，-cjk 应有输出
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest fc-list :lang=zh | head
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest-cjk fc-list :lang=zh | head
```

标签矩阵（`<version>` = Alpine 版本，如 `3.24` / `3.24.3`；带 `<version>` 的标签只在手动触发并填了版本号时生成，`latest` 每次都推）：

- 多架构 manifest list（amd64 + arm64）：`latest`、`<version>`、`latest-cjk`、`<version>-cjk`、`latest-headless`、`<version>-headless`
- 单平台：`latest[-cjk|-headless]-linux-{amd64,arm64}`、`<version>[-cjk|-headless]-linux-{amd64,arm64}`

`version` 对应的是 **Alpine 版本**（构建参数 `ALPINE_VERSION`，需与 Docker Hub 上真实存在的 alpine tag 一致），不是 Chromium 版本；Chromium 版本由该 Alpine 分支的软件包仓库决定，实际值记在元数据 `chromium_version` 里。

单平台标签现在**直接指向该架构的镜像清单**（由 `docker buildx imagetools create` 从 manifest list 里取 digest 打出来），不再是「带 attestation 的 index」：`docker buildx imagetools inspect` 看到的就是一份含 `layers` 的清单，体积可以直接求和。见 [构建元数据与徽章](metadata-and-badges.md)。

`-headless` 变体基于**同一批次**的 default 镜像（按 digest 叠层），所以三个变体的浏览器与依赖同源，不会出现「变体里是旧 chromium」。

### 标签名怎么拆

```text
<基线>[-<变体>]-linux-<架构>

  基线   latest（最近一次成功构建）| <version>（Alpine 版本线，手动触发才有）
  变体   省略 = default | -cjk | -headless
  架构   amd64 | arm64
```

从右往左读：先看架构，再看变体，最后看基线。

### 一次构建产出的全部标签（逐条）

**多架构 manifest list——两个平台，直接拉来跑**

| 标签              | 拆解                     | 内容                                                           |
|-------------------|--------------------------|----------------------------------------------------------------|
| `latest`          | 基线 latest，default     | amd64 + arm64，中性基座，不含任何启动参数                      |
| `latest-cjk`      | 基线 latest，`-cjk`      | 同上，多 `font-noto-cjk`（压缩 +72 MiB / installed +88.8 MiB） |
| `latest-headless` | 基线 latest，`-headless` | 同上，内置无头默认参数 + `tini`（压缩体积与 `latest` 相同）    |

**单平台标签——只保证一个架构，给「一标签一平台」的工具链用**

| 标签                          | 拆解                            | 内容                                      |
|-------------------------------|---------------------------------|-------------------------------------------|
| `latest-linux-amd64`          | 基线 latest，default，amd64     | `latest` 里的 amd64 清单，digest 完全相同 |
| `latest-linux-arm64`          | 基线 latest，default，arm64     | `latest` 里的 arm64 清单                  |
| `latest-cjk-linux-amd64`      | 基线 latest，`-cjk`，amd64      | `latest-cjk` 的 amd64 清单                |
| `latest-cjk-linux-arm64`      | 基线 latest，`-cjk`，arm64      | `latest-cjk` 的 arm64 清单                |
| `latest-headless-linux-amd64` | 基线 latest，`-headless`，amd64 | `latest-headless` 的 amd64 清单           |
| `latest-headless-linux-arm64` | 基线 latest，`-headless`，arm64 | `latest-headless` 的 arm64 清单           |

**构建缓存——不是镜像，别拉、别 `FROM`**

| 标签                  | 是什么                       | 为什么比镜像还大                                    |
|-----------------------|------------------------------|-----------------------------------------------------|
| `buildcache`          | default 变体的 buildx 层缓存 | 存的是构建层的中间产物，600–800 MiB，只影响构建速度 |
| `buildcache-cjk`      | `-cjk` 变体的缓存            | 同上，因为多装了 `font-noto-cjk`，比 default 更大   |
| `buildcache-headless` | `-headless` 变体的缓存       | 同上                                                |

**版本线——只有手动触发并填了 `version` 才有**

`<version>`、`<version>-cjk`、`<version>-headless` 三个多架构标签，加对应的六个 `<version>…-linux-{amd64,arm64}` 单平台标签，规则与上面逐条相同，只是基线从 `latest` 换成具体版本（如 `3.24.3`）。

三条配套说明：

- 单平台标签**不是重新构建**出来的镜像：脚本用 `docker buildx imagetools create` 把多架构 index 里对应条目的 digest 挂到新名字上，所以两者的 digest 完全一致。
- 单平台标签只承诺那一个架构：在 arm64 机器上拉 `*-linux-amd64` 会直接失败（`no matching manifest for linux/arm64`），跨架构场景请用 `latest*` 这类多架构标签。
- `buildcache*` 没有平台维度、也不是镜像，`docker run` / `FROM` 都会失败；删掉只会让下一次构建变慢。

### 制品库列表里的标签与数字怎么读

标签含义见上一节，这里只讲**阅读顺序和数字口径**：

- 列表按**推送时间倒序**：单平台标签是最后一步派生的，所以排在最上面；`latest*` 是构建时最先推的，会排在下面甚至第二页。
- **列表里的 MiB 是压缩后的层大小（下载量），不是解压后的占用。** `latest` 在列表里是 321.61 MiB（amd64），`docker image ls` 看到的是 700–800 MB 量级——Chromium 的依赖（llvm / mesa / gtk 等）可压缩率很高，差两倍多属正常。
- **`latest` 与 `latest-headless` 大小完全相同是对的**：headless 只改 `ENV` / `ENTRYPOINT` / `CMD` / `LABEL`，层与 default 完全共用，配置层只多几百字节；digest 不同，不是同一个镜像。
- **`buildcache-*`（600–800 MiB）比镜像还大是正常的**：缓存里是每个构建层的中间产物，三个变体各一份，`mode=min` 也会保留层数据；只影响构建速度，不影响镜像内容。

## 拉取与使用

```bash
# 拉取并查看 Chromium 版本
docker pull docker.cnb.cool/dtapp/alpine/chromium:latest
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest chromium --version

# -headless 变体不带参数就是一次冒烟（打印版本）
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest-headless

# 进入容器调试
docker run --rm -it docker.cnb.cool/dtapp/alpine/chromium:latest sh

# 需要特定 Alpine 版本时
docker pull docker.cnb.cool/dtapp/alpine/chromium:3.24
```

`version` 入参只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，填 Chromium 版本号会被脚本直接拒绝（校验在 `.cnb/scripts/build-chromium.sh` 开头）。

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

嫌长就用 `-headless` 变体，参数已经内置（同一套值 + `--user-data-dir=/tmp/chromium-headless`，避免并发实例撞 `SingletonLock`），并且自带 `tini` 当 PID 1，不需要再 `--init`：

```bash
docker run --rm -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest-headless \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

临时换参数：`-e CHROMIUM_USER_FLAGS="..."` 覆盖整串；全关掉用 `-e CHROMIUM_USER_FLAGS=""`。

`--headless` 在 Chromium 132 起**就是新版无头**，不要再写 `--headless=new`（等价但多余）；`--headless=old` 已经没了，旧无头被拆成独立的 `chrome-headless-shell`。

截中文网页把镜像换成 `-cjk`（没有 `-cjk-headless` 组合，所以仍用基础镜像那套参数）：

```bash
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage --hide-scrollbars" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest-cjk \
  chromium --virtual-time-budget=10000 --screenshot=/work/zh.png https://example.com
```

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
  - `version`：留空（按 `latest` 处理），或填 `3.24` / `3.24.3` 这类已存在于 Docker Hub 的 alpine tag —— 这是 **Alpine 版本**，不是 Chromium 版本；
  - `expected_chromium_major`：留空 = 用 Dockerfile 里的断言值 `155`；填 `156` = 显式确认上游换了主版本；填 `any` = 跳过断言。它只影响「版本不符就构建失败」这条断言，**不能指定安装某个旧版 Chromium**——chromium 包由 Alpine 分支的仓库决定，仓库里只保留当前版本。
- 定时：每天 `01:30`（Asia/Shanghai）自动构建一次 `latest`，用于跟随上游 Alpine 与 Chromium 更新。**定时任务没有按钮输入，两个输入都传不了**，等价于：
  - `version` = 空 → 基座跟 `alpine:latest`（当前是 3.24 分支）；
  - `expected_chromium_major` = 空 → 用 Dockerfile 里的断言值 `155`。 所以定时任务遇到上游换 Chromium 主版本会显式失败；要临时放行，只能手动点按钮并填 `expected_chromium_major`（`<新主版本>` 或 `any`）。

单条流水线内用 `docker buildx` 一次构建 amd64 + arm64 并 `--push`，多架构 manifest list 由 buildx 直接产出，三个变体在同一份脚本里依次构建，单平台标签由 `imagetools create` 从清单里取 digest 打出，所以不存在「先构建、再等两条都完成、最后合并清单」的时序问题。

相关配置：

- `.cnb/workflows/build-chromium.yml` —— 手动按钮触发的流水线（事件名 `web_trigger_build_chromium`）与 PR 校验流水线（`validate-chromium`）
- `.cnb/web_trigger.yml` —— 按钮名称、权限与两个输入项（`version`、`expected_chromium_major`）
- `.cnb.yml` —— `include` 列表与定时任务
- `.cnb/scripts/build-chromium.sh` —— 实际执行的构建与推送命令

`version` 的处理规则（见脚本开头）：去掉空白与不可打印字符，为空则回落为 `latest`，非 `latest` / 非 Alpine 版本号直接 `exit 1`。

`expected_chromium_major` 的处理规则：空 = 不传 `--build-arg`，用 Dockerfile 里的 `155`；纯数字（如 `156`）= 覆盖断言；`any` = 跳过断言；其它值直接 `exit 1`。

定时构建每天会传一个新的 `CACHE_BUST`（按天变化），用它击穿装包层缓存，这样上游补丁不用等 Dockerfile 改动也能进镜像。

## 构建产物元数据

构建成功后脚本会把本次产物信息写到 `.cnb/annotation.json`，再由 `cnbcool/annotations` 插件写入当前 commit 的元数据：

| key                           | 内容                                             | 来源                                              |
|-------------------------------|--------------------------------------------------|---------------------------------------------------|
| `chromium_image_digest`       | `sha256:...` 完整摘要                            | `docker buildx imagetools inspect`                |
| `chromium_image_digest_short` | 前 12 位，供徽章展示                             | 同上                                              |
| `chromium_image_size`         | amd64 单平台压缩后体积（config + 各 layer 合计） | 同上                                              |
| `chromium_image_size_arm64`   | arm64 单平台压缩后体积（算法同上）               | 同上                                              |
| `chromium_version`            | 镜像内实际 Chromium 版本，如 `155.0.8059.84`     | 在 `latest-linux-amd64` 里跑 `chromium --version` |
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
# 单架构，构建完留在本地（基础版本默认钉 3.24.3）
docker build -f .cnb/docker/Dockerfile.chromium --build-arg ALPINE_VERSION=3.24.3 -t alpine-chromium:local .

# 变体：中文字体
docker build -f .cnb/docker/Dockerfile.chromium --build-arg ALPINE_VERSION=3.24.3 \
  --build-arg WITH_CJK=1 -t alpine-chromium:local-cjk .

# 变体：内置无头参数（基于上面的本地镜像叠一层）
docker build -f .cnb/docker/Dockerfile.headless \
  --build-arg BASE_IMAGE=alpine-chromium:local -t alpine-chromium:local-headless .

# 多架构
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg ALPINE_VERSION=3.24.3 \
  -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
```

多平台产物无法 `--load` 进本地 docker，需要 `--push` 推到仓库，或用 `--output type=oci,dest=out.tar` 落成 tar。

Dockerfile 里用 `ARG EXPECTED_CHROMIUM_MAJOR=155` 断言测出的 chromium 主版本：上游在分支内换大版本时构建会**显式失败**并打印实际版本。临时跳过用 `--build-arg EXPECTED_CHROMIUM_MAJOR=any`，或在按钮里填 `expected_chromium_major=any`；正式提交仍要更新 Dockerfile 默认值（见 [CONTRIBUTING.md](../../CONTRIBUTING.md)）。

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
│   ├── docker/Dockerfile.alpine   # Alpine 基础镜像（curl / drill / nc / tzdata）
│   ├── docker/Dockerfile.chromium # ← 本篇：Chromium 镜像（alpine + chromium + 渲染依赖）
│   ├── docker/Dockerfile.headless # ← 本篇：-headless 变体（内置无头参数 + tini）
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

- 构建报基础镜像拉取失败：`version` 只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，写成不存在的版本会在 `FROM` 阶段直接失败；填 Chromium 版本号会被脚本直接拒绝。也别退回老分支——3.20/3.21 的 chromium 已经冻在 131/136。
- 构建报「chromium 主版本与 `EXPECTED_CHROMIUM_MAJOR` 不符」：上游换大版本了，先跑一次无头渲染确认可用，再把 Dockerfile 里的默认值改成实际主版本；临时验证可以在按钮里填 `expected_chromium_major=<新主版本>` 或 `any` 覆盖断言。
- 启动报 `No usable sandbox!` / `Running as root without --no-sandbox is not supported`：容器内以 root 运行，必须加 `--no-sandbox`（或自行准备非 root 用户与 seccomp 配置）。
- 页面渲染崩溃、`/dev/shm` 相关报错：加 `--disable-dev-shm-usage`，并给容器 `--shm-size=1g`。
- 中文显示成方块：不是配置问题，主镜像本来就没有 CJK 字形（`font-freefont` 的 cmap 里汉字码位为 0）。换 `-cjk` 变体即可，`fc-list :lang=zh | head` 能验证。
- 容器退出后留了一堆僵尸进程 / `SIGTERM` 不生效：基础镜像没有 `ENTRYPOINT`，运行时加 `--init`，或直接用 `-headless` 变体（自带 `tini`）。
- 定时任务只产出 `latest`：定时任务没有按钮输入，`version` 传不了（等价留空 → `latest`），不会打版本标签；需要版本标签请手动点按钮并填 `version`。
- 改完 `.cnb/workflows/**` 记得同步 `include` 与 `web_trigger.yml` 里的事件名，否则按钮可能指向一个不存在的事件。

## 许可与贡献

- 许可证：[MIT](../../LICENSE)
- 贡献流程与硬性规则：[CONTRIBUTING.md](../../CONTRIBUTING.md)
- 漏洞报告渠道、已知取舍：[SECURITY.md](../../SECURITY.md)
- 深入文档（Dockerfile 逐段解析、APK 源、CI 流水线、标签契约、排错手册等）：[文档索引](index.md)
