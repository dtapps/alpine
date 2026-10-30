# 镜像地址与标签

> 镜像地址 `docker.cnb.cool/dtapp/alpine`，标签是一份对外契约：一次构建产出哪些名字、每个名字什么时候出现、下游该固定到标签还是 digest，都在这里。

## 标签表

**标签就是 alpine 的版本号，不带日期。** 一次构建产出一个可推的标签，其余名字都是对它的引用改写：

| 标签                 | 何时产生                              | 内容                                               |
|----------------------|---------------------------------------|----------------------------------------------------|
| `3.25.1`             | 每次构建，构建阶段唯一的 `-t`         | amd64 + arm64 的 manifest list，同名标签每天被覆盖 |
| `3.25.1-linux-amd64` | 构建成功后由 `imagetools create` 派生 | amd64 单平台内容，digest 与 index 中条目相同       |
| `3.25.1-linux-arm64` | 同上                                  | arm64 单平台内容，digest 与 index 中条目相同       |
| `3.25`               | 冒烟测试通过后，按 digest 提升        | 滚动 minor，指向最近一次成功的 `3.25.x` 构建       |
| `latest`             | 冒烟测试通过后最后提升                | 指向最近一次成功的构建                             |

几个决定性细节：

- 标签里的版本号不是手写的，也不是 `latest`：脚本先起一个一次性容器读 `/etc/alpine-release`，把 `alpine:latest` 解析成 `3.25.1` 这种确定值。所以 `latest` 天天动，而 `3.25.1` 这个标签反映的是「当前同版本产物」，重建会被覆盖。
- **同名标签每天被覆盖是刻意的**：alpine 的版本号就是产品的版本号，再叠一层日期只会让下游不知道该固定哪一个。代价是「昨天那份」没有标签可指——要固定某一次构建，只能按 digest 拉取，见下文「按 digest 固定拉取」。
- `3.25.1-linux-*` 同样每天被覆盖，它只解决「只认单平台标签的工具」，不承担留档职责。
- `3.25` 与 `latest` 是提升出来的，且必须等冒烟测试通过：测试项是容器内 `/etc/alpine-release` 前缀等于解析出的版本、`/etc/timezone` 为 `Asia/Shanghai`、`date +%z` 为 `+0800`、`/etc/apk/repositories` 恰好 4 行、`curl`/`drill`/`nc`/`nslookup` 四个命令可执行、OCI 标签 `version` 等于本次版本标签名。任一项失败脚本 `exit 1`，`3.25` 与 `latest` 停在原地。
- 冒烟失败时 `3.25.1` 这个标签已经指向那份坏产物了（构建阶段就推了），但它不是给下游消费的名字：按 `3.25` 或 `latest` 拉取的人不受影响，下一次成功构建会把 `3.25.1` 覆盖回来。
- 定时任务不传 `version`，于是走 `Dockerfile` 里的 `ARG ALPINE_VERSION=latest`：每天 00:05 那次构建跟随上游最新稳定版，包级补丁与新小版本都自动带上。

## 为什么同时有 manifest list 和单平台标签

manifest list 是给认识多架构的客户端用的：`docker pull` 自动按宿主机架构挑条目，一条 `FROM docker.cnb.cool/dtapp/alpine:latest` 就能在 amd64 与 arm64 机器上都跑通。但有些工具链、脚本或下游配置只想拿到「一个标签对应一个平台」，不愿自己处理多平台条目，单平台标签就是给这类场景的退路。

关键区别在成本：单平台标签**不是重新构建**出来的。脚本先用 `docker buildx imagetools create` 把多架构 index 里该平台条目的 digest 挂到 `3.25.1-linux-amd64` 这个新名字上，再去提升 `latest`。整个流程只执行一次 `buildx build`，派生与提升都只是「给已有 digest 增加一个名字」，所以：

- 同名标签之间不可能出现「内容差一点」的两份镜像：它们指向的就是同一份清单 digest；
- 不需要为 arm64 再买一台 Runner，也不需要第三条「合并清单」流水线；
- 派生步骤几乎不耗时间，省下的是两次完整的构建（含两次 `apk add`）。

## manifest list 与单平台标签的区别

```bash
# 多架构标签：能看到 linux/amd64 与 linux/arm64 两个条目
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest

# 单平台标签：只承诺 amd64
docker manifest inspect docker.cnb.cool/dtapp/alpine:3.25.1-linux-amd64
```

`3.25.1-linux-amd64` 的语义是「不用挑，这个标签就是 amd64」，它由 `docker buildx imagetools create -t <镜像>:3.25.1-linux-amd64 <镜像>@sha256:<平台清单 digest>` 派生，所以它背后的 digest 与 index 里 amd64 条目完全一致。核对方式就是比较两处输出的 digest；不一致说明派生步骤没有走 `imagetools create`，而是又构建了一次。

对象形态（这个标签在制品库里到底是一份清单还是一个只含单平台条目的 index）由 buildx 决定，不同版本可能不同，因此不要依赖它：要判断「是不是同一份内容」只认 digest，要统计体积只走「index → 平台清单 digest → `--raw`」，细节见[构建元数据与徽章](metadata-and-badges.md)。

## version 输入的校验规则

脚本对 `version` 的处理是白名单，只接受这几种形态（`.cnb/scripts/build-alpine.sh`）：

