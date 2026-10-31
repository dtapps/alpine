# 构建

> 本地一次 `docker build` 验内容，CI 一次 `buildx build` 出多架构——同一份 Dockerfile、同一个 `ALPINE_VERSION` 参数，差别只在基座来源与产物怎么落地：CI 以本仓库构建的 Alpine 基础镜像为基座（digest 钉住），本地默认用官方 `alpine`。CI 只发布一个中性镜像，标签与 alpine 同款 5 个。

## 本地单架构

```bash
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
```

不传 `--build-arg` 时用 Dockerfile 的默认值 `ALPINE_VERSION=latest`，基座随之落到官方 `alpine:latest`（本地构建不依赖私有仓库）。要复用本仓库构建的 Alpine 基础镜像，传 `CHROMIUM_BASE_IMAGE`（见下文「基座来源」）。构建期已经替你做了一次 `chromium --version`：结果写进镜像内 `/usr/share/alpine-chromium/VERSION`，并（在传入 `EXPECTED_CHROMIUM_MAJOR` 时）与断言值比对，对不上就构建失败。所以「构建成功」本身已经证明浏览器装上了。

再验一次它真的能跑起来渲染：

```bash
# 1. 浏览器本体与版本
docker run --rm alpine-chromium:local chromium --version
docker run --rm alpine-chromium:local cat /usr/share/alpine-chromium/VERSION

# 2. 渲染冒烟（不进网络，只验 Chromium 能起、能输出 DOM）
docker run --rm --shm-size=1g alpine-chromium:local \
  chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank
```

- 构建上下文是仓库根目录（命令最后的 `.`），Dockerfile 在 `.cnb/docker/`，所以必须 `-f` 指定。
- `ALPINE_VERSION` 是 **Alpine 版本**，不是 Chromium 版本。CI 里 `version` 入参只用来选基座标签（`latest` / `3.24` / `3.24.3` → `docker.cnb.cool/dtapp/alpine:<同名>`），随后 `ALPINE_VERSION` 被覆盖成从基座容器读出的实际版本；本地不传 `CHROMIUM_BASE_IMAGE` 时则落到官方 `alpine:<ALPINE_VERSION>`。Chromium 装哪个版本由该 Alpine 分支的软件包仓库决定。
- `curl` / `nc` / `drill` / `git` 继承自基座，容器内可直接用；`dig`（`bind-tools`）、`vim`、`python` 仍然不装。
- `--no-sandbox` 是**运行时**参数（镜像内默认 root）；`--shm-size=1g` 与 `--disable-dev-shm-usage` 是容器 `/dev/shm` 只有 64MB 时的标准应对，两者一起带最省心。

## 构建参数

| 参数                      | 默认                       | 作用                                                                 |
|---------------------------|----------------------------|----------------------------------------------------------------------|
| `ALPINE_VERSION`          | `latest`                   | CI 传解析出的实际版本；本地决定官方基座 `alpine:<版本>`              |
| `CHROMIUM_BASE_IMAGE`     | `alpine:${ALPINE_VERSION}` | 基座镜像引用；CI 传 `<基座仓库>:<version>@sha256:…` 钉死 digest      |
| `CHROMIUM_BASE_NAME`      | `alpine:${ALPINE_VERSION}` | 写进 OCI 标签 `org.opencontainers.image.base.name`                   |
| `CHROMIUM_BASE_DIGEST`    | `unknown`                  | 写进 OCI 标签 `org.opencontainers.image.base.digest`                 |
| `WITH_CJK`                | `0`                        | `1` 时装 `font-noto-cjk`（+88.8 MiB）。CI 不传；需要中文时自己传     |
| `WITH_CHROMEDRIVER`       | `0`                        | `1` 时装 `chromium-chromedriver`（+17.5～28.4 MiB，随分支变化）      |
| `WITH_SWIFTSHADER`        | `0`                        | `1` 时装 `chromium-swiftshader`（+约 5 MiB），要 WebGL/Canvas 才需要 |
| `EXPECTED_CHROMIUM_MAJOR` | 空                         | Chromium 主版本断言，不符则构建失败；留空或传 `any` 跳过             |
| `CACHE_BUST`              | `0`                        | 装包层的缓存击穿点；GitHub 侧每天传新值，CNB 侧不启用缓存            |
| `BUILD_DATE` / `REVISION` | `unknown`                  | 写进 OCI 标签，由 CI 注入                                            |

