# GitHub Actions 与 GHCR

> 两个平台各自维护一份 Dockerfile 与构建脚本（有意复制，不互相引用）：CNB 推 `docker.cnb.cool`，GitHub Actions 推 `ghcr.io`。本篇讲 GitHub 侧的目录、触发方式、镜像地址、变量契约与已知差异；CNB 侧的平台层说明见 [CNB 流水线](cnb.md)，镜像自己的流水线细节见各镜像的 [ci-pipeline](alpine/ci-pipeline.md)。

## 设计前提：两份副本，各自演进

GitHub 侧不 `source` CNB 的脚本，也不与 CNB 共用 Dockerfile。两个平台各有一份完整实现：

| 职责       | CNB 侧                                                   | GitHub 侧                                                   |
|------------|----------------------------------------------------------|-------------------------------------------------------------|
| Dockerfile | `.cnb/docker/Dockerfile.alpine`                          | `.github/docker/Dockerfile.alpine`                          |
|            | `.cnb/docker/Dockerfile.chromium`、`Dockerfile.headless` | `.github/docker/Dockerfile.chromium`、`Dockerfile.headless` |
| 构建脚本   | `.cnb/scripts/build-alpine.sh`、`build-chromium.sh`      | `.github/scripts/build-alpine.sh`、`build-chromium.sh`      |
| 流水线     | `.cnb.yml` + `.cnb/workflows/`                           | `.github/workflows/`                                        |
| 元数据     | `.cnb/annotation.json` → commit annotation → 徽章        | `.github/annotation.json` → Step Summary + artifact         |

复制而不是共用的原因：两侧的标签规则、冒烟断言是同构的，但**平台胶水完全不同**——CNB 读 `CNB_*` 变量、用 `##[set-output]`、写 commit annotation、注释里还有「imports 改写」这类历史约束；GitHub 读 Actions 上下文、写 Step Summary/artifact、缓存后端是 `type=gha`。共用意味着任何一侧改平台细节都要考虑另一侧，也会把 CNB 的历史包袱带进 GitHub（反过来同样）。

代价只有一条，且是硬性规则：**改镜像内容、标签规则、冒烟断言时，两份都要改**（见 [CONTRIBUTING](../CONTRIBUTING.md) 硬性规则）。改平台胶水（触发器、缓存、元数据落地）则只改自己那一份。

## 镜像地址

| 镜像                             | GHCR 地址                        | 对应 CNB 地址                           |
|----------------------------------|----------------------------------|-----------------------------------------|
| Alpine 基础镜像                  | `ghcr.io/dtapps/alpine`          | `docker.cnb.cool/dtapp/alpine`          |
| Alpine + Chromium 无头浏览器镜像 | `ghcr.io/dtapps/alpine/chromium` | `docker.cnb.cool/dtapp/alpine/chromium` |

上表里的字面量只是**本仓库当前的实际值**，脚本里没有写死：GitHub 侧和 CNB 侧一样从平台内置变量派生。

| 变量            | 来源                                                                 | 作用                  |
|-----------------|----------------------------------------------------------------------|-----------------------|
| `IMAGE`         | `ghcr.io` + `GITHUB_REPOSITORY`（转小写）；chromium 再加 `/chromium` | 目标镜像全名          |
| `REGISTRY_USER` | `GITHUB_ACTOR`                                                       | `docker login` 用户名 |
| `REVISION`      | `GITHUB_SHA`                                                         | OCI `revision`        |
| `IMAGE_SOURCE`  | `https://github.com/<GITHUB_REPOSITORY>`                             | OCI `source` / `url`  |

