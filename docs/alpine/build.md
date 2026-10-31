# 构建

> 本地一次 `docker build` 验内容，CI 一次 `buildx build` 出多架构——同一份 Dockerfile、同一个 `ALPINE_VERSION` 参数，差别只在产物怎么落地。

## 本地单架构

```bash
docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .   # 默认 ALPINE_VERSION=latest
docker run --rm alpine:local sh -c 'cat /etc/alpine-release; date; command -v curl drill git nc nslookup'
```

- 构建上下文是仓库根目录（命令最后的 `.`），Dockerfile 在 `.cnb/docker/`，所以必须 `-f` 指定；`COPY` 之类的相对路径仍以根目录为基准。
- 不传 `--build-arg` 时用的是 `ARG ALPINE_VERSION=latest` 的默认值，与 CI 定时任务完全一致：本地这一跑就等于「今天上游最新的 alpine + 六个包」，和 cron 当天的产物同源同内容。
- 想复现某次具体产物，别改文件，传参即可：`--build-arg ALPINE_VERSION=3.25.1`（要位级一致就带 `@sha256:...`）。钉住之后 `FROM` 拉到的就是那一份，与上游当天发没发新补丁无关。
- 这是最快的验证路径：宿主架构即产物架构，产物直接进本地 image store，可以立刻 `docker run`。

不管本地还是 CI，一条 `docker build` 得到的都是**单层**镜像（官方 alpine 的层 + 一个 `RUN` 层），层结构见 [Dockerfile 解析](dockerfile.md)。

## 构建上下文与 .dockerignore

构建上下文是仓库根目录，而 Dockerfile 一个文件都不 `COPY`——它只跑 `apk add`。所以除了 Dockerfile 之外的所有文件都是纯粹的传输噪声，`.dockerignore` 把它们挡在外面：

```text
.git                  仓库历史，约 1.8 MB
*.md / docs           文档，与镜像内容无关
LICENSE / Makefile / .yamlfmt / .scanignore
.cnb/annotation.json  CI 生成的元数据文件
```

效果是从约 3.0 MB 降到约 0.1 MB。上下文小有两个直接好处：构建开始时上传上下文的时间几乎归零；BuildKit 计算上下文摘要更快，缓存命中判断也不会因为无关文件改动而抖动。改 `.dockerignore` 时注意别把 `.cnb/docker/Dockerfile.alpine` 排除掉——它是唯一需要进上下文的文件。

## 多架构的三种落地方式

| 方式     | 关键参数                                    | 产物             | 限制               |
|----------|---------------------------------------------|------------------|--------------------|
| `--load` | `--platform linux/amd64 --load`             | 本地 image store | 只能单平台         |
| `--push` | `--platform linux/amd64,linux/arm64 --push` | 多架构 index     | 需先 docker login  |
| OCI tar  | `--output type=oci,dest=out.tar`            | 本地 tar 文件    | 不能 `docker load` |

- `--load` 的限制来自本地 image store 不支持 manifest list：多平台 + `--load` 会直接报 `docker exporter does not currently support exporting manifest lists`。要在本地同时拿到两个架构，只能分两次单平台 `--load`，而两次会争抢同一个标签名，所以本地多平台验证通常改用 OCI tar。
- `--push` 是 CI 唯一使用的模式：产物必须进制品库，标签才有意义。本地不要随手 `--push` 到 `docker.cnb.cool/dtapp/alpine`，会覆盖对外标签。
- `--output type=oci,dest=out.tar` 把多平台产物落成一个 OCI layout 的 tar，适合留档或转交给别的机器。`docker load` 不认 OCI layout，认的是 `type=docker,dest=out.tar`，后者同样只支持单平台。

本地多架构示例：

```bash
docker buildx create --name alpine-multi --driver docker-container --bootstrap --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile.alpine \
  -t alpine:local --output type=oci,dest=out.tar .
```

第一行的自建 builder 只需要执行一次：默认的 `docker` driver 不支持多平台，容器驱动的 builder 才支持。**但这只适用于本地**——CNB 的 `services: docker` 已经内置可做多架构的 builder，流水线里不要再 `docker buildx create --driver docker-container`，受限容器里拉不起嵌套 buildkitd，会以 bootstrap 失败告终（脚本注释里写明了这条）。

## buildx 常用参数与缓存取舍

