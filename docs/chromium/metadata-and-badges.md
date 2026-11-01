# 构建元数据与徽章

> 每次构建把 digest、两个平台的体积、基座信息、APK 索引指纹、Chromium 精确版本、构建时间写成当前 commit 的元数据，README 徽章从这批 key 取值；这里讲生成链路、各 key 的语义、体积为什么按平台分别算，以及 `unknown` 是怎么出现的。本镜像体积在数百 MB 量级，徽章上的数字是压缩后的层体积，不是层数、也不是一次 `docker pull` 的流量。

## 链路

```text
build-chromium.sh
  ├─ docker buildx imagetools inspect           取 <alpine 版本> 的 index digest
  ├─ docker buildx imagetools inspect <基座>:<alpine 版本>   解析基座 digest（构建前已完成）
  ├─ imagetools inspect <alpine 版本>@<平台清单 digest> --raw   取该架构镜像清单里 config 与各 layer 的 size
  ├─ docker run <alpine 版本> chromium --version   取浏览器精确版本
  └─ heredoc 写 .cnb/annotation.json（13 个 key）
          │
          ▼
stages 第二步：image: cnbcool/annotations:latest
  settings: type: ADD / fromJsonFile: .cnb/annotation.json
          │
          ▼
当前 commit 的元数据  ←  /-/badge/annotation/commit/latest/{key}
```

元数据挂在 commit 而不是 tag：本仓库不发版、日常不打 tag，构建只由手动按钮与定时任务产生，commit 是唯一稳定的关联点。这样「某次提交对应哪个镜像」可以直接反查。

## cnbcool/annotations 的两行设置

```yaml
- name: 写入镜像元数据
  image: cnbcool/annotations:latest
  settings:
    type: ADD
    fromJsonFile: .cnb/annotation.json
```

`type: ADD` 表示新增或覆盖 key，`fromJsonFile` 指向脚本写出的扁平 JSON。插件对输入有限制：key 只允许 `0-9a-zA-Z_-`，value 不允许含换行，所以脚本只输出一层、单行的值。

这段 stages 在两个入口各有一份：手动按钮触发的 `.cnb/workflows/build-chromium.yml`（事件 `web_trigger_build_chromium`）与 `.cnb.yml` 里的 `'crontab: 5 1 * * *'`。两份内容必须一致——只改一处，另一条流水线跑完就不会写入元数据，徽章会停在旧值或退回 `unknown`。

## 生成的 JSON

```json
{
  "chromium_image_ref": "docker.cnb.cool/dtapp/alpine/chromium",
  "chromium_image_version": "3.24.3",
  "chromium_image_digest": "sha256:...",
  "chromium_image_digest_short": "前 12 位",
  "chromium_image_size": "412.7MB",
  "chromium_image_size_arm64": "398.4MB",
  "chromium_base_image": "docker.cnb.cool/dtapp/alpine:3.24.3",
  "chromium_base_digest": "sha256:...",
  "chromium_apk_index_digest": "9f2c…",
  "chromium_cache": "on",
  "chromium_version": "155.0.8059.84",
  "chromium_built_at": "2026-10-30T07:01:12Z",
  "revision": "提交 SHA"
}
```

