# 安全策略

本仓库是一个自建镜像仓库，目前包含两个镜像：Alpine 基础镜像（`.cnb/docker/Dockerfile.alpine`，Alpine 官方源提供的 `ca-certificates`、`curl`、`drill`、`git`、`netcat-openbsd`、`tzdata`）与 Chromium 无头浏览器镜像（`.cnb/docker/Dockerfile.chromium`；`.cnb/docker/Dockerfile.headless` 只是本地/下游派生配方，CI 不发布）。Chromium 镜像 `FROM` 本仓库构建的 Alpine 基础镜像（CI 按 digest 钉住），因此同时继承基座的工具、时区与 APK 源配置；CNB 侧再覆写源以引入 `community` 里的 `chromium` 及其图形/渲染依赖，GitHub 侧沿用官方源（已含 `community`）；制品推送到子路径 `/chromium`。两者都没有业务代码，也没有自研二进制。

下文的支持范围、标签与信任面以 **Alpine 基础镜像**为主；Chromium 镜像的攻击面、扫描口径与取舍见 [`docs/chromium/security-baseline.md`](docs/chromium/security-baseline.md)。

## 支持范围

| 项目                                          | 状态                                                                  |
|-----------------------------------------------|-----------------------------------------------------------------------|
| `<版本>`（如 `3.25.1`，解析出的 alpine 版本） | 版本标签：每次构建推送，同名标签每天被覆盖，不是固定点                |
| `latest`、`<MINOR>`（如 `3.25`）              | 每天 `00:05`（Asia/Shanghai）重建一次，冒烟测试通过后才提升到当天产物 |
| `*-linux-amd64` / `*-linux-arm64` 单平台标签  | 由版本标签 `imagetools create` 派生，同样每天被覆盖                   |
| 历史镜像（旧 digest）                         | 不回溯修复，用完即弃；只能靠当时记下的 `image_digest` 找回            |

一句话：这个镜像的补丁节奏等于上游 Alpine 的补丁节奏。`FROM alpine:latest` 且装包层的缓存键里带 APK 索引指纹，所以每次重建都会重新解析包索引、跟到上游当天的稳定版：索引没变就命中缓存，有任何包升级就重装；包级补丁与新 point release 最迟次日自动进入镜像。上游已修而你的镜像还是旧 digest 时，重新触发一次构建即可，详见[维护手册](docs/alpine/maintenance.md)。

## 如何报告问题

先判断属于哪一类，避免把一个上游 CVE 当成仓库漏洞：

| 类型                     | 例子                                                                                    | 渠道                                                                  |
|--------------------------|-----------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| 本仓库的配置或流水线问题 | 脚本里写死凭证、`Dockerfile` 引入了不该有的包、流水线权限过宽、`.scanignore` 排除面过大 | 开 issue 或直接提 PR（见 [CONTRIBUTING.md](CONTRIBUTING.md)）         |
| 上游 Alpine 包漏洞       | `curl`、`openssl`、`tzdata` 等的 CVE                                                    | 上游修复后重新构建即可；若上游已发布新版而本镜像未跟上，开 issue 提醒 |
| 敏感问题                 | 凭证泄露、可篡改制品的配置缺陷                                                          | **不要开公开 issue**，见下                                            |

敏感问题的报告方式：邮件联系维护者 `li.gc@icloud.com`（与 git 提交记录中的作者邮箱一致），标题前缀 `[security] dtapp/alpine`。在修复发布前请不要公开细节。

## 一份有用的报告包含什么

- 涉及哪个镜像：**完整 digest**（Commit → 元数据里的 `image_digest`，或 `docker buildx imagetools inspect` 取），只给 tag 无法定位到具体产物
- 影响平台：amd64 / arm64 / 多架构
- 复现方式：容器内命令，或构建时传入的 `version`
- 你的判断：镜像自身问题，还是上游包问题

## 已有防护

