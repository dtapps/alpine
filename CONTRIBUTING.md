# 贡献指南

本仓库只做一件事：构建两个自建镜像（Alpine 基础镜像、Chromium 镜像；`Dockerfile.headless` 只是本地派生配方，CI 不发布），由 CNB 与 GitHub Actions 两套流水线分别推送到 CNB 制品库与 GHCR。两个平台各维护一份 Dockerfile 与构建脚本（`.cnb/` 与 `.github/`，有意复制、不互相引用）。它没有应用代码、没有测试用例，所以「贡献」通常意味着改 Dockerfile、改构建脚本，或修文档——注意镜像内容与标签规则是两份副本，要一起改。Chromium 镜像的细节见 [`docs/chromium/`](docs/chromium/README.md)，两个平台的发布方式见 [`docs/cnb.md`](docs/cnb.md) 与 [`docs/github.md`](docs/github.md)。

安全问题的报告渠道在 [SECURITY.md](SECURITY.md)，不要用 issue 报敏感问题。

## 环境准备

- Docker（需要 `buildx`）
- 格式化与静态检查工具：`yamlfmt`、`markdownfmt`、`shfmt`、`dockerfmt`、`shellcheck`

```bash
brew install shfmt yamlfmt markdownfmt dockerfmt shellcheck
# 或 go install mvdan.cc/sh/v3/cmd/shfmt@latest 等对应模块
```

## 可以改什么

| 路径                               | 作用                               | 注意                                     |
|------------------------------------|------------------------------------|------------------------------------------|
| `.cnb/docker/Dockerfile.alpine`    | CNB 侧：基座引用、APK 源、包、时区 | 与 `.github/docker/` 同名文件同步        |
| `.github/docker/Dockerfile.alpine` | GitHub 侧：同上                    | 与 `.cnb/docker/` 同名文件同步           |
| `.cnb/scripts/build-alpine.sh`     | CNB 侧：构建、标签、冒烟、元数据   | POSIX `sh`；失败要显式 `exit 1`          |
| `.github/scripts/build-alpine.sh`  | GitHub 侧：同上                    | 与 CNB 侧同步标签/冒烟规则               |
| `.cnb/workflows/*.yml`             | CNB 各事件对应的流水线             | 同步 `.cnb/web_trigger.yml`              |
| `.github/workflows/*.yml`          | GitHub Actions 流水线（推 GHCR）   | 只维护平台胶水（触发器/缓存/元数据落地） |
| `.cnb.yml`                         | include 列表与定时任务             | 定时任务不传 `version`                   |
| `.cnb/security/`、`.scanignore`    | 安全扫描配置                       | 只在确认误报时加排除                     |
| `.dockerignore`                    | 构建上下文排除项                   | 别排掉两个平台的 Dockerfile              |
| `README.md`                        | 使用文档                           | 行为变了就同步                           |
| `docs/`                            | 分册文档（索引 `docs/README.md`）  | 行为变了同步分册并更新索引               |

## 提交前必做