| key                           | 语义                                | 来源                                                                          |
|-------------------------------|-------------------------------------|-------------------------------------------------------------------------------|
| `chromium_image_ref`          | 镜像地址（不含标签）                | 脚本里的 `${IMAGE}`                                                           |
| `chromium_image_version`      | 本次产物的 Alpine 版本              | 从基座容器读出的实际版本（如 `3.24.3`）                                       |
| `chromium_image_digest`       | `<alpine 版本>` 多架构 index 摘要   | `imagetools inspect` 的 `Digest:` 行，取不到则退回模板 `{{.Manifest.Digest}}` |
| `chromium_image_digest_short` | 去掉 `sha256:` 后的前 12 位         | 上面的 digest，只用于徽章                                                     |
| `chromium_image_size`         | amd64 单平台压缩体积                | 多架构 index 里 amd64 清单的 config 与各 layer 的 `size` 合计                 |
| `chromium_image_size_arm64`   | arm64 单平台压缩体积                | 同上，换 arm64                                                                |
| `chromium_base_image`         | 本次构建叠的基座引用                | 脚本解析出的 `<仓库 slug>:<alpine 版本>`                                      |
| `chromium_base_digest`        | 基座多架构 index 的完整摘要         | `imagetools inspect <基座> --format '{{.Manifest.Digest}}'`                   |
| `chromium_apk_index_digest`   | APK 仓库索引的 sha256，装包层击穿点 | 基座容器里 `apk update` 后对 `/var/cache/apk/APKINDEX.*` 求 `sha256`          |
| `chromium_cache`              | 本次是否使用 registry 缓存          | `on` / `off`；索引解析失败时脚本会自动降级成 `off`                            |
| `chromium_version`            | 镜像内 Chromium 的精确版本          | `docker run … chromium --version`，取输出第二列                               |
| `chromium_built_at`           | UTC 构建时间                        | `date -u +%Y-%m-%dT%H:%M:%SZ`                                                 |
| `revision`                    | 构建对应的提交 SHA                  | `CNB_COMMIT` / `GITHUB_SHA`                                                   |

体积值是格式化后的人类可读串（`human_mb` 输出 `%.1fMB`），保留一位小数；`chromium_image_digest_short` 用 `cut -c1-12` 截断，因此只能用于人工核对，不能用于 `docker pull`。

两个值都是数百 MB 量级，其中绝大部分来自 `chromium` 与它依赖的图形栈（`gtk+3.0`、`pango`、`gdk-pixbuf` 等）和 `font-freefont` 字体。看到 `412.7MB` 这种数量级不必怀疑构建出错——本镜像比纯 `alpine` 大一个数量级是设计使然，具体数值随上游 Alpine 仓库里 Chromium 的版本浮动。

## 为什么记基座

Chromium 镜像 `FROM` 的是本仓库构建的 Alpine 基础镜像，而基座 `latest` 每天 `00:05` 被覆盖。只记 Chromium 的 digest 与版本，回答不了「这份 Chromium 叠在哪份 Alpine 上」；两个 key 补的正是这一环：

- `chromium_base_image` 是解析出的基座引用（`<仓库 slug>:<alpine 版本>`，如 `dtapp/alpine:3.24.3`），人可以直接读；
- `chromium_base_digest` 是当时的 index digest，与 OCI 标签 `org.opencontainers.image.base.digest` 同值。基座被重新构建后，即便标签名没变，digest 也能定位到具体那一份。

CI 构建在解析阶段取不到基座就会失败，所以这两个 key 在成功构建里不会是 `unknown`；本地用默认官方 `alpine` 构建且不传 `CHROMIUM_BASE_DIGEST` 时，镜像标签里才会留下 `unknown`。

## 为什么单独记 Chromium 版本

`<alpine 版本>` 标签固定的是 Alpine 版本（`3.24.3`），不是浏览器版本。同一个 `latest`、`3.24` 或 `3.24.3` 标签，今天与一个月后拉到的 chromium 可能是不同版本：分支内会持续更新 chromium 包（仓库里的包版本形如 `155.0.8059.84-r0`），镜像重建一次就漂一次。

三个具体后果：

- 出问题时没法对账。用户报「截图崩了」，你手上只有标签或 digest，没法确认他跑的是不是带某个上游回归的那个修订。
- 标签本身给不出答案。`org.opencontainers.image.version` 是 Alpine 版本；镜像内 `/usr/share/alpine-chromium/VERSION` 有精确版本，但得先把镜像跑起来才看得到。
- 漂移是常态，不是故障。所以不能拿「标签没变」推断「浏览器没变」。

