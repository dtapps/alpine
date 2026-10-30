# 构建

> 本地一次 `docker build` 验内容，CI 一次 `buildx build` 出多架构与三个变体——同一份 Dockerfile、同一个 `ALPINE_VERSION` 参数，差别只在产物怎么落地。

## 本地单架构

```bash
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .
```

不传 `--build-arg` 时用 Dockerfile 的默认值 `ALPINE_VERSION=3.24.3`（**具体补丁版本，不是 `latest`**）。构建期已经替你做了一次 `chromium --version`：结果写进镜像内 `/usr/share/alpine-chromium/VERSION`，并与 `EXPECTED_CHROMIUM_MAJOR` 比对，对不上就构建失败。所以「构建成功」本身已经证明浏览器装上了。

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
- `ALPINE_VERSION` 是 **Alpine 版本**（对应 Docker Hub 上的 alpine tag），不是 Chromium 版本。Chromium 装哪个版本由该 Alpine 分支的软件包仓库决定。
- 验证命令刻意不用 `curl` / `nc` / `dig`：本镜像不装任何排障工具。
- `--no-sandbox` 是**运行时**参数（镜像内默认 root）；`--shm-size=1g` 与 `--disable-dev-shm-usage` 是容器 `/dev/shm` 只有 64MB 时的标准应对，两者一起带最省心。

## 构建参数与变体

| 参数                      | 默认      | 作用                                                                 |
|---------------------------|-----------|----------------------------------------------------------------------|
| `ALPINE_VERSION`          | `3.24.3`  | 基础镜像的 Alpine 版本，必须具体到补丁号                             |
| `WITH_CJK`                | `0`       | `1` 时装 `font-noto-cjk`（+88.8 MiB）。中文截图必须用这个变体        |
| `WITH_CHROMEDRIVER`       | `0`       | `1` 时装 `chromium-chromedriver`（+17.5～28.4 MiB，随分支变化）      |
| `WITH_SWIFTSHADER`        | `0`       | `1` 时装 `chromium-swiftshader`（+约 5 MiB），要 WebGL/Canvas 才需要 |
| `EXPECTED_CHROMIUM_MAJOR` | `155`     | Chromium 主版本断言，不符则构建失败；传 `any` 跳过                   |
| `CACHE_BUST`              | `0`       | 装包层的缓存击穿点，CI 每天传新值。不传也不影响正确性                |
| `BUILD_DATE` / `REVISION` | `unknown` | 写进 OCI 标签，由 CI 注入                                            |

三个变体：

```bash
# default：中性基座，不含任何启动参数
docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .

# -cjk：中文字体（主镜像不含 CJK 字形，截中文网页一定是豆腐块）
docker build -f .cnb/docker/Dockerfile.chromium --build-arg WITH_CJK=1 \
  -t alpine-chromium:local-cjk .

# -headless：内置默认无头参数 + tini 当 PID 1，基于刚构建的 default 镜像
docker build -f .cnb/docker/Dockerfile.headless \
  --build-arg BASE_IMAGE=alpine-chromium:local -t alpine-chromium:local-headless .
```

`-headless` 是唯一一个独立 Dockerfile 的变体：`ENTRYPOINT` / `CMD` 无法用 `ARG` 条件化，只能单独一层叠上去。它 `FROM` 的是同一批次的 default 镜像，所以两者共用层、不会重复占体积。

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
| `--build-arg`                     | 传构建参数           | `ALPINE_VERSION` / `WITH_*` / `CACHE_BUST` 等          |
| `--push`                          | 构建完直接推送       | 每个变体各一次                                         |
| `--pull`                          | 强制刷新基础镜像     | 全部带上，否则可能用 builder 里的旧 `alpine` 层        |
| `--provenance=false --sbom=false` | 关闭默认 attestation | 让 manifest list 只剩每个架构一个条目，digest 好对     |
| `--cache-from` / `--cache-to`     | 跨流水线层缓存       | `type=registry`，ref 为 `<image>:buildcache<suffix>`   |

缓存的两条规律，第二个是本仓库特有的坑：