### 基座来源

`FROM` 由 `CHROMIUM_BASE_IMAGE` 决定，所以同一个 Dockerfile 能同时服务两种场景：

| 场景     | `CHROMIUM_BASE_IMAGE`                                                      | 说明                                                        |
|----------|----------------------------------------------------------------------------|-------------------------------------------------------------|
| 本地构建 | 不传，默认 `alpine:${ALPINE_VERSION}`                                      | 只需要 Docker Hub，不需要私有仓库凭证                       |
| CI 构建  | `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}:<alpine 版本>@sha256:…` | 脚本先解析实际版本，再取该版本标签的 digest，取不到直接失败 |

本地复用基座时手动钉 digest：

```bash
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg CHROMIUM_BASE_IMAGE=docker.cnb.cool/dtapp/alpine:latest@sha256:<digest> \
  --build-arg CHROMIUM_BASE_NAME=docker.cnb.cool/dtapp/alpine:latest \
  --build-arg CHROMIUM_BASE_DIGEST=sha256:<digest> \
  -t alpine-chromium:local .
```

基座 API 注意：`latest` 由每天 `00:05`（Asia/Shanghai）的 build-alpine 任务刷新；填具体版本（`3.24.3`）前，基座仓库里必须已有同名标签，否则脚本在解析 digest 时就会失败，不会悄悄退回官方 `alpine`。

可选派生（CI 不发布）：

```bash
# 中性镜像（CI 发布的就是这个）
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .

# 中文字体（默认镜像不含 CJK 字形，截中文网页一定是豆腐块）
docker build -f .cnb/docker/Dockerfile.chromium --build-arg WITH_CJK=1 \
  -t alpine-chromium:local-cjk .

# 内置默认无头参数 + tini 当 PID 1，基于刚构建的中性镜像
docker build -f .cnb/docker/Dockerfile.headless \
  --build-arg BASE_IMAGE=alpine-chromium:local -t alpine-chromium:local-headless .
```

`-headless` 用独立 Dockerfile 是因为 `ENTRYPOINT` / `CMD` 无法用 `ARG` 条件化，只能单独一层叠上去。它 `FROM` 的是同一批次的镜像，所以两者共用层、不会重复占体积。

## 多架构的三种落地方式

| 方式     | 关键参数                                    | 产物                       | 限制                              |
|----------|---------------------------------------------|----------------------------|-----------------------------------|
| `--load` | `--platform linux/amd64 --load`             | 本地 image store           | 只能单平台                        |
| `--push` | `--platform linux/amd64,linux/arm64 --push` | 仓库，多架构 manifest list | 需先 `docker login`，产物不在本地 |
| OCI tar  | `--output type=oci,dest=out.tar`            | 本地 tar 文件              | 不能 `docker load`                |

- `--load` 的限制来自本地 image store 不支持 manifest list：多平台 + `--load` 会直接报 `docker exporter does not currently support exporting manifest lists`。要本地同时拿到两个架构，只能分两次单平台 `--load`，而两次会争抢同一个标签名，所以本地多平台验证通常改用 OCI tar。
- `--push` 是 CI 唯一使用的模式。本地不要随手 `--push` 到 `docker.cnb.cool/dtapp/alpine/chromium`，会覆盖对外标签。
- `--output type=oci,dest=out.tar` 把多平台产物落成一个 OCI layout 的 tar。本镜像含 Chromium，两个平台的 tar 加起来是数百 MB 量级，留档前留意磁盘。

本地多架构示例：

```bash
docker buildx create --name alpine-chromium-multi --driver docker-container --bootstrap --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile.chromium \
  -t alpine-chromium:local --output type=oci,dest=out.tar .
```

第一行的自建 builder 只需要执行一次：默认的 `docker` driver 不支持多平台。**但这只适用于本地**——CNB 的 `services: docker` 已内置可做多架构的 builder，流水线里不要再 `docker buildx create --driver docker-container`，受限容器里拉不起嵌套 buildkitd，会以 bootstrap 失败告终。