- 每天 `00:05` 重建一次：装包层按 APK 索引指纹失效 + `FROM alpine:latest`，包级补丁与新 point release 最迟次日进入镜像
- 构建前校验 `version` 白名单（只接受 `空|latest|3.25|3.25.1|3.25.1@sha256:<64hex>`），避免非法值进入 `FROM` 引用
- 用户输入与标签名、`FROM` 引用之间没有自由拼接：标签名取的是容器内解析出来的实际版本，`latest` 永远进不了标签，也不会被误写成任意 tag
- 提升 `latest` 前先跑六项冒烟断言（基座版本前缀、时区、日期偏移、源行数、五个命令、OCI 标签版本），失败则移动标签不动
- 登录用 `docker login --password-stdin`，token 不进入命令行参数；脚本退出时删除 `~/.docker/config.json`
- SCA 流水线在 push 与 PR 上扫描 `Dockerfile` 的依赖：`cnbcool/sca-vulnerability`、`sca-license`、`sca-sbom` （见 `.cnb/workflows/sca.yml`）
- 平台内置代码安全扫描（敏感信息 + 开源组件），排除规则集中在 `.scanignore`，目前只排除了两张二进制图片资源
- 仓库内不存任何凭证：流水线通过 `imports` 从组织密钥仓库取 `CNB_TOKEN`
- 每次构建把 `image_digest`、`image_version`、`alpine_version`、`base_digest` 写入 commit 元数据：既知道产物是哪一份，也知道它当时吃的是哪个基座

## 已知取舍（属于设计选择，不是漏洞）

- **容器内是 root**：这是基础调试镜像，`Dockerfile` 里显式写了 `USER root` 并注明理由——需要降权的下游自行 `adduser` + `USER`，比在基础镜像里预设一个用户更不容易踩坑（预设 UID 会被所有派生镜像继承）。
- **不含 `ENTRYPOINT` / `CMD` / `HEALTHCHECK`**：入口点与健康检查属于应用语义，基础镜像设了会被所有下游继承。 镜像的默认行为就是 `FROM alpine` 的默认行为。
- **预装了 `netcat-openbsd` 与 `drill`**：它们能发起网络连接、做 DNS 查询。若你的场景不允许，请基于本镜像裁剪， 而不是要求从这里移除。`drill` 是 `dig` 的轻量替代（换成 `bind-tools` 会多 6.6 MiB、闭包 17 个包）。
- **基座刻意浮动 + 标签每天覆盖**：`FROM alpine:latest` 让补丁自动进来，代价是无法「同一份源码重跑出逐字节相同的镜像」，标签也不能当固定点。可复现靠四样东西：`image_digest`（哪一份产物）、`built_at`（什么时候构建）、`alpine_version`（哪个基座版本）、`base_digest`（当时基座是哪一份）。要位级复现时显式传 `version=3.25.1@sha256:<digest>`。
- **APK 源按平台区分**：CNB 侧用 `sed` 把主机名换成腾讯云，保留基座自带的 `main` + `community` 两行，供应链信任面包含 Docker Hub 的 `alpine:latest` 与该镜像站；GitHub 侧不换源，直接用官方 `dl-cdn.alpinelinux.org`（同样是 `main` + `community` 两行）。
- **Chromium 依赖本仓库基座产物**：CI 不直接 `FROM alpine:latest`，而是先按 `version` 选基座标签、从容器读实际 Alpine 版本，再解析 `<仓库 slug>:<alpine 版本>` 的 digest 钉住；基座流水线失败或标签缺失会让 Chromium 无法重建。这是有意的耦合——两边工具链、时区与源策略保持一致——代价是发布顺序固定为基座先行，且基座成为 Chromium 供应链上的一环。
- **未接入镜像层漏洞扫描**：当前扫描覆盖的是 `Dockerfile` 里的依赖声明，不是镜像层内的二进制。需要层扫描请在自己的 流水线里加 Trivy 之类的工具。
- **镜像未签名**：制品库只负责存储与分发，不校验来源真实性。需要强校验时，用 commit 元数据里的 `image_digest` 以 digest 形式固定拉取。
- **构建工具链未钉版本**：`imports` 里的环境变量引用指向组织仓库的 `main`，插件（如 `cnbcool/annotations`）按 `:latest` 引用。这两处无法在本仓库内固定，因此本仓库的可复现承诺只有两条：**同一 digest = 同一份产物**（按 `@sha256:...` 拉取），以及**每次构建都能回查出基座版本与 digest**（`alpine_version`、`base_digest`）。标签会随重建前移，不能作为固定点；它也不承诺「同样的命令每次都产出相同的字节」。发现插件行为变化时先看流水线日志，再决定是否调整脚本。

## 响应预期

本仓库由维护者利用业余时间维护，不承诺 SLA。安全相关 issue 会优先于功能改动处理，但请预留若干天。
