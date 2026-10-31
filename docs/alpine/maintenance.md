# 维护手册

> 补丁节奏等于上游 Alpine 的节奏：定时构建每天跟着 `alpine:latest` 走，包级补丁与新小版本自动进来；需要人判断的只有「上游跃迁后要不要跟着改」、同步文档，以及给需要固定的下游留 digest。

## 谁在什么时候动这个镜像

| 触发方式                            | 频率                          | `version` 取值                                                      | 产物                                                                  |
|-------------------------------------|-------------------------------|---------------------------------------------------------------------|-----------------------------------------------------------------------|
| 定时构建 `crontab: 5 0 * * *`       | 每天 `00:05`（Asia/Shanghai） | 不传，走 `Dockerfile` 默认的 `latest`（跟随上游最新稳定版）         | 推送解析出的版本标签（如 `3.25.1`），再提升 `3.25` 与 `latest`        |
| 手动按钮 `web_trigger_build_alpine` | 按需                          | 留空 / `latest`（跟随）、`3.25`、`3.25.1`、`3.25.1@sha256:<digest>` | 同上；标签里的版本号取解析值，即使用入参 `latest` 也不会出现 `latest` |

定时任务刻意不传 `version`：脚本把空值解释为「用 `Dockerfile` 里的 `ARG ALPINE_VERSION`」，而它是 `latest`，于是每天重建就自动吃到上游当天的稳定版。具体版本不写死在代码里，而是构建时解析出来（`3.25.1`）并写进标签与 OCI label——**跟随最新**与**知道自己在用什么**因此可以同时成立。

## 日常补丁节奏

`Dockerfile` 不锁包版本，`apk add` 每次执行都会重新拉 `vX.Y` 仓库的索引、装当时最新的包版本。脚本刻意不启用 registry 缓存，所以这条真的成立：同样的 Dockerfile 第二天重建，装到的就是第二天仓库里的包，`apk add` 不会因为命中缓存而被跳过。节奏因此分两种，两种都不需要人工介入：

- **包级安全更新**：次日 00:05 的定时构建重新解析索引，自动装到更新后的包，`latest` 与 `<minor>` 在冒烟通过后跟着前移。
- **新的 point release（如 `3.25.1` → `3.25.2`）**：`FROM alpine:latest` 本身就指向新的稳定版，次日重建直接把 rootfs 换过去，标签也随之变成 `3.25.2`。

```bash
IMAGE=docker.cnb.cool/dtapp/alpine

# latest 当前的 digest
docker buildx imagetools inspect "${IMAGE}:latest" --format '{{.Manifest.Digest}}'
# 版本标签当前的 digest：与上面相等，说明 latest 就是这份产物
docker buildx imagetools inspect "${IMAGE}:3.25.1" --format '{{.Manifest.Digest}}'
```

判断「今天这次构建有没有产出新镜像」看 commit 元数据：`built_at` 是本次的实际运行时刻（UTC），每次成功构建都会更新——标签不带日期之后，它是唯一能回答「这份产物是什么时候构建的」的记录；`image_version` 与 `alpine_version` 则告诉你「这次解析到的是哪个版本」。

## 手动重建与回滚

手动触发时 `version` 决定基座引用。留空或填 `latest` 与定时任务等价；填 `3.25` 跟随 minor 最新补丁；填 `3.25.1` 钉住 patch；填 `3.25.1@sha256:<digest>` 是位级复现（审计、事故复盘时用）。无论填哪一种，标签名里的版本号都是**解析出来的实际版本**，不会出现 `latest`。

**回滚的落点是 digest，不是标签。** 标签每天被同名覆盖、`latest`/`<minor>` 又被下一次构建前移，所以它们都不能当固定点。真正可用的做法：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine
# 1. 从「上一份可用产物」那次构建的 commit 元数据里找到 image_digest（或从自己的归档里取）
DIGEST=sha256:<那次构建的 image_digest>

