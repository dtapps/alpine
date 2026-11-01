# 镜像构建缓存实现说明

> 讲清本仓库为什么这么改、改了哪几处、代码长什么样。实现在 `.cnb/` 与 `.github/` 两侧，代码片段摘自这两处。

## 一句话原理

buildx 的层缓存键 = **父层 digest + 指令文本 + 所有 build-arg 的值**。

本仓库的镜像都是「`FROM alpine` + `apk add` 一批包」。如果装包层只写 `apk add --no-cache chromium ...`，那么只要父层（基础镜像）和命令文本不变，这一层就永远命中第一次构建的产物——上游把 chromium 从 155 升到 156，镜像里还是旧的。

「每天重建 = 刷新依赖」因此需要一个新的失效信号。我们用的是 **APK 仓库索引指纹**：

1. 在基础镜像容器里跑 `apk update`；
2. 对 `/var/cache/apk/APKINDEX.*` 求 `sha256`，得到 `APK_INDEX_DIGEST`；
3. 把这个值作为 `--build-arg` 传进去，并 `echo` 进装包层的命令文本。

于是缓存键跟着「仓库里到底有哪些包、各自是什么版本」走，而不是跟着日期走。

| 情况                      | 缓存键 | 结果                             |
|---------------------------|--------|----------------------------------|
| 上游仓库没变化            | 不变   | 装包层命中，只剩拉基座与冒烟     |
| 任意包升级（含 chromium） | 变了   | 只重建装包层，`apk add` 拿到新包 |
| 基础镜像 digest 变了      | 变了   | 装包层及之后全部重建（符合预期） |

「每天跟最新」的语义不变：定时任务每天仍然解析一次索引，只是没变化时不再白装 184 个包 / 761 MiB。

## 两个镜像与各自的缓存 ref

缓存按镜像隔离，互不共用：

| 镜像            | 产物引用                     | 缓存 ref                                |
|-----------------|------------------------------|-----------------------------------------|
| Alpine 基础镜像 | `<registry>/<slug>`          | `<registry>/<slug>:buildcache`          |
| Chromium        | `<registry>/<slug>/chromium` | `<registry>/<slug>/chromium:buildcache` |

Chromium 的基座就是本仓库构建的 Alpine 镜像，但它有自己的装包层（chromium 闭包），所以必须用自己的 cache ref；共用会把两套完全不同的层混在一起。

## 改造点一：`LABEL` 移到文件最后

`org.opencontainers.image.created` / `revision` / `version` 每次构建都变。放在文件开头，会让它后面**所有层**（装包、时区、清理）的缓存键跟着每次提交一起变，registry 缓存直接失效。

两个 Alpine Dockerfile 都把 `LABEL` 整块挪到了所有 `RUN` 之后：

```dockerfile
# ... 所有 RUN 都在前面 ...

# created / revision / version 每次构建都会变；放在文件开头会让它下面所有层
# 的缓存键跟着变，registry 缓存就永远命不中。
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.url="${IMAGE_SOURCE}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.base.digest="${BASE_DIGEST}"
```

Chromium 的 `LABEL` 本来就在最后（`WORKDIR` 之后），未改动。

## 改造点二：APK 索引指纹作为缓存击穿点

解析函数放在两个构建脚本里（CNB 与 GitHub 各一份）。它不依赖 runner 上装了什么，直接在基础镜像容器里算：

```sh
resolve_apk_index_digest() ( # $1=基础镜像引用 $2=是否换成腾讯云源(1/0)
  ref=$1
  mirror=${2:-0}
  docker run --rm --platform linux/amd64 -e "MIRROR=${mirror}" "${ref}" sh -eu -c '
    if [ "${MIRROR}" = "1" ]; then
      sed -i "s@dl-cdn.alpinelinux.org@mirrors.cloud.tencent.com@g" /etc/apk/repositories
    fi
    apk update >/dev/null 2>&1
    printf "APK_INDEX_DIGEST=%s\n" \
      "$(cat /var/cache/apk/APKINDEX.* 2>/dev/null | sha256sum | cut -d" " -f1)"
  ' 2>/dev/null | sed -n 's/^APK_INDEX_DIGEST=//p' | tail -n 1 | tr -d '[:space:]'
)
```

两个细节：

- **解析必须和构建走同一个源。** CNB 的 Alpine Dockerfile 会把 `dl-cdn.alpinelinux.org` 换成腾讯云，所以 CNB Alpine 脚本传 `1`；GitHub 用官方源，传 `0`。Chromium 的基座是本仓库已经配好源的 Alpine 镜像，解析时不再改源。
- **Chromium 用 digest 钉住基座。** 解析时传 `"${BASE_VERSION_REF}@${BASE_DIGEST}"`，和实际 `FROM` 的引用完全一致。

Dockerfile 侧只需要两个改动：声明 `ARG`，并把值 `echo` 进装包层。

```dockerfile
ARG APK_INDEX_DIGEST=0
```