## buildx 常用参数与缓存

| 参数                              | 作用                 | 本仓库用法                                             |
|-----------------------------------|----------------------|--------------------------------------------------------|
| `-f`                              | 指定 Dockerfile      | `.cnb/docker/Dockerfile.chromium`（headless 用另一个） |
| `--platform`                      | 目标平台             | 一次构建同时给 `linux/amd64,linux/arm64`               |
| `--build-arg`                     | 传构建参数           | `ALPINE_VERSION` / `CHROMIUM_BASE_*` 等                |
| `--push`                          | 构建完直接推送       | 每次构建一次                                           |
| `--pull`                          | 强制刷新基础镜像     | 全部带上，否则可能用 builder 里旧标签对应的基座层      |
| `--provenance=false --sbom=false` | 关闭默认 attestation | 让 manifest list 只剩每个架构一个条目，digest 好对     |
| `--cache-from` / `--cache-to`     | 跨流水线层缓存       | CNB 不用；GitHub 用 `type=gha`（不产生 registry 标签） |

缓存的两条规律，第二个是本仓库特有的坑：

- **同一个 builder 内的层缓存自动复用**，所以一次多架构构建里的两个平台不会重复干活。
- **跨轮次缓存必须能被击穿**。启用缓存后，如果 Dockerfile 一个字都没改，装包层会一直命中缓存——上游 chromium 出了补丁也进不来。GitHub 侧因此每天传 `CACHE_BUST=$(date +%Y%m%d)`，它位于装包层的第一条命令里，只让这一层失效。CNB 侧**不启用 registry 缓存**：每日 cron 本来就要重新装包，缓存只会让补丁进不来，还会在制品库里多出 `buildcache*` 标签。

```bash
# GitHub 侧的等价参数（gha 缓存，不占 GHCR 标签）
docker buildx build --platform linux/amd64,linux/arm64 \
  --cache-to type=gha,scope=alpine-chromium,mode=min,ignore-error=true \
  --cache-from type=gha,scope=alpine-chromium \
  --build-arg CACHE_BUST=$(date -u +%Y%m%d) \
  -f .github/docker/Dockerfile.chromium -t <image>:<alpine 版本> --push .
```

- 首次构建慢是常态：`chromium` 的依赖闭包在 3.24 上是 184 个包 / 761 MiB installed，下载与解包占掉大部分时间。换 `ALPINE_VERSION` 会连同基座 digest 一起变，从 `FROM` 开始全量失效，等于重新装一遍。

### 基座变更与缓存

基座引用是 `FROM` 的一部分，所以「基座换了」和「Dockerfile 改了」一样会命中不了旧缓存：

- **同一轮构建**：脚本先解析基座 digest 再传给 `CHROMIUM_BASE_IMAGE`，一次构建只有一个基座，层缓存正常复用。
- **跨轮次**：基座 `latest` 每天被 build-alpine 覆盖，digest 一变，`FROM` 这层及其下游自动失效——不需要额外击穿手段，这层「基座更新 → Chromium 重建」是由 digest 自然传导的。`CACHE_BUST` 只解决「基座没变、上游 chromium 包出了补丁」这一种情况。
- **不要把基座写成浮动 tag**：CI 里传的是 `@sha256:…` 形式，保证同一次构建里解析到的基座和标签里记录的 `base.digest` 是同一个东西。

## CI 构建脚本逐段

`.cnb/scripts/build-chromium.sh` 被 `source` 执行而不是 `sh build-chromium.sh`，因为 `##[set-output]`、登录态与 `trap cleanup` 都要留在当前 shell。

1. **version 清洗与校验**：先 `tr -d '[:space:]'`、`tr -d '\n\r'` 去空白与换行，`sed 's/[^[:print:]]//g'` 去不可打印字符，空值回落 `latest`；再用 `case` 白名单只放行 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，其它直接 `exit 1`。填 Chromium 主版本号（例如 `131`）会被这一步拦下，而不是等到 `FROM <基座>:131` 报一句难懂的错。

2. **主版本断言参数**：`expected_chromium_major` 为空时不追加参数（Dockerfile 默认值也不断言）；填主版本号（如 `155`）时转成 `--build-arg EXPECTED_CHROMIUM_MAJOR=<主版本>`；填 `any` 时同样传入，Dockerfile 据此跳过断言。

