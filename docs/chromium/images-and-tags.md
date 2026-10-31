# 镜像地址与标签

> 镜像地址 `docker.cnb.cool/dtapp/alpine/chromium`。标签是一份对外契约：一次构建产出哪些名字、三种变体怎么组合、单平台与多架构的差别、下游该固定到标签还是 digest，都在这里。

## 两个平台：CNB 与 GHCR

同一套变体与标签规则同时发布到两个 registry，各推各的、互不引用：

| 平台   | 镜像地址                                | 流水线                                 |
|--------|-----------------------------------------|----------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/alpine/chromium` | `.cnb.yml` + `.cnb/workflows/`         |
| GitHub | `ghcr.io/dtapps/alpine/chromium`        | `.github/workflows/build-chromium.yml` |

三个变体（`latest` / `-cjk` / `-headless`）、标签矩阵、冒烟断言完全一致，但两边是两份副本（`.cnb/scripts/build-chromium.sh` 与 `.github/scripts/build-chromium.sh`，Dockerfile 同理）：平台胶水各自维护，改标签规则时两份都要改。digest 不同——各 registry 各自构建、各自解析基座。GitHub 侧的目录、触发方式与变量契约见 [GitHub Actions 与 GHCR](../github.md)。

## 三个变体

所有变体由同一份 `.cnb/scripts/build-chromium.sh` 一次跑完，`-headless` 基于同一批次 default 镜像的 digest 叠出来，所以它们的内容同源。

| 变体        | 构建方式                          | 相对 default 的差异                                                                                              | 代价             |
|-------------|-----------------------------------|------------------------------------------------------------------------------------------------------------------|------------------|
| default     | `.cnb/docker/Dockerfile.chromium` | 中性基座，不含任何启动参数                                                                                       | —                |
| `-cjk`      | 同上 + `WITH_CJK=1`               | 多装 `font-noto-cjk`，简繁日韩字形全覆盖                                                                         | +88.8 MiB        |
| `-headless` | `.cnb/docker/Dockerfile.headless` | `ENV CHROMIUM_USER_FLAGS=<一套默认无头参数>` + `ENTRYPOINT ["/sbin/tini","--"]` + `CMD ["chromium","--version"]` | ≈0（共用基础层） |

变体后缀直接拼在标签名里，`latest` 与 `<version>` 两套都有。

## 标签矩阵

### 多架构 manifest list

一次 `docker buildx build --platform linux/amd64,linux/arm64` 直接产出，`docker pull` 会按宿主机架构自动挑条目。

| 标签                 | 内容                          | 什么时候产生                               |
|----------------------|-------------------------------|--------------------------------------------|
| `latest`             | default 变体，amd64 + arm64   | 每次都推，无例外                           |
| `latest-cjk`         | + `font-noto-cjk`             | 每次都推                                   |
| `latest-headless`    | + 默认无头参数 + tini         | 每次都推                                   |
| `<version>`          | 与同次 `latest` 一致          | 手动触发且 `version` 清洗后不等于 `latest` |
| `<version>-cjk`      | 与同次 `latest-cjk` 一致      | 同上                                       |
| `<version>-headless` | 与同次 `latest-headless` 一致 | 同上                                       |

### 单平台标签

给「一个标签只想对应一个平台」的工具链用。每个多架构标签派生两条：

| 标签                                        | 内容                                 |
|---------------------------------------------|--------------------------------------|
| `latest-linux-amd64` / `latest-linux-arm64` | default 变体的单架构镜像             |
| `latest-cjk-linux-amd64` / `-arm64`         | `-cjk` 变体的单架构镜像              |
| `latest-headless-linux-amd64` / `-arm64`    | `-headless` 变体的单架构镜像         |
| `<version>-linux-{amd64,arm64}`             | 同次构建的版本标签，规则同上三个后缀 |

合起来是 6 个多架构标签 × 2 个架构 = 12 条单平台标签（版本标签存在时）。命名规则一句话：

```text
<base>[-cjk|-headless][-linux-<arch>]
  base  ∈ {latest, <version>}
  arch  ∈ {amd64, arm64}