1. 跑 `make format`。YAML / Markdown / Shell / Dockerfile 四类统一格式化（范围含 `.cnb/` 与 `.github/` 两侧的 workflow、脚本、Dockerfile），CI 不校验格式，但 diff 里混进格式噪音会拖慢评审。改了任一脚本再跑一次 `make lint-shell`（`shellcheck -s sh`）；改了 `.github/workflows/` 跑一次 `actionlint`。
2. 本地构建一次，确认镜像仍可用：

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .   # 默认 ALPINE_VERSION=latest
docker run --rm alpine:local sh -c 'cat /etc/alpine-release; command -v curl drill git nc nslookup; date +%Z'
docker run --rm alpine:local sh -c 'wc -l </etc/apk/repositories; cat /etc/timezone'
docker history alpine:local
```

默认构建就等于 cron 每天做的事（取当时上游最新的 alpine）。要验某个特定版本，加 `--build-arg ALPINE_VERSION=3.25.1`；只想验证自己的改动、不想被上游当天的变化干扰时，也应该这样钉一下，否则失败原因可能不在你的改动上。

`docker history` 里除基础镜像自带的层之外只应多出一层。多出第二层通常意味着有人把清理或者某一步拆成了独立的 `RUN`。

3. 改了推送逻辑的话，先用自己 fork 的路径试推，别拿 `docker.cnb.cool/dtapp/alpine` 做实验性推送。

## 硬性规则

- **不提交任何凭证**。CNB 侧脚本只允许通过 `${CNB_TOKEN}` / `${CNB_TOKEN_USER_NAME}` 取值（真实凭证在组织密钥仓库 `imports`）；GitHub 侧由 workflow 注入 `REGISTRY_TOKEN`（`GITHUB_TOKEN`），仓库里不存长期凭证。登录一律走 `--password-stdin`，不要用 `-p`（进程参数在 `ps` 里可见）。写死 token 会被敏感信息扫描拦下，但别指望扫描兜底。
- **不加不必要的包**。这个镜像的卖点是体积：新增包要在 PR 里说明「解决什么场景」「大约增加多少体积」。看体积要看**依赖闭包**而不是单包——`curl` 自身 0.27 MiB，带依赖实际 5.06 MiB。能用 `--no-cache` 的不留缓存，具体数字见 [Dockerfile 解析](docs/alpine/dockerfile.md)。
- **清理必须与安装同层**。`/var/cache/apk`、`/tmp`、`/root/.cache` 的清理如果和安装分在两个 `RUN` 里，后一层的 `rm` 只会写下 whiteout，被删的数据照样随镜像分发。「另开一层专门清理」是旧写法，现在不成立。新增 `RUN` 只有两种合法形态：并入现有的那一层，或者自带同层清理（在同一个 `RUN` 里装完就删）。
- **只有一个 `RUN` 是结果，不是约束**。如果确有必要加第二个 `RUN`（例如某个操作必须与 `apk` 分离），PR 里要说明为什么不能并入，以及它自己的清理怎么做。
- **基座默认跟随上游，钉版本要说明理由**。`ARG ALPINE_VERSION=latest` 是刻意的默认值：定时任务每天重建，就是为了把上游的补丁和新小版本吃进来。需要固定某个版本时，用 `--build-arg ALPINE_VERSION=3.25.1`（或在按钮里填 `3.25.1` / `3.25.1@sha256:<64 位 hex>`），**不要改默认值**——把默认改成具体版本等于让整个仓库停止跟进上游，PR 里必须写清楚为什么以及打算什么时候恢复。具体版本号不靠人记：构建脚本会把 `latest` 解析成 `3.25.1` 写进标签与 OCI label，产物永远可追溯。
- **APK 源按平台区分，都用 `sed` 替换主机名**。CNB 侧把 `dl-cdn.alpinelinux.org` 换成腾讯云，GitHub 侧不换源；两边都保留基座自带的 `main` + `community` 两行，不手写源列表。调整主机名、增删行都要说明理由；要删 `community` 必须确认镜像里没有依赖它的包。
- **Shell 风格固定**：`#!/bin/sh` + `set -eu`，`shfmt -w -i 2 -ci -bn -s -ln posix`（`make format-shell`），只用 POSIX 语法——不用 `local`、`[[ ]]`、`${var,,}`、herestring。脚本是被 `source` 执行的，不要在里面的命令上加 `set -x`，也不要把 token 打进日志。
- **两份副本必须同步**。`.cnb/docker/` 与 `.github/docker/`、`.cnb/scripts/` 与 `.github/scripts/` 是有意复制的两份实现：改镜像内容、标签规则、冒烟断言时**两处都要改**，只改一侧会让两个 registry 推出不同内容的同名标签；只改平台胶水（触发器、时区、缓存后端、元数据落地、APK 源）时才各改各的。两个平台各推各的 registry，digest 互不通用。
- **标签命名是对外契约，只有三种**：`<alpine 版本>`（如 `3.25.1`）、`<major.minor>`（如 `3.25`）、`latest`，外加版本标签的 `-linux-amd64` / `-linux-arm64` 派生形式。它们都不带日期，也都**允许每天移动**：
  - `<alpine 版本>`：构建阶段直接推送，同一天/同版本重建会把同名标签覆盖成新产物；
  - `<major.minor>` 与 `latest`：冒烟通过后由版本标签提升，冒烟失败则不动，因此只会前进、不会后退。 三者都不承诺内容稳定，要定位「某一份」只能用元数据里的 `image_digest`。**PR 里不要引入新的标签维度**（加日期、加提交 sha、加 `-edge` 之类）：下游只按这三种消费，多一个维度就多一套语义要维护。
- **`.scanignore` 排除面保持最小**。每加一条都要写明为什么它是噪音。

## 分支与提交信息

- 分支：`feat/xxx`、`fix/xxx`，对 `main` 提 PR。
- 提交信息用 Conventional Commits + 中文描述，与现有历史保持一致：

```text
feat(dockerfile): 增加 jq 便于脚本里解析 JSON
fix(script): 修正 arm64 体积统计取到 index 的问题
chore(dockerfile): 基座跟随上游，重新构建以吃到 3.25.x 补丁
docs: 补充元数据徽章的读取方式
```

## PR 检查清单

- [ ] `make format` 已跑，没有格式 diff；改了脚本则 `make lint-shell` 通过
- [ ] 本地单架构构建通过，容器内 `date +%Z` 显示 `CST`、`/etc/alpine-release` 有输出
- [ ] `/etc/apk/repositories` 仍是两行 `main` + `community`：CNB 主机是腾讯云，GitHub 是官方源
- [ ] `docker history` 里除基础层外只有一层
- [ ] 新增包在 PR 描述里写清用途与依赖闭包体积代价
- [ ] 若把默认基座从 `latest` 改成具体版本，写清原因与恢复计划
- [ ] 镜像内容 / 标签 / 冒烟变更已同时改 `.cnb/` 与 `.github/` 两份副本（只改一侧视为未完成）
- [ ] 行为变更已同步到 `README.md`，以及 `docs/` 下对应的分册
- [ ] 没有新增凭证，没有放宽 `.scanignore`