如果填了 `EXPECTED_CHROMIUM_MAJOR`，断言只拦主版本跃迁（上游升到 156 就让构建失败），同一个主版本内的次版本更新照常放行——`chromium_version` 补的正是这个空档：直接回答「这个 digest 里是哪个浏览器」。默认不填则不校验，`chromium_version` 就是唯一的产品答案。

取值就是一行，与脚本里的做法一致：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:3.24.3-linux-amd64 chromium --version
# 输出形如 Chromium 155.0.8059.84   脚本用 awk '{print $2}' 取第二列写进元数据
```

仓库里的包版本还带一层 apk 打包修订（`155.0.8059.84-r0` 这种 `-rN`），那是 apk 包名的一部分，不出现在 `chromium --version` 的版本串里；镜像内 `/usr/share/alpine-chromium/VERSION` 存的就是这条命令的完整输出。

取不到时写 `unknown`，原因通常是 `<alpine 版本>-linux-amd64` 标签没打成功、或容器在 Runner 上起不来；徽章上的 `unknown` 排查与体积那套是同一套步骤，见下文。

## 为什么体积要按平台分别统计

两件事决定了脚本里那段体积算法：

1. manifest list 没有「总拉取体积」。用户 `docker pull` 只会拉自己平台的那几层，把 amd64 与 arm64 相加是个虚构数字。
2. 只有真正的镜像清单才含 `layers` 字段，index 没有，所以求和无意义。

单平台标签现在是**该架构的镜像清单本身**：构建时带了 `--provenance=false --sbom=false`（buildx 不支持时脚本自动跳过），manifest list 里没有 attestation 条目；构建流程第 6 步再用 `docker buildx imagetools create` 把那份清单的 digest 直接打成 `<alpine 版本>-linux-<arch>`（步骤编号见 [CI 流水线](ci-pipeline.md)）。所以 `imagetools inspect "…:3.24.3-linux-amd64" --raw` 返回的就是清单原文，`layers` 在里面，直接求和即可，不用先去 index 里找子 digest。脚本自己算体积时更进一步：直接从多架构 index 里按平台取清单 digest，不依赖单平台标签是否已派生。

脚本仍保留了兜底路径：如果 `--raw` 里找不到 `"layers"`（这个标签是更早的流水线打的，或当前 buildx 不支持关闭 attestation），就回到多架构 index 里按 `Platform.Architecture` 挑出该架构的清单 digest，再 `imagetools inspect "${IMAGE}@${digest}" --raw` 取一次。两条路径之后都先确认含 `"layers"`，再把清单里所有 `"size"` 加起来——config 描述符与每个 layer 各有一处，都是压缩后体积。体积求和低于 1MB 判定为「取到的不是镜像清单」，记 `-1`。

两个架构都记，是因为只查 amd64 会漏掉 arm64 基础包体积异常的情况：同一份 Dockerfile 下两者通常只差几个百分点，一旦拉开差距就说明该平台的包解析出了问题。

## -1 与 unknown 的含义

```bash
# 体积：解析成功输出字节数，失败输出 -1
if [ "${bytes:-0}" -lt 1048576 ]; then echo "-1"; fi

