# 镜像地址与标签

> 镜像地址 `docker.cnb.cool/dtapp/alpine`，标签是一份对外契约：一次构建产出哪些名字、每个名字什么时候出现、下游该固定到标签还是 digest，都在这里。

## 标签表

| 标签                    | 何时产生                                   | 内容                                       |
|-------------------------|--------------------------------------------|--------------------------------------------|
| `latest`                | 每次都推，无例外                           | amd64 + arm64 的 manifest list             |
| `<version>`             | 手动触发且 `version` 清洗后不等于 `latest` | 与同次 `latest` 一致的多架构 manifest list |
| `latest-linux-amd64`    | 每次都推                                   | amd64 单平台镜像                           |
| `latest-linux-arm64`    | 每次都推                                   | arm64 单平台镜像                           |
| `<version>-linux-amd64` | 手动触发且版本非 `latest`                  | 同次构建的 amd64 单平台镜像                |
| `<version>-linux-arm64` | 手动触发且版本非 `latest`                  | 同次构建的 arm64 单平台镜像                |

两个决定性细节：

- `latest` 恒定推送。填了版本号是「额外再加一个版本标签」，不是「替换 latest」。
- 定时任务固定 `version=latest`，所以每天 00:05 的那次构建只刷新 `latest` 与两个 `latest-linux-*`，永远不会产生版本标签。版本标签只能由人点按钮决定。

## 为什么同时有 manifest list 和单平台标签

manifest list 是给认识多架构的客户端用的：`docker pull` 自动按宿主机架构挑条目，一条 `FROM docker.cnb.cool/dtapp/alpine:latest` 就能在 amd64 与 arm64 机器上都跑通。但有些工具链、脚本或下游配置只想拿到「一个标签对应一个平台」，不愿自己处理多平台条目，单平台标签就是给这类场景的退路：标签本身把平台固定下来，内容与同次构建的多架构条目一致，只是暴露粒度不同。

## manifest list 与单平台标签的区别

```bash
# 多架构标签：能看到 linux/amd64 与 linux/arm64 两个条目
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest

# 单平台标签：只承诺该架构
docker manifest inspect docker.cnb.cool/dtapp/alpine:latest-linux-amd64
```

`latest-linux-amd64` 的语义是「不用挑，这个标签就是 amd64」。但它在制品库里的对象形态与多架构标签并不对称：buildx 默认附带 attestation，单平台推送出来的同样是一个 index，只是其中只有一个平台的镜像清单（外加 attestation 条目）。因此 `docker manifest inspect` 看到索引而不是单份清单，属于预期行为，不代表标签打错了。

这一点在统计体积时最容易踩坑：不能对该 index 的条目直接求和，必须先取出对应平台镜像清单的 digest，再对 `layers` 求和，细节见[构建元数据与徽章](metadata-and-badges.md)。

## version 输入的清洗规则

脚本开头三步处理（`.cnb/scripts/build-image.sh`）：

```bash
version=$(echo "$version" | tr -d '[:space:]' | tr -d '\n\r')   # 去空白与换行
version=$(echo "$version" | sed 's/[^[:print:]]//g')            # 去不可打印字符
[ -z "$version" ] && version="latest"                           # 空值回落
```

由此得到的实际行为：

| 输入                | 实际使用                      |
|---------------------|-------------------------------|
| 留空                | `latest`                      |
| 前后带空格的 `3.20` | `3.20`                        |
| 末尾带换行的 `3.20` | `3.20`                        |
| `v3.20`             | `v3.20`，会在 `FROM` 阶段失败 |

最后一行要单独记住：清洗只去空白与不可打印字符，不做任何规范化。`version` 会原样作为 `--build-arg ALPINE_VERSION` 传给 `FROM alpine:${ALPINE_VERSION}`，所以它必须是 Docker Hub 上真实存在的 alpine tag，写 `3.20` 而不是 `v3.20`。写错不会在流水线配置阶段被拦下，而是在拉基础镜像时直接失败。

清洗后的值通过 `##[set-output interior_version=...]` 输出并 `export INTERIOR_VERSION` 给后续命令，转换后的名字不再包含输入里的空格。

## 按 digest 固定拉取

标签会移动，digest 不会。生产环境需要可复现时按 digest 拉取：

```bash
# 取当前 latest（多架构 index）的 digest
DIGEST=$(docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}')

# 固定拉取
docker pull "docker.cnb.cool/dtapp/alpine@${DIGEST}"
```

digest 的三个来源，按可靠性排序：

| 来源                                                      | 说明                                              |
|-----------------------------------------------------------|---------------------------------------------------|
| Commit 元数据 `image_digest`                              | 该次构建产出的完整 `sha256:...`，构建脚本直接写入 |
| `docker buildx imagetools inspect` 的 `Digest:` 行        | 现场查询，任何时刻都能取到当前值                  |
| 徽章 `/badge/annotation/commit/latest/image_digest_short` | 只有前 12 位，用于人工核对，不足以拉取            |

`image_digest` 记录的是 `latest` 这个多架构 index 的 digest。按它拉取，宿主机仍会自动选平台，可复现性与多架构便利性同时保留。

## 下游怎么选

| 场景                       | 选择                                   | 理由                                                  |
|----------------------------|----------------------------------------|-------------------------------------------------------|
| 生产、需要可复现、需要审计 | `@sha256:...`                          | 唯一不可变的引用；镜像未签名，digest 是唯一强校验手段 |
| 跟随上游安全补丁           | `latest`                               | 每天 00:05 随上游 Alpine 重建，自动带上补丁           |
| 需要特定 Alpine 版本       | `<version>` / `<version>-linux-<arch>` | 版本标签不会自动跟随补丁，需要重新手动触发            |

版本标签本身也是可变的：同一个 `3.20` 每次手动构建都会被覆盖。要锁死某个产物，只能记下当时的 digest。

## 改名与删除标签的兼容流程

标签命名是对外契约（见 [CONTRIBUTING](../CONTRIBUTING.md) 硬性规则），`latest`、`<version>`、`latest-linux-{arch}` 已有下游在用，改名前先在 issue 里讨论。落地顺序：

1. 脚本里给新名字和旧名字同时打标签，一次构建双写；
2. 通知下游切换到新名字，留出迁移窗口；
3. 确认无人引用后再从脚本里删掉旧名字。

不要单独删除 `latest` 或 `latest-linux-*`：定时任务每天都会重推，删除既会与下一次构建冲突，也会让删除窗口内拉取的下游直接失败。确实要下线某个版本标签，也得先确认没有下游按该名字固定，并把对应的 digest 保留下来。

## 历史镜像

- 历史镜像（旧 digest）不回溯修复，用完即弃：补丁节奏等于上游 Alpine 的补丁节奏，需要新补丁就重新触发构建。
- `*-linux-amd64` / `*-linux-arm64` 与同次构建的多架构标签内容一致，不做单独维护。
- 制品库只负责存储与分发，不校验来源真实性（镜像未签名），强校验只能靠 digest。

以上取舍的完整表述见 [SECURITY](../SECURITY.md)。

## 相关文档

- [开始使用](getting-started.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全策略](../SECURITY.md)