```dockerfile
RUN echo "apk-index: ${APK_INDEX_DIGEST}" \
    && apk add --no-cache \
      chromium \
      ...
```

`echo` 不是装饰：它把值写进这一层的命令文本，值一变缓存键就变。Dockerfile 里 `ARG` 的默认值保持 `0`，本地裸 `docker build` 不传也能构建，行为与改造前一致。

调用处（以 Chromium 为例）：

```sh
APK_INDEX_DIGEST="disabled"
if [ "${CACHE}" = "on" ]; then
  info "解析 APK 仓库索引指纹（缓存击穿点）"
  APK_INDEX_DIGEST="$(resolve_apk_index_digest "${BASE_VERSION_REF}@${BASE_DIGEST}")"
  if [ -z "${APK_INDEX_DIGEST}" ]; then
    warn "APK 索引解析失败，本次关闭缓存（全量重建）"
    CACHE="off"
    APK_INDEX_DIGEST="unknown"
  else
    info "APK_INDEX_DIGEST ${APK_INDEX_DIGEST}"
  fi
fi
```

## 改造点三：registry 缓存与 `build_image()`

缓存写到镜像自己的 `buildcache` 标签，`mode=min`（两个镜像都是单阶段构建，所有层都在最终镜像里）。

先探测缓存 ref 是否存在，再决定加不加 `--cache-from`：第一次构建时它还不存在，有些 buildx 版本直接传会报错。

```sh
CACHE_REF="${IMAGE}:${CACHE_REF_SUFFIX}"
CACHE_FROM_READY=""
if [ "${CACHE}" = "on" ]; then
  if docker buildx imagetools inspect "${CACHE_REF}" >/dev/null 2>&1; then
    CACHE_FROM_READY=yes
    info "缓存源 ${CACHE_REF} 可读，本次尝试命中"
  else
    info "缓存源 ${CACHE_REF} 还不存在，本次只写不读"
  fi
fi
```

构建包成函数，`on` / `off` / `plain` 三种模式（下面以 Chromium 为例；Alpine 侧把参数直接写在 `set --` 里，结构相同）：

```sh
build_image() (
  mode=$1
  set -- -t "${IMAGE}:${STAMP}" --platform "${PLATFORMS}" ${COMMON_ARGS}
  case "${mode}" in
    on)
      if [ -n "${CACHE_FROM_READY}" ]; then
        set -- "$@" --cache-from "type=registry,ref=${CACHE_REF}"
      fi
      set -- "$@" --cache-to "type=registry,ref=${CACHE_REF},mode=${CACHE_MODE}"
      ;;
    off) set -- "$@" --no-cache ;;
    *) : ;;
  esac
  set -- "$@" -f "${DOCKERFILE}" --push .
  docker buildx build "$@"
)

if [ "${CACHE}" = "off" ]; then
  build_image off || die "docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 缓存清单，而且缓存导出是在镜像推完之后才报错。
  # 去掉缓存重试一次，别让当天的构建白跑。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "docker buildx build 失败"
fi
```

为什么用 `mode=min`：单阶段构建，每一层都在最终镜像里，`min` 已覆盖整条链，而且缓存清单引用的 blob 与镜像层是同一批 digest，不产生没人引用的孤儿 blob。**改成多阶段构建要换成 `mode=max`**，否则中间阶段的层不会被导出。

## 改造点四：`CACHE` 开关与失败降级

```sh
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac
```

- 默认 `on`：读写 `<镜像>:buildcache`。
- `CACHE=off`：`--no-cache` 全量重建，等价于改造前。
- **解析失败自动降级。** 索引算不出来时脚本把本次 `CACHE` 改成 `off`、`APK_INDEX_DIGEST` 记为 `unknown`。宁可全量重建，也不带着空键去读可能过期的缓存。

## 改造点五：元数据记录

两个脚本都把本次的实际值写进 annotation，方便回查「某天的镜像里到底是哪份索引」：

```json
{
  "apk_index_digest": "…",
  "cache": "on"
}
```

Chromium 侧加 `chromium_` 前缀（`chromium_apk_index_digest` / `chromium_cache`），避免和同一 commit 上 Alpine 的键互相覆盖。

## 为什么不用 `type=gha`

GitHub 侧原来用 `type=gha`，这次一并换成 registry 缓存：

- `type=gha` 需要额外暴露 `ACTIONS_CACHE_URL` / `ACTIONS_RUNTIME_TOKEN`，裸调 `docker buildx build` 时要自己传；
- 有 10 GB 上限，Chromium 的装包层很大，容易挤掉别的缓存；
- registry 缓存与平台无关，CNB 与 GitHub 可以共用同一套脚本结构，只是缓存 ref 的地址不同；
- 缓存清单是普通 manifest，仓库页面会多一个 `buildcache` 标签，属正常现象。

## 改动清单

两侧（CNB / GitHub）各一份，改动一一对应：