# 2. 下游临时锁定到这一份（不需要任何重建）
docker pull "${IMAGE}@${DIGEST}"
```

要「让某个标签指回旧产物」在现在这套方案里不成立：`imagetools create -t 3.25 …` 只能指向制品库里仍存在的 digest，而下一次构建又会把它覆盖。所以正确的期望是：**标签永远代表最新，历史只能靠 digest 保存**。真要长期留档，就在流水线之外把 `image_digest` 记进变更单、发布记录或自己的清单里——元数据本身也只保留最近一次。

## 上游跃迁（3.25 → 3.26）怎么处理

`latest` 跟的是上游 latest-stable，所以小版本跃迁**不需要改任何文件**：某天 00:05 的构建会自动变成基于 `3.26.0` 的产物，标签也变成 `3.26.0`。但跃迁后的第一次构建值得按下面清单核一遍，任何一项不对就先用 digest 把下游锁回上一份可用产物，再修。

**第一步：确认新版本在 Docker Hub 上真的可拉。** `latest` 自己就会暴露问题：拉不到时构建在 `FROM` 阶段失败。

```bash
docker buildx imagetools inspect alpine:latest
```

**第二步：确认新版本的源路径可用。** CNB 侧 Dockerfile 只把基座源的主机名替换为腾讯云，`vX.Y` 路径由上游镜像自带，腾讯云同步滞后时 `apk add` 会 404 或超时；GitHub 侧不换源，路径由官方镜像自带。

**第三步：确认六个包在新版本仓库里仍然可用。** `netcat-openbsd`、`drill`、`git` 在大版本间移动过仓库的情况要先排除：

```bash
docker run --rm alpine:latest sh -c \
  'apk add --no-cache ca-certificates curl drill git netcat-openbsd tzdata'
```

**第四步：本地构建并跑容器自检。**

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .
docker run --rm alpine:local sh -c \
  'cat /etc/alpine-release; date; cat /etc/timezone; cat /etc/apk/repositories; command -v curl drill git nc nslookup'
```

**第五步：逐项核对验证清单。** 这份清单与流水线里的冒烟断言一一对应，本地通过就等于冒烟会通过。

| 检查项   | 命令                                                                   | 期望                                                     |
|----------|------------------------------------------------------------------------|----------------------------------------------------------|
| 基座版本 | `cat /etc/alpine-release`                                              | 新版本号，与元数据里的 `alpine_version` 一致             |
| 时区     | `date +%z`、`cat /etc/timezone`                                        | `+0800`，时区文件为 `Asia/Shanghai`                      |
| 源路径   | `cat /etc/apk/repositories`                                            | `main` + `community` 两行：CNB 主机腾讯云，GitHub 官方源 |
| 包策略   | `apk policy ca-certificates curl drill git netcat-openbsd tzdata`      | 每个包都有版本与来源仓库，无 `unavailable`               |
| 工具自检 | `command -v curl drill git nc nslookup`                                | 五个路径都有输出（`dig` 已由 `drill` 取代）              |
| 时区链接 | `ls -l /etc/localtime`                                                 | 指向 `/usr/share/zoneinfo/Asia/Shanghai`                 |
| OCI 标签 | `docker image inspect --format '{{json .Config.Labels}}' alpine:local` | 九个标签齐全，`base.name`/`base.digest` 有值             |

**第六步：同步文档。** `README.md`、`SECURITY.md`、`docs/` 里以 `3.25.x` 为例的版本号可以保留（它们只是示例），但如果写了「当前基座是 3.25」这类断言就要跟着改。文档落后于镜像比没有文档更容易误导。

**第七步：确认移动标签的落点。** 跃迁后旧的 `<minor>`（如 `3.25`）不再被提升，会停在最后一次成功的那份产物上。它已经不再是「能取到新补丁」的名字，但仍可作为「3.25 系列最后一份」的快速引用；要精确固定，还是用那次构建的 digest。

## 何时必须重建