3. **登录与构建元数据**：凭证来自 `imports` 引入的组织环境，仓库里不存在任何 token，见 [安全基线](security-baseline.md)；`BUILD_DATE` / `REVISION` 在这一段算出。

4. **buildx 自检**：`docker buildx version`、`docker buildx ls`、`docker buildx inspect` 各带 `|| exit 1`。builder 不可用时立刻停下，不必等到基座解析。

5. **解析基座**：按 `version` 映射到本仓库的基座标签（`latest` → `<仓库 slug>:latest`，否则 `<仓库 slug>:<version>`），启动一个容器读 `/etc/alpine-release` 得到实际版本（如 `3.24.3`），再确认 `<仓库 slug>:3.24.3` 存在并取它的 index digest。取不到就 `die`，不会退回官方 `alpine`——这是 Chromium 构建对 build-alpine 产物的硬依赖。之后把 digest 同时传进 `CHROMIUM_BASE_IMAGE`（真正给 `FROM` 用）和 `CHROMIUM_BASE_DIGEST`（给 OCI 标签）。

6. **公共构建参数**：`--pull`、attestation 开关（老版本 buildx 不认 `--provenance` 时自动跳过）、`ALPINE_VERSION`、三个 `CHROMIUM_BASE_*`、`BUILD_DATE`、`BUILD_REVISION`。CNB 侧不传 `CACHE_BUST`（没有 registry 缓存）；GitHub 侧还多传一个按天变化的值，用来击穿 gha 缓存。

7. **一次多架构构建**：只构建一个中性镜像，恒定推 `<alpine 版本>`（脚本从基座解析出来的实际版本，不是入参）。

8. **单平台标签**：不再重新构建。脚本用 `docker buildx imagetools inspect` 从 manifest list 里取出每个架构的清单 digest，再用 `docker buildx imagetools create -t <image>:<alpine 版本>-linux-<arch> <image>@<digest>` 直接打标签：

| 多架构                       | 单平台                                     |
|------------------------------|--------------------------------------------|
| `<alpine 版本>`（如 3.24.3） | `<alpine 版本>-linux-{amd64,arm64}`        |
| `<major.minor>`（如 3.24）   | 由基座同名标签对齐后提升，无独立单平台标签 |
| `latest`                     | 同上                                       |

这一步把原来「同样的内容再构建两遍」省掉了：以前靠三次构建「撞」出内容一致，现在单平台标签就是 manifest list 里那个清单本身，一致性是构造出来的。

第 8 步之后还有两道门闸：冒烟测试通过后，才提升 `<major.minor>` 与 `latest`；提升前还要确认 `dtapp/alpine:<同名标签>` 已指向本次基座 digest，否则跳过——手动构建旧分支时，Chromium 的 `latest` 不会被拉回去。

9. **元数据汇总**：`docker buildx imagetools inspect` 取 index digest；体积按平台算，单平台标签现在直接指向镜像清单，`--raw` 里就有 `layers`，求和即可（脚本保留了「退回 index 子 digest」的兜底路径）。Chromium 版本用 `docker run … chromium --version` 取，写进 `chromium_version`——标签只固定 Alpine 版本，同一个标签里的浏览器会漂，只有这个 key 能回答「这个 digest 里是哪个 Chromium」。基座信息同时写进 `chromium_base_image` / `chromium_base_digest`，可以反查这次构建叠在哪个基座上。结果写成 `.cnb/annotation.json`，由流水线第二步的 `cnbcool/annotations` 插件写进当前 commit 元数据，README 徽章从 `/-/badge/annotation/commit/latest/{key}` 读。细节见 [构建元数据](metadata-and-badges.md)。

## 构建失败怎么定位

