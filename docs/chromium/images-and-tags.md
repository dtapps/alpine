# 镜像地址与标签

> 镜像地址 `docker.cnb.cool/dtapp/alpine/chromium`。标签与 Alpine 基础镜像同一套契约：**一次构建最多产出 5 个名字，版本号来自基座，不来自入参**。

## 两个平台：CNB 与 GHCR

同一套标签规则同时发布到两个 registry，两条流水线各自独立推送、互不引用：

| 平台   | 镜像地址                                | 流水线                                 |
|--------|-----------------------------------------|----------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/alpine/chromium` | `.cnb.yml` + `.cnb/workflows/`         |
| GitHub | `ghcr.io/dtapps/alpine/chromium`        | `.github/workflows/build-chromium.yml` |

标签名、提升顺序、冒烟断言完全一致，但两边是两份副本（`.cnb/scripts/build-chromium.sh` 与 `.github/scripts/build-chromium.sh`，Dockerfile 同理）：平台胶水各自维护，改标签规则时两份都要改。digest 不同——各 registry 各自构建、各自解析本平台的 Alpine 基座。

## 标签表

一次构建最多产出 5 个标签，其余名字都是对同一份 manifest 的引用改写（`<minor>` / `latest` 在基座未对齐时会跳过）：

| 标签                         | 何时产生                              | 内容                                               |
|------------------------------|---------------------------------------|----------------------------------------------------|
| `<alpine 版本>`，如 `3.24.3` | 每次构建，构建阶段唯一的 `-t`         | amd64 + arm64 的 manifest list，同名标签每天被覆盖 |
| `<alpine 版本>-linux-amd64`  | 构建成功后由 `imagetools create` 派生 | amd64 单平台内容，digest 与 index 中条目相同       |
| `<alpine 版本>-linux-arm64`  | 同上                                  | arm64 单平台内容，digest 与 index 中条目相同       |
| `<major.minor>`，如 `3.24`   | 冒烟通过 **且基座已对齐** 后提升      | 滚动 minor，指向最近一次成功的 `3.24.x` 构建       |
| `latest`                     | 最后提升，条件同上                    | 指向最近一次成功的构建                             |

示例：

```text
docker.cnb.cool/dtapp/alpine/chromium:3.24.3
docker.cnb.cool/dtapp/alpine/chromium:3.24
docker.cnb.cool/dtapp/alpine/chromium:latest
docker.cnb.cool/dtapp/alpine/chromium:3.24.3-linux-amd64
docker.cnb.cool/dtapp/alpine/chromium:3.24.3-linux-arm64
```

几个决定性细节：

- **标签里的版本不是手写的，也不是 `latest`**：脚本先启动一个基座容器读 `/etc/alpine-release`，把 `dtapp/alpine:latest` 解析成 `3.24.3` 这种确定值。所以 `latest` 天天动，而 `3.24.3` 这个标签反映的是「当前同版本产物」，重建会被覆盖。
- **同名标签每天被覆盖是刻意的**：和 alpine 一样，Alpine 的版本号就是产品的版本号。要固定某一次构建，只能按 digest 拉取，见下文「按 digest 固定拉取」。
- **`<major.minor>` 与 `latest` 有基座对齐门闸**：只有当 `dtapp/alpine:<同名标签>` 已经指向本次基座的 digest 时，才提升 chromium 的同名标签。手动构建旧分支（如基座还在 3.25、你指定 `version=3.24`）时，`latest` 会跳过，Chromium 永远不会跑到基座前面。
- 冒烟失败时 `<alpine 版本>` 已经指向那份坏产物（构建阶段就推了），但它不是给下游消费的名字：按 `latest` 或 `<major.minor>` 拉取的人不受影响，下一次成功构建会把版本标签覆盖回来。

## 版本号从哪来

`version` 入参只决定「选哪个基座标签」，不直接进产物标签：

| 输入            | 基座引用              | 产物标签（以基座实际 3.24.3 为例）        |
|-----------------|-----------------------|-------------------------------------------|
| 留空 / `latest` | `dtapp/alpine:latest` | `3.24.3`、`3.24`、`latest`                |
| `3.24`          | `dtapp/alpine:3.24`   | `3.24.3`、`3.24`；`latest` 视基座对齐情况 |
| `3.24.3`        | `dtapp/alpine:3.24.3` | `3.24.3`、`3.24`；`latest` 视基座对齐情况 |

脚本解析出实际版本后，会再确认 `dtapp/alpine:<实际版本>` 这个版本标签存在（`build-alpine` 先推版本标签、冒烟通过后才提升 `latest` / minor），然后钉住它的 digest 构建。**基座不存在就直接失败，不会退回官方 alpine。**

`version` 只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号；Chromium 版本号（如 `155.0.8059.84`）会被直接拒绝。它不能指定「装某个旧版 Chromium」——chromium 包由该 Alpine 分支的仓库决定。

## 与 Alpine 基座的关系

- Chromium 镜像 `FROM` 本仓库构建的 `alpine`（`dtapp/alpine:<alpine 版本>`），CI 按 digest 钉住；不是 Docker Hub 的官方 `alpine`。
- Dockerfile 里的 `ARG CHROMIUM_BASE_IMAGE=alpine:${ALPINE_VERSION}` 只是**不依赖私有仓库的本地构建默认值**。CI 一定用 `--build-arg` 覆盖它；基座不存在时构建失败，不会静默退回官方镜像。
- 「基于」不意味着共享标签或 digest：基座的层在构建时被复制进 Chromium 镜像，两边各自独立发布。基座 `latest` 每天 `00:05` 刷新，Chromium `01:05` 才重建；如果 Chromium 流水线没跑，它里面的 Alpine 层就还是旧的那份。
- 每次构建都会校验 OCI 标签 `org.opencontainers.image.base.name` 等于本次解析的基座引用、`org.opencontainers.image.version` 等于解析出的实际版本，校验不过直接失败。

## 为什么同时有 manifest list 和单平台标签

manifest list 是给认识多架构的客户端用的：`docker pull` 自动按宿主机架构挑条目，一条 `FROM ...:latest` 就能在 amd64 与 arm64 机器上都跑通。但有些工具链、脚本或下游配置只想拿到「一个标签对应一个平台」，单平台标签就是给这类场景的退路。

单平台标签**不是重新构建**出来的：脚本用 `docker buildx imagetools create` 把多架构 index 里该平台条目的 digest 挂到 `<版本>-linux-<arch>` 这个新名字上。整个流程只执行一次 `buildx build`，所以：

- 同名标签之间不可能出现「内容差一点」的两份镜像：它们指向的就是同一份清单 digest；
- arm64 不需要第二台 Runner，也不需要额外的「合并清单」流水线；
- 推导步骤几乎不耗时间，省掉的是两次完整构建（含两次 `apk add`）。

边界：单平台标签只承诺那一个架构，在 arm64 上拉 `*-linux-amd64` 会失败；跨架构场景请用 `latest` / `<版本>` 这类多架构标签。

## 变体与缓存标签

以前一次构建会推三套变体（default / `-cjk` / `-headless`），标签数量是现在的 3～4 倍。现在：

- **`-cjk` / `-headless` 不再发布**。需要中文字体或内置无头参数时，自行派生：

  ```bash
  # 中文字体：多 88.8 MiB
  docker build -f .cnb/docker/Dockerfile.chromium \
    --build-arg WITH_CJK=1 -t my-chromium:cjk .

  # 默认无头参数 + tini：基于已发布的 chromium 叠一层
  docker build -f .cnb/docker/Dockerfile.headless \
    --build-arg BASE_IMAGE=docker.cnb.cool/dtapp/alpine/chromium:latest \
    -t my-chromium:headless .
  ```
- **`buildcache` 是缓存清单，不是镜像标签**：两侧都写自己的 `<镜像>:buildcache`，供下一次构建命中。装包层的缓存键里带 APK 索引指纹，索引不变才命中，任何包升级都会重跑 `apk add`。
- 默认镜像仍然**不含任何 CJK 字形**：`font-freefont` 实测 12 个 `.otf` 的 cmap 里汉字/假名/谚文码位为 0。要中文必须自行构建 `WITH_CJK=1`，或在派生镜像里 `apk add font-noto-cjk`。

### 旧标签怎么迁移

本次是破坏性切换，没有双写期。旧名字与替代方案：

| 旧标签                                   | 现在怎么办                                                                   |
|------------------------------------------|------------------------------------------------------------------------------|
| `latest-cjk` / `<version>-cjk`           | 用 `--build-arg WITH_CJK=1` 自行构建，或在派生镜像里装 CJK 字体              |
| `latest-headless` / `<version>-headless` | 用 `.cnb/docker/Dockerfile.headless` 自行构建，或自己加 `ENV` / `ENTRYPOINT` |
| `latest-linux-amd64` 等单平台旧名        | 改用 `latest` / `<版本>`（多架构），或 `<版本>-linux-<arch>`                 |
| `buildcache*`                            | 不需要替代：缓存清单不是可拉取的镜像                                         |

`<version>` 的语义也变了：以前它等于你填的基座标签（如 `3.24`），现在它等于解析出的实际 Alpine 版本（如 `3.24.3`）。`3.24` 仍然存在，作为滚动 minor 标签继续移动。

## 选标签的决策树

```text
先问「我要什么」
├─ 跟随上游安全补丁、要多架构   → latest
├─ 要某个 Alpine 分支的产物     → <major.minor>（如 3.24）
├─ 要可复现 / 可审计            → @sha256:<digest>
├─ 要中文 / 日韩字形            → 自行构建 WITH_CJK=1
└─ 要内置无头参数 + tini        → 自行构建 Dockerfile.headless
```

| 场景                       | 选择                  | 理由                                                  |
|----------------------------|-----------------------|-------------------------------------------------------|
| 生产、需要可复现、需要审计 | `@sha256:...`         | 唯一不可变的引用；镜像未签名，digest 是唯一强校验手段 |
| 跟随上游安全补丁           | `latest`              | 每天 `01:05` 随上游 Alpine 重建，装包层每轮重跑       |
| 需要特定 Alpine 版本线     | `<major.minor>`       | 滚动标签，跟随基座同名标签                            |
| 需要固定 Chromium 版本     | `@sha256:...`         | Chromium 版本由 Alpine 仓库决定，标签表达不了         |
| 需要中文渲染               | 自行构建 `WITH_CJK=1` | 默认镜像一个汉字字形都没有                            |
| 工具链只吃「一标签一平台」 | `<版本>-linux-<arch>` | 平台写死在标签里，代价是失去跨架构可移植性            |

## 按 digest 固定拉取

```bash
# 取当前 latest（多架构 index）的 digest
DIGEST=$(docker buildx imagetools inspect \
  docker.cnb.cool/dtapp/alpine/chromium:latest --format '{{.Manifest.Digest}}')

# 固定拉取
docker pull "docker.cnb.cool/dtapp/alpine/chromium@${DIGEST}"
```

`chromium_image_digest` 元数据记录的就是这次构建的 index digest；`chromium_image_version` 说明它是哪个 Alpine 版本。需要确认里面是哪个 Chromium：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest \
  cat /usr/share/alpine-chromium/VERSION
```

## 改名与删除标签的兼容流程

标签命名是对外契约（见 [CONTRIBUTING](../../CONTRIBUTING.md) 硬性规则）。本次从「变体矩阵」切到 alpine 同款 5 标签，旧名字的替代方案见上文。以后再改标签名，按这个顺序：

1. 脚本里给新名字和旧名字同时打标签，一次构建双写；
2. 通知下游切换，留出迁移窗口；
3. 确认无人引用后，再从脚本里删掉旧名字。

不要单独删除 `latest` 或 `<版本>-linux-*`：定时任务每天 `01:05` 都会重推，删除既会与下一次构建冲突，也会让删除窗口内拉取的下游直接失败。
