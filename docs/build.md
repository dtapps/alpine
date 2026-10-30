# 构建

> 本地一次 `docker build` 验内容，CI 一次 `buildx build` 出多架构——同一份 Dockerfile、同一个 `ALPINE_VERSION` 参数，差别只在产物怎么落地。

## 本地单架构

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest -t alpine:local .
docker run --rm alpine:local sh -c 'cat /etc/alpine-release; date; command -v curl nc dig'
```

- 构建上下文是仓库根目录（命令最后的 `.`），Dockerfile 在 `.cnb/docker/`，所以必须 `-f` 指定；`COPY` 之类的相对路径仍以根目录为基准。
- 不传 `--build-arg` 时用 `ARG ALPINE_VERSION=latest` 的默认值。
- 这是最快的验证路径：宿主架构即产物架构，产物直接进本地 image store，可以立刻 `docker run`。

## 多架构的三种落地方式

| 方式     | 关键参数                                    | 产物                       | 限制                              |
|----------|---------------------------------------------|----------------------------|-----------------------------------|
| `--load` | `--platform linux/amd64 --load`             | 本地 image store           | 只能单平台                        |
| `--push` | `--platform linux/amd64,linux/arm64 --push` | 仓库，多架构 manifest list | 需先 `docker login`，产物不在本地 |
| OCI tar  | `--output type=oci,dest=out.tar`            | 本地 tar 文件              | 不能 `docker load`                |

- `--load` 的限制来自本地 image store 不支持 manifest list：多平台 + `--load` 会直接报 `docker exporter does not currently support exporting manifest lists`。要在本地同时拿到两个架构，只能分两次单平台 `--load`，而两次会争抢同一个标签名，所以本地多平台验证通常改用 OCI tar。
- `--push` 是 CI 唯一使用的模式：产物必须进制品库，标签才有意义。本地不要随手 `--push` 到 `docker.cnb.cool/dtapp/alpine`，会覆盖对外标签。
- `--output type=oci,dest=out.tar` 把多平台产物落成一个 OCI layout 的 tar，适合留档或转交给别的机器。`docker load` 不认 OCI layout，认的是 `type=docker,dest=out.tar`，后者同样只支持单平台。

本地多架构示例：

```bash
docker buildx create --name alpine-multi --driver docker-container --bootstrap --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest \
  -t alpine:local --output type=oci,dest=out.tar .
```

第一行的自建 builder 只需要执行一次：默认的 `docker` driver 不支持多平台，容器驱动的 builder 才支持。**但这只适用于本地**——CNB 的 `services: docker` 已经内置可做多架构的 builder，流水线里不要再 `docker buildx create --driver docker-container`，受限容器里拉不起嵌套 buildkitd，会以 bootstrap 失败告终（脚本注释里写明了这条）。

## buildx 常用参数与缓存

| 参数          | 作用            | 本仓库用法                           |
|---------------|-----------------|--------------------------------------|
| `-f`          | 指定 Dockerfile | `.cnb/docker/Dockerfile`             |
| `--platform`  | 目标平台        | 多架构那步两个，单平台那步一个       |
| `--build-arg` | 传构建参数      | `ALPINE_VERSION=${INTERIOR_VERSION}` |
| `--push`      | 构建完直接推送  | 三次构建都带                         |

缓存规律：

- 同一个 builder 内的 BuildKit 层缓存自动复用。脚本里第 2、3 次 `buildx build` 与第 1 次共用同一个 builder，命中缓存后主要开销只剩推层。
- 缓存键由「本层指令 + 上层内容」算出，所以 Dockerfile 的段落顺序直接决定复用率：换源、装包在前，清理在最后；新增指令要加在清理层之前，缓存只失效它之后的部分。加在清理层之后既不享受这条规律，也会让「清理在最后一层」失效。
- 跨机器或跨流水线复用需要显式导出导入（仓库当前没有启用，仅列出做法）：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --cache-to type=registry,ref=<registry>/alpine:buildcache \
  --cache-from type=registry,ref=<registry>/alpine:buildcache \
  -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest -t <registry>/alpine:test --push .
```

## CI 构建脚本逐段

`.cnb/scripts/build-image.sh` 被 `source` 执行而不是 `sh build-image.sh`，因为 `##[set-output]` 与 `export` 都要在当前 shell 里生效。

1. **version 清洗**：`tr -d '[:space:]'`、`tr -d '\n\r'` 去空白与换行，`sed 's/[^[:print:]]//g'` 去不可打印字符，最后空值回落 `latest`。目的是让输入直接进 `-t` 与 `--build-arg` 时不会因为多一个空格变成非法标签。

2. **输出与导出**：

```bash
echo "##[set-output interior_version=$version]"
export INTERIOR_VERSION="$version"
```