| 现象                                                | 常见原因                                         | 处置                                                                                 |
|-----------------------------------------------------|--------------------------------------------------|--------------------------------------------------------------------------------------|
| `❌ version 只接受…`                                | 填了 Chromium 版本号或非法字符                   | 填 `latest`、`3.24`、`3.24.3` 这类 Alpine 版本号                                     |
| `❌ 找不到基座 <仓库 slug>:<version>`               | 基座仓库里没有同名标签                           | 先跑 build-alpine 产出该标签（`latest` 由每日 `00:05` 任务刷新），或改用已存在的版本 |
| `FROM` 阶段失败                                     | `CHROMIUM_BASE_IMAGE` 指向的基座拉不到           | 本地核对 `CHROMIUM_BASE_IMAGE`；CI 里检查上一条的基座解析是否通过                    |
| `❌ chromium 主版本与 EXPECTED_CHROMIUM_MAJOR 不符` | 上游在该分支升了 Chromium 主版本                 | 跑一次渲染冒烟确认无回归，更新 Dockerfile 默认值；临时可传 `any`                     |
| `docker login` 返回 401                             | `CNB_TOKEN` / `CNB_TOKEN_USER_NAME` 未注入       | 检查 `imports` 是否成功、环境仓库是否可读                                            |
| buildx 自检失败或 bootstrap 超时                    | 误建了 `docker-container` builder                | 去掉自建 builder，直接用平台内置的                                                   |
| `apk add` 卡住或超时                                | 某个源当前不可用                                 | 按 [APK 源与网络](mirrors.md) 在宿主机探活源地址                                     |
| 构建耗时远超预期                                    | 缓存未命中，或换了 `ALPINE_VERSION`              | CNB 本来就没有跨轮次缓存，首轮慢属正常；GitHub 检查 gha 缓存是否命中                 |
| 单平台标签报 `digest 取不到`                        | manifest list 还没推成功，或 `--provenance` 没关 | 手工 `imagetools inspect` 复核索引条目                                               |
| 元数据 `chromium_image_digest` 为 `unknown`         | `imagetools inspect` 没取到 digest               | 先确认推送成功，再手工跑一次 `imagetools inspect`                                    |
| 本地 `-headless` 构建失败                           | `BASE_IMAGE` 拉不到（基础镜像还没构建/拉取）     | 先构建中性镜像，或把 `BASE_IMAGE` 指向已发布的 chromium 标签                         |

定位手法：

- 脚本每段都有 `echo` 标记（`== buildx 环境 ==`、`== 汇总镜像元数据 ==` 等），日志里最后出现的标记就是失败位置。
- 每条 `docker` 命令后面都跟 `|| exit 1`，不会出现「命令失败但流水线继续」的假成功。
- 需要复现单条命令时，把 `${CNB_*}` 换成自己的值，在本地按同样的参数跑一次。

## 改动后怎么验证

四个构建工作流只有手动与定时两种触发，`push` / `pull_request` 都不会自动构建。改完 Dockerfile 或构建脚本后，要验证就手动触发一次对应流水线（CNB 按钮 / `gh workflow run`），或按上面的命令本地构建；没有 PR 校验作业兜底。

## 先在 fork 或私有路径试推

- 镜像是从**运行流水线的那个仓库**的 slug 推出去的：`IMAGE` = `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/chromium`，所以从 fork 或自己的仓库触发，产物落到 `docker.cnb.cool/<你的命名空间>/alpine/chromium`，不会碰 `dtapp/alpine`。
- 基座同样按运行仓库解析：`BASE_REPO` = `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}`。fork 里只跑 Chromium 流水线是不够的，得先在你的命名空间跑一次 build-alpine 产出 `<你的命名空间>/alpine:latest`，否则脚本会在基座解析处直接失败。本地试推则手动传 `CHROMIUM_BASE_IMAGE`，或直接用它默认的官方 `alpine`。
- 本地试推自己的 tag：

```bash
docker login <your-registry>
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile.chromium \
  -t <your-registry>/alpine-chromium:test --push .
```

- 不要在 `dtapp/alpine/chromium` 上做实验性推送：`latest` 是对外标签，一次错推会直接影响所有以 `FROM ...:latest` 构建的下游。另外它和 Alpine 基础镜像共用 `dtapp/alpine` 这个仓库前缀，试推时务必带上 `/chromium` 子路径，别把标签推到 `dtapp/alpine` 上。
- 改完脚本用 `shfmt -i 2 -ci -bn -s -ln posix` 的规则对齐（`make format-shell`）。

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据](metadata-and-badges.md)
- [开始使用](getting-started.md)
- [排错手册](troubleshooting.md)
