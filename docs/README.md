# 文档索引

本仓库两个镜像的文档分开维护，结构对称：每个镜像都有自己的「速查页 + 分册索引 + 12 篇分册」。

| 镜像                             | 速查                                     | 分册索引                               | 分册数量 |
|----------------------------------|------------------------------------------|----------------------------------------|----------|
| Alpine 基础镜像                  | [alpine/README.md](alpine/README.md)     | [alpine/index.md](alpine/index.md)     | 12 篇    |
| Alpine + Chromium 无头浏览器镜像 | [chromium/README.md](chromium/README.md) | [chromium/index.md](chromium/index.md) | 12 篇    |

## 先选镜像

| 你要做的事                                  | 看这里                                                                                                            |
|---------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| 容器里要 `curl` / `dig` / `nc` 这类排障工具 | [Alpine 基础镜像](alpine/README.md)                                                                               |
| 容器里要跑无头浏览器（截图、PDF、E2E）      | [Chromium 镜像](chromium/README.md)                                                                               |
| 两个都要                                    | 直接用 Chromium 镜像：它已叠在本仓库的 Alpine 基座上，继承 `curl` / `nc` / `drill` / `git`；缺 `dig` 等再派生一层 |

## 两个镜像的关系

- **有依赖**：Chromium 镜像 `FROM` 本仓库构建的 Alpine 基础镜像（CI 按 `<仓库 slug>:<alpine 版本>` 解析实际版本与 digest 钉住），因此自动继承基座的时区、APK 源与 `curl` / `nc` / `drill` / `git`。Dockerfile 的默认基座是官方 `alpine:${ALPINE_VERSION}`，只用于不依赖私有仓库的本地构建。`-headless` 只是本地派生配方，CI 不发布。
- **发布有先后**：两条流水线、两条定时任务，Alpine `00:05` 先产基座，Chromium `01:05` 再消费；基座标签不存在时 Chromium 构建直接失败。
- **标签同构**：两个镜像都用 `<alpine 版本>` / `<major.minor>` / `latest` / `<版本>-linux-{amd64,arm64}` 这 5 个标签；Chromium 在子路径 `dtapp/alpine/chromium`，命名空间独立。
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
| `mirrors.md`             | APK 源策略与失效处置                               |
| `getting-started.md`     | 快速上手与常见用法                                 |
| `maintenance.md`         | 补丁节奏、版本升级、周期性检查                     |
| `troubleshooting.md`     | 症状到处置的排查手册                               |
| `formatting.md`          | `make format` 与各格式化器配置                     |

## 共用文档

- [CONTRIBUTING.md](../CONTRIBUTING.md) —— 贡献流程、硬性规则、PR 检查清单
- [SECURITY.md](../SECURITY.md) —— 支持范围、漏洞报告渠道、已知取舍
- [README.md](../README.md) —— 仓库总览：两个镜像一览、快速使用、仓库结构
- [cnb.md](cnb.md) —— CNB 平台层：内置变量与地址来源、事件矩阵、按钮/权限、imports、元数据、排错
- [github.md](github.md) —— GitHub Actions 与 GHCR：两份副本的目录与同步规则、触发矩阵、变量契约、与 CNB 的差异
- [cache-implementation.md](cache-implementation.md) —— 构建缓存实现：APK 索引指纹、registry 缓存、`CACHE` 开关与回滚

## 平台与流水线文档

两个平台的文档结构对称：平台层一篇（触发、地址、权限、元数据），镜像层的流水线细节仍放在各镜像分册里。

| 平台           | 平台层文档             | 镜像层文档                                                                                         |
|----------------|------------------------|----------------------------------------------------------------------------------------------------|
| CNB            | [cnb.md](cnb.md)       | [alpine/ci-pipeline.md](alpine/ci-pipeline.md)、[chromium/ci-pipeline.md](chromium/ci-pipeline.md) |
| GitHub Actions | [github.md](github.md) | 同上（镜像细节与平台无关，两份副本保持一致）                                                       |
