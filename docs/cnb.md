# CNB 流水线（平台层）

> 和 [GitHub Actions 与 GHCR](github.md) 对称的一篇：讲 CNB 侧怎么触发、镜像地址从哪来、元数据怎么落地、与 GitHub 侧差在哪。镜像自己的流水线细节（每个事件做什么、插件参数、冒烟断言）仍在 [Alpine CI 流水线](alpine/ci-pipeline.md) 与 [Chromium CI 流水线](chromium/ci-pipeline.md)。

## 目录与职责

| 路径                   | 职责                                                            |
|------------------------|-----------------------------------------------------------------|
| `.cnb.yml`             | `include` 列表 + `main` 上的两条定时任务                        |
| `.cnb/workflows/`      | 一个事件一组职责：构建、扫描、评审、文档生成、知识库            |
| `.cnb/docker/`         | CNB 侧的 Dockerfile（alpine / chromium / headless）             |
| `.cnb/scripts/`        | CNB 侧的构建脚本（解析版本、派生标签、冒烟、写元数据）          |
| `.cnb/web_trigger.yml` | 手动按钮、权限、输入项                                          |
| `.cnb/annotation.json` | 构建生成的元数据（`.gitignore` 已排除），由 annotation 插件读取 |
| `.cnb/security/`       | 代码扫描配置                                                    |

GitHub 侧有一份对应的副本（`.github/`），两边不互相引用，见文末「两份副本的同步」。

## 镜像地址不是写死的