| 输入                        | 含义                                                     |
|-----------------------------|----------------------------------------------------------|
| 留空                        | 用 `Dockerfile` 的 `ARG ALPINE_VERSION`（当前 `latest`） |
| `latest`                    | 显式跟随上游最新稳定版，与留空等价                       |
| `3.25`                      | 跟随 3.25 分支的最新补丁（标签就是解析出的 3.25.x）      |
| `3.25.1`                    | 钉住某个 patch 作为基座（标签仍是解析出的实际版本）      |
| `3.25.1@sha256:<64 位 hex>` | 位级复现（审计、事故复盘）                               |
| 其它（`v3.25`、`3.25/` 等） | 拒绝，`exit 1`                                           |

```bash
case "${version}" in
  '' | latest) : ;;                       # 跟随上游：cron 与默认按钮的用法
  *)
    printf '%s' "${version}" \
      | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?(@sha256:[0-9a-f]{64})?$' \
      || die "version 只接受 latest / 3.25 / 3.25.1 / 3.25.1@sha256:<digest>，收到：${version}"
    ;;
esac
```

白名单比「把危险字符删掉」可靠：`version` 会原样进入 `FROM alpine:${ALPINE_VERSION}` 与 `--build-arg`，一旦允许 `/`、`:`（除 digest 那处固定格式）或大小写混写，构建命令的语义就由输入决定。校验发生在拉基础镜像之前，所以写错时看到的是校验报错，而不是跑到一半的拉取失败。

传 `latest` 也不会让标签里出现 `latest`：`ALPINE_REF=latest` 只用于 `FROM`，标签与元数据里用的是解析出来的实际版本（如 `3.25.1`）。也就是说「基座是 latest」只体现在构建时刻，产物本身始终有确定版本号。

一个容易被当成 bug 的细节：如果 `version` 本身就带 digest（`3.25.1@sha256:<64hex>`），脚本算出的 `BASE_DIGEST` 会与它**完全相同**。这是预期——`docker run alpine:3.25.1@sha256:…` 与 `FROM` 拉的是同一份 digest，所以「基座 digest = 你给的那个 digest」才对；白名单会先挡掉位数不对的 hex，不会让半截 digest 混进 `FROM`。

## 按 digest 固定拉取

**标签会随重建前移，digest 才是固定点。** 需要可复现时按 digest 拉取：

```bash
# 取当前 latest（多架构 index）的 digest
DIGEST=$(docker buildx imagetools inspect \
  docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}')

# 固定拉取
docker pull "docker.cnb.cool/dtapp/alpine@${DIGEST}"
```

digest 与基座信息的来源：

| 来源                                                      | 说明                                                       |
|-----------------------------------------------------------|------------------------------------------------------------|
| Commit 元数据 `image_digest`                              | 该次构建产出的完整 `sha256:...`，构建脚本直接写入          |
| Commit 元数据 `base_digest`                               | 当次 `alpine:latest` 的 index digest，回查基座到底是哪一份 |
| `docker buildx imagetools inspect` 的 `Digest:` 行        | 现场查询，任何时刻都能取到当前值                           |
| 徽章 `/badge/annotation/commit/latest/image_digest_short` | 只有前 12 位，用于人工核对，不足以拉取                     |

`image_digest` 记录的是这次构建的 index digest，元数据里同一批的 `image_version` 说明它是哪个版本、`built_at` 说明什么时候构建、`alpine_version` 与 `base_digest` 说明当时吃的是哪个基座。四个值合起来才够复现，缺一个都会在几个月后变成猜谜。

注意元数据只保留「当前 commit 最近一次构建」的结果：想长期留住某次产物，必须把 `image_digest` 自己抄走或归档，制品库里的标签不会帮你保存历史。

## 下游怎么选

| 场景                       | 选择                 | 理由                                                     |
|----------------------------|----------------------|----------------------------------------------------------|
| 生产、需要可复现、需要审计 | `@sha256:...`        | 唯一不会变的引用；镜像未签名，digest 是唯一强校验手段    |
| 跟随上游安全补丁           | `latest` / `3.25`    | 每天 00:05 重建，包级补丁与新 patch 最迟次日自动带上     |
| 需要某个确定版本号         | `3.25.1`             | 映射到 alpine 的版本号，好读；但它随重建前移，不是固定点 |
| 只认单平台标签的工具       | `3.25.1-linux-amd64` | 标签把平台固定下来，内容与同次构建的多架构条目一致       |

## 改名与删除标签的兼容流程

标签命名是对外契约（见 [CONTRIBUTING](../../CONTRIBUTING.md) 硬性规则），`latest`、`3.25`、`<版本>` 及其 `-linux-{arch}` 变体已有下游在用，改名前先在 issue 里讨论。落地顺序：

1. 脚本里给新名字和旧名字同时打标签，一次构建双写；
2. 通知下游切换到新名字，留出迁移窗口；
3. 确认无人引用后再从脚本里删掉旧名字。

不要单独删除 `latest` 或 `3.25`：定时任务每天都会重新提升，删除既会与下一次构建冲突，也会让删除窗口内拉取的下游直接失败。带版本号的标签（如 `3.25.1`）也不用删：它每天被覆盖，上游换版本后自然不再更新，留着不会额外占位。

## 历史镜像

- 历史镜像（旧 digest）不回溯修复，用完即弃：上游发新补丁后重建一次即可。
- 标签不承担历史职责：同名标签被覆盖后，昨天的产物只能靠当时记下的 `image_digest` 找回。
- `-linux-amd64` / `-linux-arm64` 与同一版本标签里对应平台的条目是同一个 digest，不做单独维护。
- 制品库只负责存储与分发，不校验来源真实性（镜像未签名），强校验只能靠 digest。

以上取舍的完整表述见 [SECURITY](../../SECURITY.md)。

## 相关文档

- [开始使用](getting-started.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全策略](../../SECURITY.md)