所以 fork 后自动推到 `ghcr.io/<你的账号>/alpine`，rename 仓库也不需要改代码；CNB 侧同理由 `CNB_DOCKER_REGISTRY` + `CNB_REPO_SLUG_LOWERCASE` 拼出（见 [CNB 流水线](cnb.md#镜像地址不是写死的)）。Chromium 挂在 `/chromium` 子路径下，与基础镜像的标签空间互不覆盖——这是 GHCR 支持的嵌套包名（包名即 `alpine/chromium`）。

```bash
# 基础镜像
docker run --rm -it ghcr.io/dtapps/alpine:latest sh

# Chromium（三个变体：latest / latest-cjk / latest-headless）
docker run --rm ghcr.io/dtapps/alpine/chromium:latest chromium --version
```

标签契约与 CNB 完全一致：`<alpine 版本>`、`<major.minor>`、`latest`，加上 `<base>[-cjk|-headless][-linux-<arch>]` 派生形式，详见 [Alpine 镜像与标签](alpine/images-and-tags.md) 与 [Chromium 镜像与标签](chromium/images-and-tags.md)。两个平台各自构建、各自解析基座，**digest 不通用**，不要跨平台比对。

## 触发矩阵

| 事件                | build-alpine.yml                                 | build-chromium.yml                              | 行为                                                             |
|---------------------|--------------------------------------------------|-------------------------------------------------|------------------------------------------------------------------|
| `schedule`          | 每天 `16:35 UTC`（= 00:35 Asia/Shanghai）        | 每天 `18:00 UTC`（= 02:00 Asia/Shanghai）       | 跟随上游重建；比 CNB 的 00:05 / 01:30 各晚 30 分钟，两边互不等待 |
| `workflow_dispatch` | 输入 `version`                                   | 输入 `version`、`expected_chromium_major`       | 手动构建，输入语义与 CNB 按钮完全一致                            |
| `push` 到 `main`    | 改到 `.github/docker/Dockerfile.alpine` 等输入时 | 改到 chromium / headless 的 Dockerfile 或脚本时 | 自动重建，改文档不触发                                           |
| `pull_request`      | 同上路径过滤                                     | 同上路径过滤                                    | 只构建、不推送：alpine 验时区/源/命令，chromium 验 default 变体  |

两个 workflow 都用 `concurrency: build-*-${{ github.ref }}` 串行化：定时与手动同时触发时排队，避免两条流水线并发改同一个 `latest` / `<minor>`。`cancel-in-progress: false`，不要改成 `true`——把正在推 manifest 的那次构建砍掉，会留下半套标签。

### 定时任务只认 UTC

GitHub 的 `cron` 是 UTC，不会跟随仓库时区。所以北京时间 00:35 写成 `35 16 * * *`（前一天 16:35 UTC），02:00 写成 `0 18 * * *`。改时间时两处都要换算，别直接抄 CNB 的 `5 0 * * *` / `30 1 * * *`——那会在北京时间 08:05 / 09:30 跑。比 CNB 晚 30 分钟是刻意的：两个平台各自拉上游 `alpine` 镜像源，同一分钟开跑只会互相抢索引。

另外三个平台限制：

- 定时 workflow 只会在**默认分支**上生效，且只跑该分支最新一次提交里的定义；
- fork 仓库里的定时任务默认不启用，需要在 fork 的 Actions 页手动启用（或用 `workflow_dispatch` 手动跑）；
- 仓库连续 60 天没有提交（issue、PR 也算活动）时，GitHub 会自动停用定时任务，需要手动 `Run workflow` 或提交一次才会恢复。

## 变量契约

脚本不读任何 `CNB_*`，也不需要 workflow 把镜像名拼好传进来：默认值从 Actions 内置变量派生，显式传同名变量即可覆盖（fork、本地复跑、试推）。唯一必须由 workflow 显式传的是 `REGISTRY_TOKEN`——`GITHUB_TOKEN` 不会自动进环境变量。

| 变量                      | 默认来源 / workflow 传值                                         | 作用                                                  |
|---------------------------|------------------------------------------------------------------|-------------------------------------------------------|
| `REGISTRY_TOKEN`          | workflow：`${{ secrets.GITHUB_TOKEN }}`                          | `docker login` 密码；Actions 临时签发，仓库里不存凭证 |
| `IMAGE`                   | `ghcr.io` + `GITHUB_REPOSITORY`（小写），chromium 加 `/chromium` | 目标镜像全名；可覆盖                                  |
| `REGISTRY_USER`           | `GITHUB_ACTOR`                                                   | `docker login` 用户名；可覆盖                         |
| `REVISION`                | `GITHUB_SHA`                                                     | 写进 OCI `revision` 标签；可覆盖                      |
| `IMAGE_SOURCE`            | `https://github.com/<GITHUB_REPOSITORY>`                         | 写进 OCI `source` / `url`，GHCR 靠它挂回仓库；可覆盖  |
| `version`                 | workflow：`${{ inputs.version }}`                                | 基座版本；定时/留空时跟随 Dockerfile 默认值           |
| `expected_chromium_major` | workflow：`${{ inputs.expected_chromium_major }}`                | Chromium 主版本断言（仅 chromium）                    |

Dockerfile 里的 `ARG IMAGE_SOURCE=…`、`ARG BASE_IMAGE=…` 同理只是**本地手动构建的兜底默认值**，CI 会用派生出来的值覆盖，生产产物不依赖那两行字面量。

脚本产物：`GITHUB_OUTPUT` 里写 `image_version` / `image_digest`（chromium 是 `chromium_version` / `chromium_image_digest`），并把完整元数据写进 `.github/annotation.json`（`.gitignore` 已排除），由 workflow 的 Step Summary 与 `upload-artifact` 消费。

## 与 CNB 的实现差异

| 维度     | CNB                                               | GitHub Actions                                                            |
|----------|---------------------------------------------------|---------------------------------------------------------------------------|
| 地址来源 | `CNB_DOCKER_REGISTRY` + `CNB_REPO_SLUG_LOWERCASE` | `ghcr.io` + `GITHUB_REPOSITORY`（小写）                                   |
| builder  | `services: docker` 自带多架构 buildx              | `docker/setup-qemu-action` + `docker/setup-buildx-action` 现装            |
| arm64    | runner 内置 binfmt                                | QEMU 模拟；chromium 三变体多架构因此要几十分钟（超时给到 240 分钟）       |
| 层缓存   | Alpine 不用缓存；Chromium 用 registry cache       | Alpine 不用缓存；Chromium 用 GitHub Actions 缓存（`type=gha`，不占 GHCR） |
| 元数据   | `.cnb/annotation.json` → commit annotation → 徽章 | `.github/annotation.json` → Step Summary + `upload-artifact`（留 30 天）  |
| 磁盘     | 专用 runner                                       | hosted runner 约 14 GiB，chromium 构建前先删预装 SDK 腾空间               |
| 权限     | 组织密钥仓库 `imports`                            | `permissions: packages: write` + `GITHUB_TOKEN`                           |

关于 `type=gha` 缓存：它存在 Actions 缓存里，不往 GHCR 推 `buildcache*` 标签，所以 GHCR 上不会出现 CNB 制品库那种缓存标签。三个变体用独立的 `scope`（`alpine-chromium` / `-cjk` / `-headless`），避免互相当成缓存命中；`CACHE_BUST` 每天变化，保证上游 chromium 补丁进得来。

关于 Alpine 为什么不用缓存：它只有一个 `RUN`，命中缓存就等于不装包，每日重建的「刷新依赖」意义会消失（详见 [CNB 流水线](alpine/ci-pipeline.md) 的同名小节）。GitHub 侧沿用这个结论。

## 权限与可见性

- workflow 里显式声明 `permissions: contents: read` + `packages: write`。仓库默认的 `GITHUB_TOKEN` 权限若是只读，推送会报 `denied: permission_denied`，这是第一个要检查的地方。
- 包第一次被推送后，可见性由包自己的设置决定，**不会**自动跟随仓库可见性。需要匿名可拉时，去包页面（`https://github.com/users/<owner>/packages/container/alpine`；chromium 的包名是 `alpine/chromium`，URL 里写作 `alpine%2Fchromium`）把 visibility 改成 public。
- `source` 标签指回仓库后，包会挂在仓库的 Packages 区，仓库权限也才能顺延到包上。
- PR 来自 fork 时 `GITHUB_TOKEN` 只有只读权限，所以 PR 校验作业不登录、不推送，只做本地 `--load` 构建与冒烟。
- 组织仓库如果限制「Actions 创建包」（组织级 Packages 策略），首次推送会被拒；需要管理员放开，或改用有 `write:packages` 的个人访问令牌。

## 手动运行与排错

```bash
# 手动触发（等价于 CNB 的按钮）
gh workflow run build-alpine.yml -f version=3.25.1
gh workflow run build-chromium.yml -f version=3.24.3 -f expected_chromium_major=155

# 看运行状态与下载元数据
gh run list --workflow=build-alpine.yml
gh run watch
gh run download <run-id> -n alpine-annotation
```

| 症状                           | 常见原因                                                            | 先看哪里                                 |
|--------------------------------|---------------------------------------------------------------------|------------------------------------------|
| `denied: permission_denied`    | 缺少 `packages: write`，或包已被别的仓库占用                        | workflow 的 `permissions`、包设置        |
| arm64 阶段 `exec format error` | 少了 QEMU 步骤，或 `platforms: arm64` 没写                          | `setup-qemu-action` 那一步               |
| `no space left on device`      | chromium 三变体 × 两平台的层缓存吃满 14 GiB                         | 「释放磁盘空间」步骤与 `df -h`           |
| 定时任务不跑                   | cron 不是 UTC、不是默认分支、或仓库 60 天无提交被停用               | workflow 的 `on.schedule`                |
| `latest` 没前进                | 冒烟失败（时区、源行数、命令缺失、OCI 标签），脚本在提升前 `exit 1` | 构建步骤日志的「冒烟测试失败」           |
| chromium 构建在断言处失败      | 上游升了 Chromium 主版本，`EXPECTED_CHROMIUM_MAJOR` 不匹配          | 用 `expected_chromium_major` 覆盖        |
| `toomanyrequests`              | Docker Hub 对匿名拉取限流（runner 是共享出口 IP）                   | 构建日志；换镜像源或配置 Docker Hub 凭证 |
| GHCR 上找不到 `buildcache*`    | 预期行为：GitHub 用 Actions 缓存，不推 registry 缓存                | 无需处理                                 |

## 维护约定

- **两份副本要同步**：改镜像内容（`.github/docker/`）或标签/冒烟/元数据（`.github/scripts/`）时，必须同时改 `.cnb/docker/` 与 `.cnb/scripts/` 里的对应实现。PR 里只改一侧，等于让两个 registry 推不同内容的同名标签。
- **平台胶水各自维护**：触发器、时区、缓存后端、元数据落地、action 版本只改自己那一份，不要为了「统一」把 GitHub 侧的逻辑塞进 CNB 的 imports 体系，反之亦然。
- workflow 里用到的 action（`actions/checkout`、`docker/setup-*` 等）版本由 [dependabot](../.github/dependabot.yml) 的 `github-actions` 生态扫描，升级后至少手动跑一次两条流水线。
- 不要在 GitHub workflow 里改用 `docker/build-push-action` 的三行式构建：标签派生、冒烟、提升顺序都在 `.github/scripts/` 里，换成 action 等于把同一份契约再实现一遍。

## 相关文档

- [CNB 流水线（平台层）](cnb.md)
- [Alpine 镜像与标签](alpine/images-and-tags.md)
- [Chromium 镜像与标签](chromium/images-and-tags.md)
- [Alpine CI 流水线（CNB）](alpine/ci-pipeline.md)
- [Chromium CI 流水线（CNB）](chromium/ci-pipeline.md)
- [贡献指南](../CONTRIBUTING.md)