CNB 在构建环境里注入了一组内置变量（[官方文档](https://docs.cnb.cool/zh/build/build-in-env.md)），脚本据此拼出镜像名，所以改仓库名、换命名空间、fork 之后都不需要改脚本：

| 变量                      | 用途                                        |
|---------------------------|---------------------------------------------|
| `CNB_DOCKER_REGISTRY`     | registry 主机（本仓库是 `docker.cnb.cool`） |
| `CNB_REPO_SLUG_LOWERCASE` | 仓库路径（本仓库是 `dtapp/alpine`，全小写） |
| `CNB_TOKEN_USER_NAME`     | `docker login` 用户名                       |
| `CNB_TOKEN`               | `docker login` 密码                         |
| `CNB_COMMIT`              | 写进 OCI `revision` 标签                    |

拼装规则（`.cnb/scripts/build-alpine.sh`）：

```sh
IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"          # Alpine 基础镜像
IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/chromium" # Chromium 镜像
```

所以本篇、[README](../README.md) 与各分册里出现的 `docker.cnb.cool/dtapp/alpine` 只是**本仓库当前的实际值**，不是脚本里写死的常量。GitHub 侧同理：`ghcr.io` + `GITHUB_REPOSITORY`（转小写），见 [GitHub Actions 与 GHCR](github.md)。

## 触发矩阵

| 事件                                | 定义位置                                                            | 产物                                                                                                |
|-------------------------------------|---------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `web_trigger_build_alpine`          | `.cnb/workflows/build-alpine.yml`                                   | 解析基座版本 → 一次多架构 `buildx build --push` → 派生单平台标签 → 冒烟 → 提升 `latest` / `<minor>` |
| `web_trigger_build_chromium`        | `.cnb/workflows/build-chromium.yml`                                 | default / `-cjk` / `-headless` 三个变体 + 单平台标签，推到 `<repo>/chromium`                        |
| `'crontab: 5 0 * * *'`              | `.cnb.yml` 的 `main`                                                | 同 Alpine 手动构建；定时任务不传 `version`，走 Dockerfile 默认的 `alpine:latest`                    |
| `'crontab: 30 1 * * *'`             | `.cnb.yml` 的 `main`                                                | 同 Chromium 手动构建；与 Alpine 错峰                                                                |
| `pull_request`                      | `.cnb/workflows/build-chromium.yml`                                 | 只构建不推送，验 chromium 的 Dockerfile 与渲染冒烟                                                  |
| `push`                              | `.cnb/workflows/{sca,knowledge-base}.yml`                           | SCA 报告、知识库索引                                                                                |
| `pull_request`                      | `.cnb/workflows/{code-review,cnb-sechook,code-security-config}.yml` | PR 评论、扫描与敏感信息统计、配置校验                                                               |
| `tag_push` / `web_trigger_codewiki` | `.cnb/workflows/codewiki.yml`                                       | Code Wiki                                                                                           |

定时任务只在 `main` 顶层键下声明，所以只对默认分支生效；时间按 `Asia/Shanghai` 解释（`.cnb.yml` 里直接写北京时间）。

## 按钮、权限与输入

`.cnb/web_trigger.yml` 定义手动入口，`event` 必须与 workflow 文件里的事件键逐字一致，否则按钮点下去不会产生流水线：

| 按钮                                       | event                        | 权限                       | 输入                                                |
|--------------------------------------------|------------------------------|----------------------------|-----------------------------------------------------|
| 打包 Alpine 镜像（多架构 amd64 + arm64）   | `web_trigger_build_alpine`   | owner / master / developer | `version`：留空 = 跟随 `alpine:latest`              |
| 打包 Chromium 镜像（多架构 amd64 + arm64） | `web_trigger_build_chromium` | owner / master / developer | `version`（Alpine 版本）、`expected_chromium_major` |
| 生成 Code Wiki                             | `web_trigger_codewiki`       | owner / master / developer | 无                                                  |

输入值的白名单校验在脚本里（`version` 只接受 `latest` / `3.25` / `3.25.1` / `3.25.1@sha256:…`），所以按钮上写错不会跑一半才失败。

## imports 与凭证

两条构建流水线都 `imports` 组织的 `https://cnb.cool/dtapp/envs/-/blob/main/docker.yml`，它提供上面那组 `CNB_*` 变量。这是**可变引用**：上游改了 `main`，下一次构建就跟着变；仓库里因此不存任何凭证，直接用组织密钥仓库注入的 `CNB_TOKEN` / `CNB_TOKEN_USER_NAME`。

不要把 `.cnb/scripts/*.sh` 放进 `imports`：imports 会做变量处理，脚本里的 `${...}` 会被改写成字面量。脚本在仓库里，由流水线的 `source` 直接执行。

## 元数据与徽章

构建脚本把本次产物的 digest、版本、体积写到 `.cnb/annotation.json`，`cnbcool/annotations` 插件以 `type: ADD` + `fromJsonFile` 写进 commit annotation，README 徽章从 `/-/badge/annotation/commit/latest/{key}` 读取。键分两组：Alpine 用 `image_*`，Chromium 用 `chromium_*` 前缀，避免同一个 commit 上互相覆盖。

## 与 GitHub 侧的差异

| 维度     | CNB                                                         | GitHub Actions                                                 |
|----------|-------------------------------------------------------------|----------------------------------------------------------------|
| 地址来源 | `CNB_DOCKER_REGISTRY` + `CNB_REPO_SLUG_LOWERCASE`           | `ghcr.io` + `GITHUB_REPOSITORY`（小写）                        |
| 登录凭证 | `CNB_TOKEN` / `CNB_TOKEN_USER_NAME`（组织密钥仓库 imports） | `secrets.GITHUB_TOKEN`（Actions 临时签发）                     |
| builder  | `services: docker` 自带多架构 buildx                        | `docker/setup-qemu-action` + `docker/setup-buildx-action` 现装 |
| arm64    | runner 内置 binfmt                                          | QEMU 模拟（chromium 三变体多架构要几十分钟）                   |
| 缓存     | Alpine 不用；Chromium 用 registry cache（`buildcache*`）    | Alpine 不用；Chromium 用 Actions 缓存（`type=gha`）            |
| 定时任务 | `main` 下 `crontab`，北京时间 00:05 / 01:30                 | `on.schedule`，UTC 16:35 / 18:00（= 北京时间 00:35 / 02:00）   |
| 元数据   | `.cnb/annotation.json` → commit annotation → 徽章           | `.github/annotation.json` → Step Summary + artifact            |
| 手动入口 | `web_trigger.yml` 按钮 + 输入项                             | `workflow_dispatch` + inputs                                   |

标签契约两边一致（`<alpine 版本>` / `<major.minor>` / `latest` + `-linux-{arch}` 派生），但各自构建、digest 不通用。

## 两份副本的同步

`.cnb/` 与 `.github/` 是**有意复制**的两份实现：平台胶水（变量来源、缓存、元数据落地、触发器）各自维护；镜像内容、标签规则、冒烟断言**必须两边一起改**（见 [CONTRIBUTING](../CONTRIBUTING.md) 硬性规则）。只改一侧会让两个 registry 推出不同内容的同名标签。

## 排错入口

| 症状                               | 常见原因                                                                    | 先看哪里                          |
|------------------------------------|-----------------------------------------------------------------------------|-----------------------------------|
| 点按钮没有任何流水线产生           | `web_trigger.yml` 的 `event` 与 workflow 事件键不一致，或文件没进 `include` | 按钮定义、`.cnb.yml` 的 `include` |
| 脚本报 version 非法                | 输入不是 `latest` / `3.25` / `3.25.1` / `3.25.1@sha256:<64hex>`             | 白名单校验的报错输出              |
| `sed: can't read "${DOCKERFILE…}"` | 脚本被当成 import 处理，`${...}` 被改写                                     | `.cnb.yml` 的 `imports` 列表      |
| 冒烟失败、`latest` 没更新          | 基座版本前缀、时区、源行数、命令缺失、OCI 标签不符                          | 冒烟步骤的断言输出                |
| 徽章显示 `unknown`                 | 元数据解析失败（体积记 `-1`）或 digest 未取到                               | 日志里的「体积解析失败」行        |
| 定时任务不生效                     | 定时任务只在 `main` 顶层键下声明，或仓库 60 天无活动被平台停用              | `.cnb.yml`、平台设置              |

## 相关文档

- [GitHub Actions 与 GHCR](github.md)
- [Alpine CI 流水线](alpine/ci-pipeline.md)
- [Chromium CI 流水线](chromium/ci-pipeline.md)
- [贡献指南](../CONTRIBUTING.md)
- [CNB 内置环境变量（官方）](https://docs.cnb.cool/zh/build/build-in-env.md)