```

`<version>` 只代表 **Alpine 版本**（例如 `3.24` / `3.24.3`），不是 Chromium 版本。它决定 `FROM` 哪一版 `alpine`，Chromium 的具体版本由该 Alpine 版本仓库在构建当时锁定的包决定——想固定 Chromium 版本，标签帮不上忙，只能按 digest 固定，见下文「按 digest 固定拉取」。

另外两个命名要点：

- `latest` 恒定推送。填了版本号是「额外再加一套版本标签」，不是「替换 latest」。
- 定时任务固定 `version=latest`，所以每天 `01:30` 那次构建只刷新 6 个 `latest*` 与 12 个单平台标签，不会产生版本标签。版本标签只能由人点按钮决定。
- 制品库里还能看到 `buildcache` / `buildcache-cjk` / `buildcache-headless` 三个标签，那是 buildx 的层缓存（`mode=min`），不是给人拉的。

## 单平台标签现在就是镜像清单

以前单平台标签是「带 attestation 的 index」，统计体积得先钻进去找子 digest。现在不一样了：

- 构建时加了 `--provenance=false --sbom=false`（buildx 不支持时自动跳过），manifest list 里每个架构只剩一个条目；
- 单平台标签由 `docker buildx imagetools create -t <tag> <image>@<该架构 digest>` 生成，**直接指向该架构的镜像清单**。

```bash
# raw 里出现 "layers" 就是镜像清单，说明标签打对了
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest-linux-amd64 --raw | head -20

# 多架构标签则是 index，能看到 amd64 与 arm64 两个条目
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest
```

带来的直接好处：**「按平台算体积」可以直接对单平台标签求和**，不用再绕 index 找子 digest。

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest-linux-amd64 --raw \
  | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
  | awk '{s+=$1} END{printf "%.1f MB\n", s/1048576}'
```

多架构标签没有「总拉取体积」这种东西：用户只会拉自己平台那几层，所以体积永远按平台报（commit 元数据里就是 `chromium_image_size` / `chromium_image_size_arm64` 两个值）。

还要记住单平台标签的边界：它里面只有那一个架构，在 arm64 上拉 `*-linux-amd64` 会失败；跨架构场景请用 `latest` 这类多架构标签。

## 选标签的决策树

```text
先问「我要什么」
├─ 页面 / 截图里要有中文（或日韩）  → latest-cjk / <version>-cjk
├─ 想开箱即用：默认无头参数 + tini  → latest-headless / <version>-headless
├─ 要中性基座，参数完全自己控        → latest / <version>
└─ 要钉死某次产物（任何变体都行）    → @sha256:<digest>

再问「要不要固定」
├─ 跟随上游安全补丁  → latest*
└─ 可复现 / 可审计   → @sha256:<digest>
```

按场景展开：

| 场景                       | 选择                                               | 理由                                                                        |
|----------------------------|----------------------------------------------------|-----------------------------------------------------------------------------|
| 生产、需要可复现、需要审计 | `@sha256:...`                                      | 唯一不可变的引用；镜像未签名，digest 是唯一强校验手段                       |
| 跟随上游安全补丁           | `latest`（或 `latest-cjk` / `latest-headless`）    | 每天 `01:30` 随上游 Alpine 重建一次，`CACHE_BUST` 每天击穿缓存，补丁进得来  |
| 中文页面 / 中文截图        | `latest-cjk` / `<version>-cjk`                     | 默认变体一个汉字字形都没有，`font-freefont` 的 CJK 码位实测为 0             |
| 少拼命令行、要 tini 收尸   | `latest-headless` / `<version>-headless`           | 默认参数已进镜像，`docker run image:latest-headless` 不带参就是一次版本冒烟 |
| 需要特定 Alpine 版本       | `<version>` / `<version>-linux-<arch>`             | 版本标签不会自动跟随补丁，需要重新手动触发                                  |
| 需要固定 Chromium 版本     | `@sha256:...`（digest）                            | Chromium 版本由 Alpine 仓库决定，不是构建参数，标签表达不了                 |
| 工具链只吃「一标签一平台」 | `latest-linux-<arch>`（`-cjk` / `-headless` 同理） | 平台写死在标签里，代价是失去跨架构可移植性                                  |

体积上的取舍也一并说清楚：`-cjk` 多 88.8 MiB installed，`-headless` 约等于零（只加了一个 `ENV`、一个 `ENTRYPOINT` 和一个 `CMD`，层几乎不增重）。所以「能不能用 `-headless`」基本不需要犹豫，「要不要 `-cjk`」才是真正的成本决策。

## version 输入的清洗与校验

脚本开头三步处理（`.cnb/scripts/build-chromium.sh`）：

```bash
version=$(echo "$version" | tr -d '[:space:]' | tr -d '\n\r')   # 去空白与换行
version=$(echo "$version" | sed 's/[^[:print:]]//g')            # 去不可打印字符
[ -z "$version" ] && version="latest"                           # 空值回落
```

紧接着是白名单校验：只接受 `latest` 或 `3.24` / `3.24.3` 这类 Alpine 版本号，其它值直接 `exit 1` 并提示「这里填的是 Alpine 版本，不是 Chromium 版本」。由此得到的实际行为：

