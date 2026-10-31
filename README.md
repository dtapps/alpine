# Alpine 基础镜像 + Alpine + Chromium 镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security) [![build-alpine](https://github.com/dtapps/alpine/actions/workflows/build-alpine.yml/badge.svg)](https://github.com/dtapps/alpine/actions/workflows/build-alpine.yml) [![build-chromium](https://github.com/dtapps/alpine/actions/workflows/build-chromium.yml/badge.svg)](https://github.com/dtapps/alpine/actions/workflows/build-chromium.yml)

本仓库用两套流水线构建两个自建镜像：CNB 推送到制品库（`docker.cnb.cool/dtapp/alpine`），GitHub Actions 推送到 GHCR（`ghcr.io/dtapps/alpine`）。两个平台各维护一份 Dockerfile 与构建脚本（有意复制，不互相引用），标签契约保持一致；改镜像内容或标签规则时两份都要改，见 [docs/github.md](docs/github.md)。

## 两个镜像

| 镜像                             | CNB 地址                                | GitHub 地址（GHCR）              | Dockerfile（CNB / GitHub）                                                                     | 文档                                      |
|----------------------------------|-----------------------------------------|----------------------------------|------------------------------------------------------------------------------------------------|-------------------------------------------|
| Alpine 基础镜像                  | `docker.cnb.cool/dtapp/alpine`          | `ghcr.io/dtapps/alpine`          | `.cnb/docker/Dockerfile.alpine` / `.github/docker/Dockerfile.alpine`                           | [docs/alpine/](docs/alpine/README.md)     |
| Alpine + Chromium 无头浏览器镜像 | `docker.cnb.cool/dtapp/alpine/chromium` | `ghcr.io/dtapps/alpine/chromium` | `.cnb/docker/Dockerfile.{chromium,headless}` / `.github/docker/Dockerfile.{chromium,headless}` | [docs/chromium/](docs/chromium/README.md) |

构建脚本同样是两份副本：CNB 用 `.cnb/scripts/build-*.sh`，GitHub 用 `.github/scripts/build-*.sh`。两侧的标签名、提升顺序、冒烟断言必须保持一致，平台胶水（触发器、缓存、元数据落地）各自维护。

**怎么区分这两个镜像**

- **定位不同**：前者是「进容器就能 `apk add` / `curl` / `dig` / `nc` 的调试基座」，几十 MB；后者是「容器里跑无头浏览器」的运行环境，数百 MB。
- **依赖不同**：Chromium 镜像 `FROM alpine:3.24.3`（官方），**不基于**本仓库的 Alpine 基础镜像；`-headless` 变体再叠在 Chromium 镜像之上（同一批次 digest），只加默认启动参数和 `tini`。
- **发布独立**：两条流水线、两条定时任务（Alpine `00:05`、Chromium `01:30`，刻意错峰），一个坏了不影响另一个；CNB 与 GitHub 各有一份同样的定时任务，互相不等待。
- **标签独立**：Alpine 用 `latest` / `<alpine 版本>`；Chromium 挂在子路径 `/chromium` 下，用 `latest[-cjk|-headless]` / `<alpine 版本>[-cjk|-headless]`。命名契约各自见 `images-and-tags.md`。

## 快速使用

```bash
# 拉 CNB 制品库或 GHCR 都行，标签规则一致
docker run --rm -it docker.cnb.cool/dtapp/alpine:latest sh
docker run --rm -it ghcr.io/dtapps/alpine:latest sh

# Chromium 镜像：无头浏览器（截图 / PDF / E2E）
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest chromium --version
docker run --rm ghcr.io/dtapps/alpine/chromium:latest chromium --version
```

作为基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
# 或
FROM ghcr.io/dtapps/alpine:latest
# Chromium 同理：ghcr.io/dtapps/alpine/chromium:latest
```

## 仓库结构

```text
.cnb/
├── docker/
│   ├── Dockerfile.alpine           # Alpine 基础镜像
│   ├── Dockerfile.chromium         # Chromium 镜像（default 变体）
│   └── Dockerfile.headless         # Chromium 的 -headless 变体
├── scripts/
│   ├── build-alpine.sh             # Alpine 基础镜像构建
│   └── build-chromium.sh           # Chromium 镜像构建（三个变体一次跑完）
├── workflows/                      # build-alpine.yml / build-chromium.yml / 扫描与评审流水线
└── web_trigger.yml                 # 两个镜像各一个手动按钮
.github/
├── docker/                         # GitHub 侧的 Dockerfile 副本（alpine / chromium / headless）
├── scripts/                        # GitHub 侧的构建脚本副本（build-alpine.sh / build-chromium.sh）
├── workflows/
│   ├── build-alpine.yml            # GitHub 平台：构建并推送 ghcr.io/<owner>/<repo>
│   └── build-chromium.yml          # GitHub 平台：构建并推送 ghcr.io/<owner>/<repo>/chromium
├── annotation.json                 # CI 生成的镜像元数据（.gitignore 已排除）
└── dependabot.yml                  # GitHub Actions 依赖更新
docs/
├── alpine/                         # Alpine 基础镜像文档（README + index + 12 篇）
├── chromium/                       # Chromium 镜像文档（README + index + 12 篇）
├── cnb.md                          # CNB 平台层说明（内置变量与地址来源、按钮、元数据）
└── github.md                       # GitHub Actions / GHCR 平台说明（两份副本的同步规则）
```

## 约定

- 提交前跑 `make format`（yamlfmt / markdownfmt / shfmt / dockerfmt）与 `make lint-shell`；范围包含 `.cnb/` 与 `.github/` 两侧的脚本、Dockerfile 与 workflow。
- 标签是对外契约：改名或删除标签要先按各镜像 `images-and-tags.md` 里的兼容流程走；制品库列表里「多架构 / 单平台 / buildcache」和「压缩后 vs 解压后」的口径，见两个镜像 README 的「制品库列表里的标签与数字怎么读」一节。
- 两个平台的 Dockerfile 与脚本是两份副本（`.cnb/` 与 `.github/`）：改镜像内容、标签规则或冒烟断言时两处都要改；只改平台胶水时各改各的。平台层说明见 [docs/cnb.md](docs/cnb.md) 与 [docs/github.md](docs/github.md)。
- 安全报告走 [SECURITY.md](SECURITY.md)，贡献流程与硬性规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 文档入口：[docs/README.md](docs/README.md)。

## 许可

[MIT](LICENSE)
