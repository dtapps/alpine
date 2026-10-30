# Alpine 基础镜像 + Alpine + Chromium 镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security)

本仓库用 CNB 流水线构建两个自建镜像并推送到制品库。两者互不依赖、标签空间互不重叠，共用一层 CI 脚手架与文档。

## 两个镜像

| 镜像                             | 地址                                    | Dockerfile                                               | 构建脚本                         | 文档                                      |
|----------------------------------|-----------------------------------------|----------------------------------------------------------|----------------------------------|-------------------------------------------|
| Alpine 基础镜像                  | `docker.cnb.cool/dtapp/alpine`          | `.cnb/docker/Dockerfile.alpine`                          | `.cnb/scripts/build-alpine.sh`   | [docs/alpine/](docs/alpine/README.md)     |
| Alpine + Chromium 无头浏览器镜像 | `docker.cnb.cool/dtapp/alpine/chromium` | `.cnb/docker/Dockerfile.chromium`、`Dockerfile.headless` | `.cnb/scripts/build-chromium.sh` | [docs/chromium/](docs/chromium/README.md) |

**怎么区分这两个镜像**

- **定位不同**：前者是「进容器就能 `apk add` / `curl` / `dig` / `nc` 的调试基座」，几十 MB；后者是「容器里跑无头浏览器」的运行环境，数百 MB。
- **依赖不同**：Chromium 镜像 `FROM alpine:3.24.3`（官方），**不基于**本仓库的 Alpine 基础镜像；`-headless` 变体再叠在 Chromium 镜像之上（同一批次 digest），只加默认启动参数和 `tini`。
- **发布独立**：两条流水线、两条定时任务（Alpine `00:05`、Chromium `01:30`，刻意错峰），一个坏了不影响另一个。
- **标签独立**：Alpine 用 `latest` / `<alpine 版本>`；Chromium 挂在子路径 `/chromium` 下，用 `latest[-cjk|-headless]` / `<alpine 版本>[-cjk|-headless]`。命名契约各自见 `images-and-tags.md`。

## 快速使用

```bash
# Alpine 基础镜像：进容器调试
docker run --rm -it docker.cnb.cool/dtapp/alpine:latest sh

# Chromium 镜像：无头浏览器（截图 / PDF / E2E）
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest chromium --version
```

作为基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
# 或
FROM docker.cnb.cool/dtapp/alpine/chromium:latest
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
docs/
├── alpine/                         # Alpine 基础镜像文档（README + index + 12 篇）
└── chromium/                       # Chromium 镜像文档（README + index + 12 篇）
```

## 约定

- 提交前跑 `make format`（yamlfmt / markdownfmt / shfmt / dockerfmt）与 `make lint-shell`。
- 标签是对外契约：改名或删除标签要先按各镜像 `images-and-tags.md` 里的兼容流程走；制品库列表里「多架构 / 单平台 / buildcache」和「压缩后 vs 解压后」的口径，见两个镜像 README 的「制品库列表里的标签与数字怎么读」一节。
- 安全报告走 [SECURITY.md](SECURITY.md)，贡献流程与硬性规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 文档入口：[docs/README.md](docs/README.md)。

## 许可

[MIT](LICENSE)