- [X] Alpine Dockerfile：`LABEL` 整块移到所有 `RUN` 之后。
- [X] Alpine Dockerfile：新增 `ARG APK_INDEX_DIGEST=0`，并 `echo` 进装包层。
- [X] Chromium Dockerfile：`CACHE_BUST` 改名为 `APK_INDEX_DIGEST`，`echo` 文本同步。
- [X] 四个构建脚本：加 `resolve_apk_index_digest()`，构建前解析索引。
- [X] 四个构建脚本：把 `docker buildx build` 包成 `build_image()`。
- [X] 四个构建脚本：加 `--cache-to/--cache-from type=registry,ref=<镜像>:buildcache,mode=min`。
- [X] 四个构建脚本：加 `CACHE=on/off` 开关、缓存存在性探测、失败去掉缓存重试。
- [X] 四个构建脚本：解析失败自动降级为 `CACHE=off`。
- [X] Alpine 构建加 `--pull`，确保基础镜像 digest 刷新。
- [X] annotation 加 `apk_index_digest` / `cache`（Chromium 加 `chromium_` 前缀）。
- [X] 每个镜像用自己的 cache ref，不共用。
- [X] 跑格式化与 lint（`shfmt -i 2 -ci -bn -s -ln posix` + `shellcheck -s sh -S warning`）。

## 怎么验证

### 看层是否命中

```bash
docker buildx build --progress=plain ... 2>&1 | grep -E 'CACHED|RUN '
```

命中时对应 `RUN` 显示 `CACHED`。第一次必然全 miss，第二次应该大部分命中。

### 看解析结果

构建日志里会有：

```text
  解析 APK 仓库索引指纹（缓存击穿点）
  APK_INDEX_DIGEST 9f2c…
  CACHE       on
```

如果这里出现「APK 索引解析失败，本次关闭缓存」，说明网络或 `apk update` 有问题，本次会全量重建（构建仍然正确）。

### 确认标签契约没变

缓存改造**不应该**动任何标签规则。改完用这个命令对比改造前后：

```bash
git diff HEAD -- .cnb/scripts/build-alpine.sh .github/scripts/build-alpine.sh \
  | grep -E '^[-+].*(STAMP=|MINOR=|imagetools create|for tag in)'
```

输出为空 = 标签逻辑逐字节没变。

## 踩过的坑

1. **`LABEL` 不放最后，缓存基本白做。** `BUILD_DATE` 每次构建都变，它下面的层每天全 miss。
2. **索引指纹必须和实际构建用同一个源。** CNB 换腾讯云、GitHub 用官方源；解析时改了源，构建时没改（或反过来），指纹就和真实索引对不上。
3. **Chromium 解析要用 digest 引用。** 用 `:latest` 解析、用 `@digest` 构建，中间基座被别的流水线挪走时，指纹会对不上。
4. **`mode=min` 只适合单阶段构建。** 多阶段构建的中间层不在最终镜像里，`min` 导不出来，要改 `mode=max`。
5. **registry 可能不接受 cache manifest。** 表现为「镜像已经推上去了，但步骤失败」。必须加重试分支，否则当天的构建白跑。
6. **探测缓存是否存在再决定加不加 `--cache-from`。** 第一次构建时 cache ref 还不存在，直接传有些 buildx 版本会报错。
7. **解析失败要降级，不能带着空值读缓存。** 空 `APK_INDEX_DIGEST` 会变成一个稳定的键，反而可能命中旧层。
8. **缓存命中不等于跳过冒烟。** 冒烟跑在 `docker run` 的新容器里，缓存只影响构建阶段。这个设计要保留，它是「`latest` 只在验证通过后才提升」的保证。
9. **首次上线建议先跑一次 `CACHE=off`。** 建立可信基线，再开缓存；坏二进制不会被缓存固化。

## 回滚

```bash
CACHE=off source ./build.sh
```

行为完全等价于改造前（全量重建），不需要回滚代码。

## 代码位置

| 文件                                                                    | 内容                                                           |
|-------------------------------------------------------------------------|----------------------------------------------------------------|
| `.cnb/docker/Dockerfile.alpine`、`.github/docker/Dockerfile.alpine`     | `LABEL` 后移、`ARG APK_INDEX_DIGEST`、装包层 `echo`            |
| `.cnb/docker/Dockerfile.chromium`、`.github/docker/Dockerfile.chromium` | `APK_INDEX_DIGEST` 替换 `CACHE_BUST`、装包层 `echo`            |
| `.cnb/scripts/build-alpine.sh`、`.github/scripts/build-alpine.sh`       | `resolve_apk_index_digest`、`build_image`、`CACHE`、annotation |
| `.cnb/scripts/build-chromium.sh`、`.github/scripts/build-chromium.sh`   | 同上（Chromium 侧解析基座 digest 引用）                        |
| [alpine/build.md](alpine/build.md)                                      | Alpine 构建流程与缓存章节                                      |
| [chromium/build.md](chromium/build.md)                                  | Chromium 构建流程与缓存章节                                    |