- **同一个 builder 内的层缓存自动复用**，所以一条流水线里三个变体、六个平台构建不会重复干活。
- **跨轮次缓存必须能被击穿**。启用 registry 缓存后，如果 Dockerfile 一个字都没改，装包层会一直命中缓存——上游 chromium 出了补丁也进不来。脚本因此每天传一个 `CACHE_BUST=$(date +%Y%m%d)`，它位于装包层的第一条命令里，只让这一层失效：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --cache-to type=registry,ref=<registry>/alpine-chromium:buildcache,mode=min \
  --cache-from type=registry,ref=<registry>/alpine-chromium:buildcache \
  --build-arg CACHE_BUST=$(date -u +%Y%m%d) \
  -f .cnb/docker/Dockerfile.chromium -t <registry>/alpine-chromium:test --push .
```

- 首次构建慢是常态：`chromium` 的依赖闭包在 3.24 上是 184 个包 / 761 MiB installed，下载与解包占掉大部分时间。换 `ALPINE_VERSION` 会从 `FROM` 开始全量失效，等于重新装一遍。

## CI 构建脚本逐段

`.cnb/scripts/build-chromium.sh` 被 `source` 执行而不是 `sh build-chromium.sh`，因为 `##[set-output]` 与 `export` 都要在当前 shell 里生效。

1. **version 清洗与校验**：先 `tr -d '[:space:]'`、`tr -d '\n\r'` 去空白与换行，`sed 's/[^[:print:]]//g'` 去不可打印字符，空值回落 `latest`；再用 `case` 白名单只放行 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，其它直接 `exit 1`。填 Chromium 主版本号（例如 `131`）会被这一步拦下，而不是等到 `FROM alpine:131` 报一句难懂的错。

2. **输出与导出**：

```bash
echo "##[set-output interior_version=$version]"
export INTERIOR_VERSION="$version"
```

3. **登录**：凭证来自 `imports` 引入的组织环境，仓库里不存在任何 token，见 [安全基线](security-baseline.md)。

4. **公共构建参数**：`--pull`、attestation 开关（老版本 buildx 不认 `--provenance` 时自动跳过）、`ALPINE_VERSION`、`BUILD_DATE`、`BUILD_REVISION`、`CACHE_BUST`。装包层的缓存击穿就靠最后这个值。

5. **buildx 自检**：`docker buildx version`、`docker buildx ls`、`docker buildx inspect` 各带 `|| exit 1`。builder 不可用时立刻停下。

6. **三个变体依次构建**：default → `-cjk` → `-headless`。`-headless` 先取 default 的 index digest，用 `--build-arg BASE_IMAGE=<image>@<digest>` 钉住，避免 `--pull` 又去拉一次刚推上去的 tag。每个变体恒定推 `latest<suffix>`，`INTERIOR_VERSION != latest` 时再追加 `<version><suffix>`。

7. **单平台标签**：不再重新构建。脚本用 `docker buildx imagetools inspect` 从 manifest list 里取出每个架构的清单 digest，再用 `docker buildx imagetools create -t <image>:latest<suffix>-linux-<arch> <image>@<digest>` 直接打标签：

| 变体        | 多架构                            | 单平台                                               |
|-------------|-----------------------------------|------------------------------------------------------|
| default     | `latest` / `<version>`            | `latest-linux-{amd64,arm64}` / `<version>-linux-…`   |
| `-cjk`      | `latest-cjk` / `<version>-cjk`    | `latest-cjk-linux-{amd64,arm64}` / `<version>-cjk-…` |
| `-headless` | `latest-headless` / `<version>-…` | `latest-headless-linux-{amd64,arm64}` / …            |

这一步把原来「同样的内容再构建两遍」省掉了：以前靠三次构建「撞」出内容一致，现在单平台标签就是 manifest list 里那个清单本身，一致性是构造出来的。

8. **元数据汇总**：`docker buildx imagetools inspect` 取 index digest；体积按平台算，单平台标签现在直接指向镜像清单，`--raw` 里就有 `layers`，求和即可（脚本保留了「退回 index 子 digest」的兜底路径）。Chromium 版本用 `docker run … chromium --version` 取，写进 `chromium_version`——标签只固定 Alpine 版本，同一个标签里的浏览器会漂，只有这个 key 能回答「这个 digest 里是哪个 Chromium」。结果写成 `.cnb/annotation.json` 六个 key，由流水线第二步的 `cnbcool/annotations` 插件写进当前 commit 元数据，README 徽章从 `/-/badge/annotation/commit/latest/{key}` 读。细节见 [构建元数据](metadata-and-badges.md)。