# -1 经 human_mb 变成 unknown
human_mb() { awk -v b="${1:--1}" 'BEGIN{if(b<0) print "unknown"; else printf "%.1fMB", b/1048576}'; }
```

- 求和结果小于 1MB 就判定「取到的不是镜像清单」，输出 `-1`，同时往 stderr 打一行「体积解析失败」加清单前 200 字节；`-1` 再变成 `unknown`。本镜像数百 MB，求和低于 1MB 必然取错了对象——这个阈值只用来区分「层体积」与「清单 JSON 自身的几百字节」，与镜像真实大小无关，所以对 Chromium 镜像而言离真实值极远，不会误判。
- digest 取不到时写 `${DIGEST:-unknown}`、`${DIGEST_SHORT:-unknown}`；`chromium_version` 取不到（平台标签缺失、容器起不来）时同样写 `unknown`。
- 徽章上的灰色 `unknown` 因此有两种成因：这次构建没取到值，或这个 key 从未被写入过。它不代表 0，也不代表体积很小。

## 徽章地址

```text
https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}
```

README 用了其中四个：`chromium_image_size`、`chromium_image_size_arm64`、`chromium_version`、`chromium_image_digest_short`；`chromium_image_digest` 与 `chromium_built_at` 用同一条路径也能读到，只是没放进徽章行。浏览器版本那段的写法就是：

```markdown
![Chromium 版本](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_version)
```

路径里的 `commit/latest` 指最新提交这一维度，与镜像标签 `latest` 同名但无关。

徽章显示 `unknown` 时的排查顺序：

1. 这次构建是否成功，`cnbcool/annotations` 那一步有没有跑（手动与定时两条流水线各有一份，确认改的是触发本次构建的那一份）；
2. Commit → 元数据页面里这批 key 是否存在；
3. 构建日志里有没有「体积解析失败」那一行，它带着清单片段，能直接看出取到的是 index 还是镜像清单；
4. 只是 `chromium_version` 为 `unknown` 时，先确认 `<alpine 版本>-linux-amd64` 标签在不在（单平台派生失败会打告警），再本机 `docker run … chromium --version` 走一遍。

## 重跑同一 commit

`type: ADD` 对同一 commit 是覆盖语义：同名 key 换成新值，只保留最后一次构建的结果。所以元数据记录的是「这个提交最近一次构建产出什么」，不能当版本归档用；要长期锁定某个产物，按 `chromium_image_digest` 以 digest 形式拉取。

## 本地复现查询

不依赖流水线，用同一组命令核对元数据：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine/chromium

# 1. 多架构 index 的 digest（对应徽章 chromium_image_digest）
docker buildx imagetools inspect "${IMAGE}:latest" --format '{{.Manifest.Digest}}'

# 2. 单平台标签的清单原文：它直接就是该架构的镜像清单，含 layers
docker buildx imagetools inspect "${IMAGE}:3.24.3-linux-amd64" --raw | head -20

# 3. config 与各 layer 的 size 合计（字节）
BYTES=$(docker buildx imagetools inspect "${IMAGE}:3.24.3-linux-amd64" --raw \
  | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | awk '{s+=$1} END{print s+0}')

# 4. 换算成 MB，与徽章 chromium_image_size 对照
awk -v b="${BYTES}" 'BEGIN{printf "%.1fMB\n", b/1048576}'

# 5. 这个 digest 里是哪个 Chromium（对应徽章 chromium_version）
docker run --rm "${IMAGE}:3.24.3-linux-amd64" chromium --version
```

第 2 步的 `--raw` 里应该出现 `"layers"`，说明它是镜像清单而不是 index——单平台标签由 `imagetools create` 从 manifest list 里取清单 digest 直接打出，构建时又关掉了 attestation，所以这一步不再需要「先找 index 子 digest」。若返回里只有 `manifests` 没有 `layers`（旧流水线打的标签，或 attestation 没关掉），退回下面这段取子清单：

```bash
PLATFORM_DIGEST=$(docker buildx imagetools inspect "${IMAGE}:latest" --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')
docker buildx imagetools inspect "${IMAGE}@${PLATFORM_DIGEST}" --raw | head -20
```

第 4 步的结果应当是数百 MB 量级（与徽章上的 `chromium_image_size` 同量级，差一点属于正常：本地算的是当前 `latest`，徽章记的是最近一次构建写入的值）。算出来是几 KB 或 0，就说明取错了对象，回去确认第 2 步拿到的到底是镜像清单还是 index。

第 5 步的输出应当与徽章上的 `chromium_version` 一致（本地是当前 `<alpine 版本>`，徽章是最近一次构建写入的值，上游推过补丁就会有差异）；拿到的是 `unknown` 或空行，先确认 `<alpine 版本>-linux-amd64` 这个标签存在、且容器能在本机跑起来。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [构建与本地复现](build.md)
- [镜像与标签](images-and-tags.md)
- [排错手册](troubleshooting.md)
- [维护手册](maintenance.md)