| 输入                | 实际使用                            |
|---------------------|-------------------------------------|
| 留空                | `latest`                            |
| 前后带空格的 `3.24` | `3.24`                              |
| 末尾带换行的 `3.24` | `3.24`                              |
| `latest`            | `latest`（跟随上游，默认）          |
| `v3.24`             | 直接 `exit 1`，不会进到构建阶段     |
| `155.0.8059.84`     | 直接 `exit 1`（这是 Chromium 版本） |

清洗只去空白与不可打印字符，不做任何规范化。通过校验的值会原样作为 `--build-arg ALPINE_VERSION` 传给 `FROM alpine:${ALPINE_VERSION}`，所以它必须是 Docker Hub 上真实存在的 alpine tag。

再强调一次它的边界：`version` 只换 Alpine，不换 Chromium。Dockerfile 不锁包版本，`apk add chromium` 装的是该 Alpine 版本仓库里的当前版本，所以：

- 换成 `3.21` / `3.22` 这类不同版本分支，会连带不同的 Chromium 版本（3.21 冻在 136、3.22 在 142、3.24 是 155）；`3.20` 已 EOL，别用；
- 同一个版本标签重建，也可能因为上游仓库更新而带上更新的 Chromium 小版本。

也就是说，**标签无法表达「我要 Chromium 1xx」**。需要确定 Chromium 版本时，只能记下某次构建的 digest 并按 digest 拉取；每个镜像里的精确版本可以现场查：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest cat /usr/share/alpine-chromium/VERSION
```

## 按 digest 固定拉取

标签会移动，digest 不会。生产环境需要可复现时按 digest 拉取：

```bash
# 取当前 latest（多架构 index）的 digest
DIGEST=$(docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --format '{{.Manifest.Digest}}')

# 固定拉取
docker pull "docker.cnb.cool/dtapp/alpine/chromium@${DIGEST}"
```

三个变体各有自己的 digest，要固定哪个变体就取哪个标签的 digest（`latest-cjk`、`latest-headless` 各取一次），不要拿 `latest` 的 digest 当通用值。

digest 的四个来源，按可靠性排序：

| 来源                                                               | 说明                                                |
|--------------------------------------------------------------------|-----------------------------------------------------|
| Commit 元数据 `chromium_image_digest`                              | 该次构建 `latest` 的完整 `sha256:...`，构建脚本写入 |
| `docker buildx imagetools inspect --format '{{.Manifest.Digest}}'` | 现场查询，任何时刻都能取到当前值                    |
| 镜像内的 `/usr/share/alpine-chromium/VERSION`                      | 反过来确认「这个 digest 里是哪个 Chromium」         |
| 徽章 `/badge/annotation/commit/latest/chromium_image_digest_short` | 只有前 12 位，用于人工核对，不足以拉取              |

`chromium_image_digest` 记录的是 `latest` 这个多架构 index 的 digest。按它拉取，宿主机仍会自动选平台，可复现性与多架构便利性同时保留。

## 改名与删除标签的兼容流程

标签命名是对外契约（见 [CONTRIBUTING](../../CONTRIBUTING.md) 硬性规则），`latest`、`<version>`、三个变体后缀与 `*-linux-{arch}` 已有下游在用，改名前先在 issue 里讨论。落地顺序：

1. 脚本里给新名字和旧名字同时打标签，一次构建双写；
2. 通知下游切换到新名字，留出迁移窗口；
3. 确认无人引用后再从脚本里删掉旧名字。

不要单独删除 `latest*` 或 `*-linux-*`：定时任务每天 `01:30` 都会重推，删除既会与下一次构建冲突，也会让删除窗口内拉取的下游直接失败。确实要下线某个版本标签，也得先确认没有下游按该名字固定，并把对应的 digest 保留下来。

## 历史镜像

- 历史镜像（旧 digest）不回溯修复，用完即弃：补丁节奏等于上游 Alpine 的补丁节奏，需要新补丁就重新触发构建。
- Chromium 的安全更新同样由 Alpine 的 `chromium` 包带进来，本仓库不单独跟随 Chromium 上游版本；上游发了新版 Chromium，重建 `latest` 就能拿到。上游在分支内换主版本时构建会显式失败（`EXPECTED_CHROMIUM_MAJOR` 断言），定时任务某天变红通常就是这个原因。
- `*-linux-{amd64,arm64}` 与同次构建的多架构标签指向同一批清单 digest，不单独维护、也不会各自漂移。
- 制品库只负责存储与分发，不校验来源真实性（镜像未签名），强校验只能靠 digest。

以上取舍的完整表述见 [SECURITY](../../SECURITY.md)。

## 相关文档

- [开始使用](getting-started.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全策略](../../SECURITY.md)