## 构建失败怎么定位

| 现象                                                | 常见原因                                          | 处置                                                                |
|-----------------------------------------------------|---------------------------------------------------|---------------------------------------------------------------------|
| `❌ version 只接受…`                                | 填了 Chromium 版本号或非法字符                    | 填 `latest`、`3.24`、`3.24.3` 这类 Alpine 版本号                    |
| `FROM` 阶段失败                                     | `ALPINE_VERSION` 不是 Docker Hub 上真实存在的标签 | 用 `3.24` / `3.24.3` 这类真实标签                                   |
| `❌ chromium 主版本与 EXPECTED_CHROMIUM_MAJOR 不符` | 上游在该分支升了 Chromium 主版本                  | 跑一次渲染冒烟确认无回归，更新 Dockerfile 默认值；临时可传 `any`    |
| `docker login` 返回 401                             | `CNB_TOKEN` / `CNB_TOKEN_USER_NAME` 未注入        | 检查 `imports` 是否成功、环境仓库是否可读                           |
| buildx 自检失败或 bootstrap 超时                    | 误建了 `docker-container` builder                 | 去掉自建 builder，直接用平台内置的                                  |
| `apk add` 卡住或超时                                | 某个源当前不可用                                  | 按 [APK 源与网络](mirrors.md) 在宿主机探活源地址                    |
| 构建耗时远超预期                                    | 缓存未命中，或换了 `ALPINE_VERSION`               | 属正常量级；确认 registry 缓存在用，见上文「buildx 常用参数与缓存」 |
| 单平台标签报 `digest 取不到`                        | manifest list 还没推成功，或 `--provenance` 没关  | 手工 `imagetools inspect` 复核索引条目                              |
| 元数据 `chromium_image_digest` 为 `unknown`         | `imagetools inspect` 没取到 digest                | 先确认推送成功，再手工跑一次 `imagetools inspect`                   |
| `-headless` 变体构建失败                            | `BASE_IMAGE` 拉不到（default 还没推上去）         | 单独重跑脚本；本地构建时确认 `BASE_IMAGE` 指向本地标签              |

定位手法：

- 脚本每段都有 `echo` 标记（`== buildx 环境 ==`、`== 汇总镜像元数据 ==` 等），日志里最后出现的标记就是失败位置。
- 每条 `docker` 命令后面都跟 `|| exit 1`，不会出现「命令失败但流水线继续」的假成功。
- 需要复现单条命令时，把 `${CNB_*}` 换成自己的值，在本地按同样的参数跑一次。

## PR 上的自动校验

`pull_request` 会跑 `validate-chromium`：`--load` 构建 amd64（不推送），然后三次冒烟——`chromium --version`、`--dump-dom about:blank`、`date +%Z` 应为 `CST`。改坏 Dockerfile 不用再等到次日 `01:30` 的定时任务才发现。

## 先在 fork 或私有路径试推

- 镜像是从**运行流水线的那个仓库**的 slug 推出去的：`IMAGE` = `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/chromium`，所以从 fork 或自己的仓库触发，产物落到 `docker.cnb.cool/<你的命名空间>/alpine/chromium`，不会碰 `dtapp/alpine`。
- 本地试推自己的 tag：

```bash
docker login <your-registry>
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile.chromium \
  -t <your-registry>/alpine-chromium:test --push .
```

- 不要在 `dtapp/alpine/chromium` 上做实验性推送：`latest` 是对外标签，一次错推会直接影响所有以 `FROM ...:latest` 构建的下游。另外它和 Alpine 基础镜像共用 `dtapp/alpine` 这个仓库前缀，试推时务必带上 `/chromium` 子路径，别把标签推到 `dtapp/alpine` 上。
- 改完脚本用 `shfmt -i 2 -ci -bn -s -ln bash` 的规则对齐（`make format-shell`）。

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据](metadata-and-badges.md)
- [开始使用](getting-started.md)
- [排错手册](troubleshooting.md)