| 场景                                           | 是否重建   | 说明                                                          |
|------------------------------------------------|------------|---------------------------------------------------------------|
| Alpine 发布新 point release 或新 minor         | 否（自动） | `FROM alpine:latest` 次日重建时自动跟过去，标签按解析版本命名 |
| 上游仓库里的包发布安全更新                     | 否（自动） | 不缓存装包层，次日重建重新解析索引即带上                      |
| SCA 报出 high / critical 且上游已修复          | 是         | 重建后 `image_digest` 变化即代表修复进入镜像                  |
| 改了 `Dockerfile`、`build-alpine.sh`、workflow | 是         | 构建内容或构建逻辑变了，产物必须重出                          |
| 手头只有 digest、想重新拉回那一份              | 否         | `docker pull <镜像>@sha256:<digest>`，不需要重建              |
| 只改文档、只改 `.scanignore`                   | 否         | 不影响镜像内容，扫描与知识库各自会重跑                        |

## 历史镜像不回溯

旧 digest 不会被补丁：上游修了也只作用于之后的新构建。因此下游不要把 digest 当「长期通行证」，而是把它当「我知道自己当时用的是哪一份」的凭据。

不回溯的理由很实际：回溯要给历史 commit 逐个重跑构建并重新推同名 tag，等于把已经前移的 `latest` 语义再改一次，而遗留的旧产物又没有人拉。收益与成本不成比例，所以明确写成「用完即弃」。

## 周期性检查清单

| 频率 | 检查什么                                                         | 位置 / 命令                          |
|------|------------------------------------------------------------------|--------------------------------------|
| 每周 | 定时构建是否连续成功，`built_at` 是否每天推进                    | 流水线记录、`built_at` 徽章          |
| 每周 | `alpine_version` 是否跟上了上游（Docker Hub 的 `alpine:latest`） | `alpine_version` 徽章、Docker Hub    |
| 每周 | SCA 报告里 high / critical 是否指向上游已修的包                  | 安全页的漏洞扫描报告                 |
| 每月 | 需要长期固定的下游是否都记录了 `image_digest`                    | 各下游的发布记录 / 变更单            |
| 每月 | `.scanignore` 两条排除是否仍然必要                               | 扫描结果对两张图片无报错即可考虑删除 |

## 标签与留档的关系

四个标签位，没有一个是留档用的：

| 标签                    | 语义                    | 是否覆盖         |
|-------------------------|-------------------------|------------------|
| `<版本>`（如 `3.25.1`） | 当前同版本产物          | 每次构建覆盖     |
| `<版本>-linux-amd64`    | 同上，单平台            | 每次构建覆盖     |
| `<版本>-linux-arm64`    | 同上，单平台            | 每次构建覆盖     |
| `<MINOR>`（如 `3.25`）  | 最近一次成功的 `3.25.x` | 每次成功构建前移 |
| `latest`                | 最近一次成功的构建      | 每次成功构建前移 |

所以没有「保留窗口」「删旧标签释放空间」这些事要做：同名标签本就被覆盖，`3.26` 上线后 `3.25.x` 自然不再更新，留着一个旧名字不会额外占位。真正会一直增长的是制品库里的 blob（每次构建都是新 digest），那由制品库自己按策略回收，与本仓库无关。

需要留档时，动作在文档与流程里：把 `image_digest` 抄进发布记录。这才是「某天的那一份」唯一的锚点。

## 已知待办

| 待办                   | 现状                                 | 影响                                                |
|------------------------|--------------------------------------|-----------------------------------------------------|
| 未接入镜像层扫描       | 只有 SCA 扫 `Dockerfile` 的依赖声明  | 层内二进制的 CVE 不会被发现，需要下游自己加扫描     |
| 镜像未签名             | 制品库不校验来源真实性               | 强校验只能按 digest 固定拉取                        |
| 标签不承担历史         | 同名标签每天覆盖，元数据只留最近一次 | 需要留档的下游必须自己记录 `image_digest`           |
| 基座浮动无法逐字节复现 | 同一份源码不同天构建的产物不同       | 复现要按 `image_digest` + `base_digest`，不能靠重跑 |

## 相关文档

- [镜像与标签](images-and-tags.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [SECURITY](../../SECURITY.md)