`##[set-output ...]` 是 CNB Stage Result 的输出协议，后续步骤能读到 `interior_version`；`export` 让脚本后面所有命令共用同一个值。

3. **登录**：

```bash
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}" || exit 1
```

凭证来自 `imports` 引入的组织环境（`https://cnb.cool/dtapp/envs/-/blob/main/docker.yml`），仓库里不存在任何 token，见 [安全基线](security-baseline.md)。

4. **拼变量与三组标签**：`IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"`，`BUILD_ARGS` 固定为 `--build-arg ALPINE_VERSION=${INTERIOR_VERSION}`。三组 `-t` 都以 `latest` 打底，只有当 `INTERIOR_VERSION != latest` 时才追加版本标签：

| 组     | 恒定标签             | 版本标签                |
|--------|----------------------|-------------------------|
| 多架构 | `latest`             | `<version>`             |
| amd64  | `latest-linux-amd64` | `<version>-linux-amd64` |
| arm64  | `latest-linux-arm64` | `<version>-linux-arm64` |

所以定时任务永远只产出 `latest`，历史版本不会被自动覆盖。

5. **buildx 自检**：`docker buildx version`、`docker buildx ls`、`docker buildx inspect` 各带 `|| exit 1`。builder 不可用时立刻停下，而不是等第一次 build 抛一个更长更难读的错误。

6. **三次 `buildx build --push`**：顺序固定为多架构 → amd64 → arm64，三次都带同一份 `BUILD_ARGS`，保证三类标签指向同一份内容；每步 `|| exit 1`，不会留下「只有多架构、没有单平台」的半成品还继续写元数据。这一步的机制说明见 [仓库架构](architecture.md)。

7. **元数据汇总**：用 `docker buildx imagetools inspect` 取 index 的 digest；体积必须按平台算——对每个平台先定位到该平台的镜像清单，再对清单里 `layers` 的 `size` 求和，解析不出合理值时记 `-1`。结果写成 `.cnb/annotation.json` 五个 key，由流水线第二步的 `cnbcool/annotations` 插件（`type: ADD`、`fromJsonFile`）写进当前 commit 元数据，README 徽章从 `/-/badge/annotation/commit/latest/{key}` 读。细节见 [构建元数据](metadata-and-badges.md)。

## 构建失败怎么定位

| 现象                               | 常见原因                                          | 处置                                                 |
|------------------------------------|---------------------------------------------------|------------------------------------------------------|
| `FROM` 阶段失败                    | `ALPINE_VERSION` 不是 Docker Hub 上真实存在的标签 | 用 `3.20`、`3.21` 这类完整 `major.minor`             |
| `docker login` 返回 401            | `CNB_TOKEN` / `CNB_TOKEN_USER_NAME` 未注入        | 检查 `imports` 是否成功、环境仓库是否可读            |
| buildx 自检失败或 bootstrap 超时   | 误建了 `docker-container` builder                 | 去掉自建 builder，直接用平台内置的                   |
| `apk add` 卡住或超时               | 某个源当前不可用                                  | 按 [APK 源与网络](mirrors.md) 的 `curl` 循环逐个探活 |
| 元数据 `image_digest` 为 `unknown` | `imagetools inspect` 没取到 digest                | 先确认推送成功，再手工跑一次 `imagetools inspect`    |

定位手法：

- 脚本每段都有 `echo` 标记（`== buildx 环境 ==`、`== 汇总镜像元数据 ==` 等），日志里最后出现的标记就是失败位置。
- 每条 `docker` 命令后面都跟 `|| exit 1`，不会出现「命令失败但流水线继续」的假成功。
- 需要复现单条命令时，把 `${CNB_*}` 换成自己的值，在本地按同样的参数跑一次。

## 先在 fork 或私有路径试推

- 镜像是从**运行流水线的那个仓库**的 slug 推出去的：`IMAGE` 由 `CNB_REPO_SLUG_LOWERCASE` 拼成，所以从 fork 或自己的仓库触发，产物落到 `docker.cnb.cool/<你的命名空间>/alpine`，不会碰 `dtapp/alpine`。
- 本地试推自己的 tag：

```bash
docker login <your-registry>
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest \
  -t <your-registry>/alpine:test --push .
```

- 不要在 `dtapp/alpine` 上做实验性推送：`latest` 是对外标签，一次错推会直接影响所有以 `FROM ...:latest` 构建的下游；已发布的 digest 也无法回收。
- 改完脚本用 `shfmt -i 2 -ci -bn -s -ln bash` 的规则对齐（`make format-shell`），并在 PR 描述里写清改了哪一次 buildx 调用。

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [构建元数据](metadata-and-badges.md)
