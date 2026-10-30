# 文档索引

本仓库两个镜像的文档分开维护，结构对称：每个镜像都有自己的「速查页 + 分册索引 + 12 篇分册」。

| 镜像                             | 速查                                     | 分册索引                               | 分册数量 |
|----------------------------------|------------------------------------------|----------------------------------------|----------|
| Alpine 基础镜像                  | [alpine/README.md](alpine/README.md)     | [alpine/index.md](alpine/index.md)     | 12 篇    |
| Alpine + Chromium 无头浏览器镜像 | [chromium/README.md](chromium/README.md) | [chromium/index.md](chromium/index.md) | 12 篇    |

## 先选镜像

| 你要做的事                                   | 看这里                                                      |
|----------------------------------------------|-------------------------------------------------------------|
| 容器里要 `curl` / `dig` / `nc` 这类排障工具  | [Alpine 基础镜像](alpine/README.md)                         |
| 容器里要跑无头浏览器（截图、PDF、E2E）       | [Chromium 镜像](chromium/README.md)                         |
| 两个都要，或想把浏览器装在带排障工具的基座上 | 分别拉两个镜像，或基于 Chromium 镜像派生（见其 `build.md`） |

## 两个镜像的关系

- **互不依赖**：Chromium 镜像 `FROM alpine:3.24.3`（官方），不基于本仓库的 Alpine 基础镜像；`-headless` 变体叠在 Chromium 镜像之上。
- **发布独立**：两条流水线、两条定时任务（Alpine `00:05`、Chromium `01:30`），互不影响。
- **标签独立**：Alpine 在 `dtapp/alpine`，Chromium 在子路径 `dtapp/alpine/chromium`，标签命名规则各自固定。
- **共用部分**：根目录的 [CONTRIBUTING.md](../CONTRIBUTING.md)、[SECURITY.md](../SECURITY.md)、`Makefile` 与 `.cnb/workflows/` 里与构建无关的扫描/评审流水线。

## 文档怎么组织

每套文档的结构相同，只是内容各讲各的镜像：

| 文档                     | 内容                                               |
|--------------------------|----------------------------------------------------|
| `README.md`              | 一页速查：镜像里有什么、怎么拉、怎么触发构建       |
| `index.md`               | 分册索引：按目的找入口，以及「事实来源」与维护约定 |
| `dockerfile.md`          | Dockerfile 逐段解析、包清单与体积取舍              |
| `images-and-tags.md`     | 镜像地址与标签契约、digest 固定方式                |
| `build.md`               | 本地与 CI 构建、buildx 用法                        |
| `ci-pipeline.md`         | 事件矩阵、按钮与权限、imports、插件职责            |
| `metadata-and-badges.md` | 元数据键、写入链路、徽章、按平台算体积             |
| `security-baseline.md`   | 攻击面、扫描能力、排除规则                         |
| `mirrors.md`             | APK 源顺序与失效处置                               |
| `getting-started.md`     | 快速上手与常见用法                                 |
| `maintenance.md`         | 补丁节奏、版本升级、周期性检查                     |
| `troubleshooting.md`     | 症状到处置的排查手册                               |
| `formatting.md`          | `make format` 与各格式化器配置                     |

## 共用文档

- [CONTRIBUTING.md](../CONTRIBUTING.md) —— 贡献流程、硬性规则、PR 检查清单
- [SECURITY.md](../SECURITY.md) —— 支持范围、漏洞报告渠道、已知取舍
- [README.md](../README.md) —— 仓库总览：两个镜像一览、快速使用、仓库结构