| 参数           | 作用            | 本仓库用法                              |
|----------------|-----------------|-----------------------------------------|
| `-f`           | 指定 Dockerfile | `.cnb/docker/Dockerfile.alpine`         |
| `--platform`   | 目标平台        | 一次构建两个平台                        |
| `--build-arg`  | 传构建参数      | `ALPINE_VERSION` + 四个元数据参数       |
| `--push`       | 构建完直接推送  | CI 唯一的落地方式                       |
| `--provenance` | 附加证明清单    | `mode=min`，压掉多余的 attestation 条目 |
| `--sbom`       | 附加 SBOM 清单  | `false`，同上                           |

缓存与「刻意不缓存」：

- 同一个 builder 内的 BuildKit 层缓存自动复用，这是本地反复构建同一条命令很快的原因。CI 每次都是新 runner，这层缓存基本用不上。
- 缓存键由「本层指令 + 上层内容」算出，所以 Dockerfile 的段落顺序直接决定复用率：换源、装包、写时区、清理压在同一层里，改包列表必然重建这一整层——这是有意的取舍，理由见 [Dockerfile 解析](dockerfile.md#为什么只有一个-run)。
- **CI 刻意不启用 registry 缓存**（没有 `--cache-from` / `--cache-to`，也不会产生 `:buildcache` 这样的标签）。理由不是「忘了配」，而是这套缓存对本镜像有害：镜像只有一个 `RUN`，registry 缓存能复用的就是这一层，一旦命中，`apk add` 根本不会执行——每日 cron 会永远装到同一批包，上游在分支里发布的包级安全补丁永远进不来，「构建成功」会变成「构建没做事」。基座跟随 `latest` 之后这一点更要紧：`FROM` 已经换了新 digest，那一层要是命中旧缓存，镜像内容会和标签上的版本号对不上。
- 不启用缓存的代价很小：每次多跑一遍「2 个索引 + 6 个包」，实测是秒级；而镜像本来就只有一个层、一次构建，没有「多层重复编译」那种值得优化的东西。换来的是**「每天重建 = 真的刷新依赖」**这个语义，对基础镜像来说这笔交换明显划算。
- 需要快的时候，能指望的只有本地 BuildKit 层缓存与单层结构本身：本地反复构建时同一条命令会命中缓存，改 Dockerfile 才会真正重跑那一层。
- `--provenance` 与 `--sbom` 默认都开，会产生额外的 attestation 清单，这些清单不占层体积，但会混进 `imagetools inspect` 的输出。所以体积统计必须先定位到平台镜像清单再对 `layers` 求和，不能对 index 的各个条目直接相加——拿到手的会是「清单 JSON 自身」的一两 KB。CI 里显式传 `--provenance=mode=min --sbom=false`，把这类噪声压到最小。

## CI 构建脚本逐段

`.cnb/scripts/build-alpine.sh` 被 `source` 执行而不是 `sh build-alpine.sh`，因为 `##[set-output]` 与 `export` 都要在当前 shell 里生效。脚本是 POSIX `sh`（`#!/bin/sh` + `set -eu`），不依赖 bash 扩展；`local`、`[[ ]]`、`${var,,}`、herestring 一概不用，函数体需要局部变量时用子 shell。

脚本头部的「设计约束」五条是整套流程的纲，后面每一段都在服务它们，改脚本前建议先读原文：

```text
1. 只构建一次多架构，单平台标签从同一份 manifest 派生 —— 不重建，
   所以三类标签的 digest 天然相同（旧实现三次构建，digest 各不相同）。
2. 基座跟随上游：Dockerfile 的 ARG ALPINE_VERSION 默认 latest，定时任务
   每天重建就能吃到新补丁甚至新小版本；具体版本由脚本解析成 3.25.1 这种
   确定值，写进标签与 OCI label。
3. 标签就是 alpine 版本号（不加日期）：先推 <版本>，冒烟通过后才提升 latest / minor。
   冒烟失败时 latest / minor 不动，对外契约不受影响。
4. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效，
   用 `sh build-alpine.sh` 跑会静默丢掉这两件事。
5. 不启用 registry cache：唯一那层 RUN 一旦命中缓存就不会再执行 apk add，
   每日 cron 会永远装到同一批包。宁可每次多跑几秒，也要让「重建=刷新依赖」。
```

1. **环境检查**：`CNB_DOCKER_REGISTRY`、`CNB_REPO_SLUG_LOWERCASE`、`CNB_TOKEN_USER_NAME`、`CNB_TOKEN` 缺一个就在开跑前停下（`: "${VAR:?}"`），而不是等 `docker login` 报一个含糊的 401。`trap cleanup EXIT` 负责在结束时删掉 `${HOME}/.docker/config.json`。

2. **version 校验**：入参只有五种合法形态，其余一律 `die`（写 stderr 并退出）。

| 入参                        | 行为                                                 |
|-----------------------------|------------------------------------------------------|
| 留空（定时任务、未填）      | 用 Dockerfile 里的 `ALPINE_VERSION`（默认 `latest`） |
| `latest`                    | 显式要求跟随上游最新稳定版                           |
| `3.25`                      | 跟随该分支的最新补丁，同 tag 产出会漂                |
| `3.25.1`                    | 钉住某个 patch                                       |
| `3.25.1@sha256:<64 位 hex>` | 位级复现，内容由 digest 决定                         |
| 其它（`3.25-rc1`、`v3.25`） | 报错退出，不构建                                     |

留空与 `latest` 等价，差别只在取值路径：留空是回落到 Dockerfile 的 `ARG`，`latest` 是直接把入参当引用。校验用白名单 `^[0-9]+\.[0-9]+(\.[0-9]+)?(@sha256:[0-9a-f]{64})?$`，比黑名单可靠——非法值既不会被拼进 `FROM`，也不会变成标签名，不会跑到一半才失败。注意 `@sha256:` 后面必须是完整的 64 位 hex，截短的 digest 同样被挡下。

2. **基座引用**：有 `version` 就用它，没有就 `sed -n 's/^ARG ALPINE_VERSION=//p'` 从 Dockerfile 读默认值，得到 `ALPINE_REF`。这一步只决定「用哪个引用去拉」，值里可能还带着 `latest` 或 digest 后缀，所以不能直接拿来做标签。

3. **解析基座的实际版本与 digest**：基座跟随 `latest` 之后新增、也最关键的一步。

```bash
ALPINE_REAL="$(docker run --rm --platform linux/amd64 "alpine:${ALPINE_REF}" \
  cat /etc/alpine-release | sed 's/-r[0-9]*$//' | tr -d '[:space:]')"
BASE_DIGEST="$(docker buildx imagetools inspect "alpine:${ALPINE_REF}" --format '{{.Manifest.Digest}}')"
```

- `ALPINE_REAL` 是「这次真正拉到的版本」，例如 `3.25.1`，它**直接就是最终的版本标签名**（`${IMAGE}:3.25.1`）。`latest` 是另一条独立的移动标签，绝不参与版本标签的命名——否则下游没法按版本拉取，也没法从标签上看出自己吃的是哪个 alpine。
- `BASE_DIGEST` 是基座 index 的 digest：写进 `annotation.json`，同时通过 `--build-arg` 变成镜像 label 里的 `org.opencontainers.image.base.digest`。`latest` 天天变，只有 digest 能事后精确指回「那天的最新是哪一份」。
- 解析失败（Docker 不可用、拉不到镜像）就直接退出：连基座是哪个版本都不知道，后面的构建没有意义。
- 滚动 minor 也在这里定：取 `ALPINE_REAL` 的前两段，`3.25.1` → `3.25`。

4. **标签与时间字段**：`STAMP="${ALPINE_REAL}"`，标签就是 `3.25.1`，**不带日期**。三个后果要记住：

   - **同名标签每天覆盖**。上游还是 `3.25.1` 时，今天的 cron 会把 `3.25.1` 重新指到今天的构建结果；上游走到 `3.25.2`，就换成新的 `3.25.2`，`3.25.1` 停在最后一次基于它的构建上。好处是标签极其好记、和 alpine 版本一一对应；代价是**标签不承诺内容不变**，也不存在「某天那一份」的标签。
   - **要指回「某一份」只能用 digest**。第 11 段把当次的 index digest 写进 `annotation.json` 的 `image_digest`，这是唯一的定位依据（下面「可追溯与可复现」一节展开）。
   - **`BUILD_DATE` 不是构建时间**。它取 `git log -1 --format=%cI`（最后一次提交时间，取不到回落 `1970-01-01T00:00:00Z`），进镜像 `LABEL` 的 `created`，为的是同一 commit 两次构建 config 一致。**真正记录「什么时候构建的」只有 `built_at`**（`date -u +%Y-%m-%dT%H:%M:%SZ`），它只写进 `annotation.json`、不进镜像。标签不再带日期之后，`built_at` 就是唯一的时间线索，每一次构建都必须写。

5. **登录**：用 `--password-stdin` 而不是 `-p`，凭证不出现在进程参数（`ps` 可见）与 CI 日志里：

```bash
printf '%s' "${CNB_TOKEN}" \
  | docker login -u "${CNB_TOKEN_USER_NAME}" --password-stdin "${CNB_DOCKER_REGISTRY}"
```

凭证来自 `imports` 引入的组织环境（`https://cnb.cool/dtapp/envs/-/blob/main/docker.yml`），仓库里不存在任何 token，见 [安全基线](security-baseline.md)。脚本用 `trap` 在结束时删掉 `${HOME}/.docker/config.json`，避免 runner 上残留一个带 token 的文件。

6. **buildx 自检**：`docker buildx version` 与 `docker buildx inspect` 各带失败即退出。builder 不可用时立刻停下，而不是等第一次 build 抛一个更长更难读的错误。注意这里**不做** `docker buildx create`：CNB 的 `services: docker` 自带可做多架构的 builder。

7. **一次多架构构建（唯一的构建）**：只推一个标签——`${IMAGE}:${STAMP}`，也就是 alpine 版本号 `3.25.1`。

```bash
docker buildx build -t "${IMAGE}:${STAMP}" --platform linux/amd64,linux/arm64 \
  --build-arg "ALPINE_VERSION=${ALPINE_REF}" --build-arg "IMAGE_VERSION=${STAMP}" \
  --build-arg "VCS_REF=${VCS_REF}" --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "BASE_DIGEST=${BASE_DIGEST}" \
  --provenance=mode=min --sbom=false -f "${DOCKERFILE}" --push .
```

一次构建两个平台，而不是「多架构 + 两次单平台」三次构建：arm64 那次在 amd64 runner 上要靠 QEMU 模拟重跑一遍 `apk add`，是三次构建里最贵的一次，而它产出的内容与多架构构建里的 arm64 条目本来就一样。命令里也没有 `--cache-from/--cache-to`，这是刻意的，理由见上一节。

注意 `ALPINE_VERSION` 传的是 `ALPINE_REF`（可能是 `latest`、`3.25`，也可能是 `3.25.1@sha256:...` 原样），不是解析后的 `ALPINE_REAL`：`FROM` 要的是「用户想用的那个引用」，位级复现靠的正是把带 digest 的引用原样传进去；解析出来的值只用于标签与 label。

8. **派生单平台标签**：对每个架构用 `docker buildx imagetools create -t "${IMAGE}:${STAMP}-linux-${arch}" "${IMAGE}@${digest}"` 从 index 里对应条目派生，不重新构建，所以 digest 与 STAMP 里的条目完全一致。

| 标签                   | 例子                 | 怎么来的                 | 覆盖语义             |
|------------------------|----------------------|--------------------------|----------------------|
| `${STAMP}`             | `3.25.1`             | 构建阶段直接 `--push`    | 每天重建覆盖同名标签 |
| `${STAMP}-linux-amd64` | `3.25.1-linux-amd64` | `imagetools create` 派生 | 同上                 |
| `${STAMP}-linux-arm64` | `3.25.1-linux-arm64` | 同上                     | 同上                 |
| `${MINOR}`             | `3.25`               | 冒烟通过后由 STAMP 提升  | 滚动，只前进不后退   |
| `latest`               | `latest`             | 同上，最后提升           | 滚动，只前进不后退   |

标签名不带日期，是刻意的简化：alpine 的版本号就是产品的版本号，`docker pull …:3.25.1` 一眼能读懂，不用记「哪天构建的」。代价是**所有标签都会动**——`3.25.1` 每天被重新指向当次构建，`3.25` 与 `latest` 在冒烟通过后被提升。因此标签只回答「这条线现在指向什么」，不回答「某个历史产物是什么」；后者只能靠 digest，见下一节。

`3.25` 与 `latest` 永远由 `imagetools create` 从版本标签**提升**，绝不自己重新构建——重建会得到新 digest，同一个版本号的几条标签立刻对不上。

9. **冒烟测试**：在提升 `3.25` / `latest` 之前，先验证 amd64 产物，六项断言：

| # | 断言                                                 | 在验什么                     |
|---|------------------------------------------------------|------------------------------|
| 1 | `cut -d- -f1 /etc/alpine-release` 等于 `ALPINE_REAL` | 镜像确实基于当次解析出的基座 |
| 2 | `/etc/timezone` 是 `Asia/Shanghai`                   | 时区文件写入                 |
| 3 | `date +%z` 是 `+0800`                                | 时区真的生效                 |
| 4 | `/etc/apk/repositories` 恰好两行                     | 源没被写坏                   |
| 5 | `curl`/`drill`/`git`/`nc`/`nslookup` 都可执行        | 预装工具齐全                 |
| 6 | label `org.opencontainers.image.version` 等于 STAMP  | 版本标签写对了               |

第 1 项是基座跟随 `latest` 之后新增的：既然基座每天都可能变，就必须确认「这次装的包确实来自我以为的那个 alpine 版本」，否则标签上的版本号就是假的。第 6 项在容器外单独用 `docker image inspect` 校验。

任一条不满足就打印失败项并 `exit 1`。这里要清楚失败时制品库处于什么状态：**版本标签在第 7 段就已经推上去了，冒烟失败时它指向的正是这份坏产物**（没有临时标签可以退回）；但 `3.25` 与 `latest` 不会被提升，仍然指向上一份通过验证的构建，所以按这两个标签拉取的下游不受影响。下次成功构建会用同名标签把版本标签覆盖回来。

脚本会**先 `docker pull --platform linux/amd64` 再 `docker run`**：`buildx --push` 只把镜像推进制品库，本地并没有那份镜像，让 `docker run` 隐式拉取会把 `Unable to find image ...` 与 `Pulling fs layer` 混进要断言的输出里。拉取拆成独立一步后，容器内只打印一个完成标记，判定用「标记是否出现」而不是「输出是否完全相等」——docker 的平台警告、镜像名提示都可能混进来。

10. **提升可变标签**：顺序固定 `MINOR` 在前、`latest` 最后，两者都用 `imagetools create` 从 STAMP 提升。先 minor 后 latest 是为了让失败面只落在「新 minor 已更新、latest 还没动」这种可接受状态，而不是反过来。

11. **元数据汇总**：用 `docker buildx imagetools inspect` 取 **STAMP** 的 index digest（不是 `latest`，避免读到别人刚提升的结果）；体积必须按平台算——对每个平台先定位到该平台的镜像清单，再对清单里 `layers` 之和加 `config.size` 求和，解析不出合理值时记 `-1`（最终显示 `unknown`，绝不输出假的小数字）。有 `jq` 时精确求和，没有则回落到 `grep` 扫全文档、靠 1 MiB 门闸兜底。

`##[set-output]` 也在这里输出：`interior_version=${ALPINE_REAL}`（解析出的具体版本，保留旧 key）、`image_version=${STAMP}`（本产物）。

结果写成 `.cnb/annotation.json`（`image_digest`、`image_digest_short`、`image_version`、`alpine_version`、`base_image`、`base_digest`、`image_size`、`image_size_arm64`、`built_at`、`source_date`），由流水线第二步的 `cnbcool/annotations` 插件（`type: ADD`、`fromJsonFile`）写进当前 commit 元数据，README 徽章从 `/-/badge/annotation/commit/latest/{key}` 读。

两个时间字段别混：`source_date` 是提交时间（`BUILD_DATE`，与镜像 `LABEL` 的 `created` 同值，为了让同一 commit 的两次构建 config 一致），`built_at` 是流水线实际运行的时刻（`BUILT_AT`）。标签不再带日期，**`built_at` 因此是唯一记录「什么时候构建的」的地方**，每次构建都要写，「这份产物是哪天做的」只能来元数据里查。细节见 [构建元数据](metadata-and-badges.md)。

## 可追溯与可复现：标签不承诺稳定，digest 才是凭据

基座默认跟随 `latest`，标签又都不带日期、每天重建会被覆盖，所以**标签本身不承诺稳定内容**：今天拉 `3.25.1` 和上周拉 `3.25.1`，可能是两次不同构建的结果。这不是缺陷，是取舍——换来的是「标签和 alpine 版本一一对应」和「每天自动吃到上游补丁」。

于是两件事要分开看：

- **可追溯**：每次构建都在 `.cnb/annotation.json` 里写下 `image_digest`、`built_at`、`alpine_version`、`base_digest`。这四样合起来能回答「这份产物是什么时候、基于哪一份 alpine 构建的」，并且能反过来定位到一个不可变的 digest。
- **可复现**：按 digest 拉取，而不是按标签。`image_digest` 一旦拿到，内容就固定了：

```bash
docker pull docker.cnb.cool/dtapp/alpine@sha256:<image_digest>
```

两个必须知道的限制：

- `annotation.json` 属于 commit 元数据，**每次构建都会被覆写，只保留最近一次**。要长期留档（发布记录、事故取证）就得自己把 digest 抄到别处，或者在上层流水线里另存一份。
- 想重建「内容相同的镜像」，除了 digest 还得钉住基座：把记录下来的 `base_digest` 写成 `--build-arg ALPINE_VERSION=3.25.1@sha256:<64 位 hex>`。只钉镜像 digest 只能「拉回旧产物」，不能「重新造出同一份」。

| 依据                                                  | 回答的问题             | 稳定性     |
|-------------------------------------------------------|------------------------|------------|
| `annotation.json` 的 `image_digest`                   | 那次构建的产物是哪一份 | 仅最近一次 |
| `annotation.json` 的 `built_at`                       | 那次构建发生在什么时候 | 仅最近一次 |
| `annotation.json` 的 `alpine_version` / `base_digest` | 那次基于哪一份 alpine  | 仅最近一次 |
| 标签 `3.25.1` / `3.25` / `latest`                     | 这条线现在指向什么     | 会移动     |

反过来，只想要「稳定基线」而不关心上游补丁，就传 `3.25.1`；想连基座都钉死，就传 `3.25.1@sha256:...`。两种诉求用同一行 ARG 表达，不需要改文件。

## 构建失败怎么定位

| 现象                     | 常见原因                    | 处置                                                |
|--------------------------|-----------------------------|-----------------------------------------------------|
| `version` 校验失败       | 非法值、截短的 digest       | 用 `latest` / `3.25` / `3.25.1`                     |
| 第 3 段解析基座失败      | Docker 不可用、拉不到镜像   | 手工跑一次 `docker run --rm alpine:latest`          |
| `FROM` 阶段失败          | 钉的版本不存在              | 用真实 tag，或传空走 `latest`                       |
| `docker login` 返回 401  | token 未注入                | 检查 `imports` 与环境仓库                           |
| buildx 自检失败          | 缺 buildx、误建了 builder   | 用 `services: docker` 内置的                        |
| `apk add` 卡住或超时     | 某个源当前不可用            | 按 [APK 源与网络](mirrors.md)                       |
| 冒烟失败、`latest` 未动  | 基座/时区/源/命令/标签不符  | 看失败断言；版本标签此时指向该产物，可直接 run 排查 |
| `base_digest` 为 unknown | `imagetools inspect` 没取到 | 确认能访问 Docker Hub registry                      |

定位手法：

- 脚本用 `info()` 逐段打印当前动作（`解析基座`、`构建`、`派生`、`冒烟测试`、`提升`、`digest`），日志里最后出现的那一行就是失败位置；`die()` 输出的 `错误: ...` 是具体原因。
- 每条 `docker` 命令失败即退出，不会出现「命令失败但流水线继续」的假成功；冒烟失败时也不会有半截的 `latest` 被推上去。
- 需要复现单条命令时，把 `${CNB_*}` 换成自己的值，在本地按同样的参数跑一次。

## 先在 fork 或私有路径试推

- 镜像是从**运行流水线的那个仓库**的 slug 推出去的：`IMAGE` 由 `CNB_REPO_SLUG_LOWERCASE` 拼成，所以从 fork 或自己的仓库触发，产物落到 `docker.cnb.cool/<你的命名空间>/alpine`，不会碰 `dtapp/alpine`。
- 本地试推自己的 tag：

```bash
docker login <your-registry>
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile.alpine --build-arg ALPINE_VERSION=3.25.1 \
  -t <your-registry>/alpine:test --push .
```

- 不要在 `dtapp/alpine` 上做实验性推送：所有标签都会动（版本标签每天被覆盖、`3.25`/`latest` 被提升），一次错推会直接影响所有按这些标签拉取的下游，而且同名标签覆盖掉旧 digest 后无法还原。真正需要实验时推 `<你的命名空间>` 下的独立仓库或自造的临时标签。
- 改完脚本用 `make format-shell`（`shfmt -w -i 2 -ci -bn -s -ln posix`）对齐格式，用 `make lint-shell`（`shellcheck -s sh`）过一遍静态检查，并在 PR 描述里写清改了哪一步。

## 相关文档

- [文档索引](index.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据](metadata-and-badges.md)
