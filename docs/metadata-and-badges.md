# 构建元数据与徽章

> 每次构建把 digest、两个平台的体积、构建时间写成当前 commit 的元数据，README 徽章从这批 key 取值；这里讲生成链路、五个 key 的语义，以及 `unknown` 是怎么出现的。

## 链路

```text
build-image.sh
  ├─ docker buildx imagetools inspect     取 latest 的 digest
  ├─ 逐平台取镜像清单 --raw               取 layers 体积
  └─ heredoc 写 .cnb/annotation.json
          │
          ▼
stages 第二步：image: cnbcool/annotations:latest
  settings: type: ADD / fromJsonFile: .cnb/annotation.json
          │
          ▼
当前 commit 的元数据  ←  /-/badge/annotation/commit/latest/{key}
```

元数据挂在 commit 而不是 tag：本仓库不发版、日常不打 tag，构建只由 push 与定时任务产生，commit 是唯一稳定的关联点。这样「某次提交对应哪个镜像」可以直接反查。

## cnbcool/annotations 的两行设置

```yaml
- name: 写入镜像元数据
  image: cnbcool/annotations:latest
  settings:
    type: ADD
    fromJsonFile: .cnb/annotation.json
```

`type: ADD` 表示新增或覆盖 key，`fromJsonFile` 指向脚本写出的扁平 JSON。插件对输入有限制：key 只允许 `0-9a-zA-Z_-`，value 不允许含换行，所以脚本只输出一层、单行的值。

## 生成的 JSON

```json
{
  "image_digest": "sha256:...",
  "image_digest_short": "前 12 位",
  "image_size": "12.3MB",
  "image_size_arm64": "12.1MB",
  "built_at": "2026-10-30T07:01:12Z"
}
```

| key                  | 语义                             | 来源                                                                          |
|----------------------|----------------------------------|-------------------------------------------------------------------------------|
| `image_digest`       | `latest` 多架构 index 的完整摘要 | `imagetools inspect` 的 `Digest:` 行，取不到则退回模板 `{{.Manifest.Digest}}` |
| `image_digest_short` | 去掉 `sha256:` 后的前 12 位      | 上面的 digest，只用于徽章                                                     |
| `image_size`         | amd64 单平台压缩体积             | 该平台镜像清单里各 layer 的 `size` 求和                                       |
| `image_size_arm64`   | arm64 单平台压缩体积             | 同上                                                                          |
| `built_at`           | UTC 构建时间                     | `date -u +%Y-%m-%dT%H:%M:%SZ`                                                 |

体积值是格式化后的人类可读串（`human_mb` 输出 `%.1fMB`），保留一位小数；`image_digest_short` 用 `cut -c1-12` 截断，因此只能用于人工核对，不能用于 `docker pull`。

## 为什么体积要按平台分别统计

三件事叠在一起，决定了脚本里那段看起来绕的体积算法：

1. manifest list 没有「总拉取体积」。用户 `docker pull` 时只会拉自己平台的那几层，把 amd64 与 arm64 相加是个虚构数字。
2. 不能对单平台 tag 直接求和。buildx 默认带 attestation，单平台推送出来的依然是一个 index，其中每个条目的 `size` 只是清单 JSON 自身的一两 KB，直接求和会得到几 KB 的假值。
3. 只有真正的镜像清单才含 `layers` 字段。index 没有，所以求和无意义。

脚本的处理顺序是：先按 `Platform.Architecture` 从多架构 index 里挑出该平台的镜像清单 digest，再 `imagetools inspect "${IMAGE}@${digest}" --raw` 取清单原文；挑不到时退回 `latest-linux-<arch>` 再试一次。拿到原文后先确认含 `"layers"`，才把 `"size"` 求和。

两个架构都记，是因为只查 amd64 会漏掉 arm64 基础包体积异常的情况：同一份 Dockerfile 下两者通常只差几个百分点，一旦拉开差距就说明该平台的包解析出了问题。

## -1 与 unknown 的含义

```bash
# 体积：解析成功输出字节数，失败输出 -1
if [ "${bytes:-0}" -lt 1048576 ]; then echo "-1"; fi

# -1 经 human_mb 变成 unknown
human_mb() { awk -v b="${1:--1}" 'BEGIN{if(b<0) print "unknown"; else printf "%.1fMB", b/1048576}'; }
```

- 求和结果小于 1MB 就判定「取到的不是镜像清单」，输出 `-1`，同时往 stderr 打一行「体积解析失败」加清单前 200 字节；`-1` 再变成 `unknown`。正常 alpine 镜像不可能小于 1MB，这个阈值是经验下界。
- digest 取不到时写 `${DIGEST:-unknown}`、`${DIGEST_SHORT:-unknown}`。
- 徽章上的灰色 `unknown` 因此有两种成因：这次构建没取到值，或这个 key 从未被写入过。它不代表 0，也不代表体积很小。

## 徽章地址

```text
https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}
```

README 用了其中三个：`image_size`、`image_size_arm64`、`image_digest_short`；`image_digest`、`built_at` 用同一条路径也能读到，只是没放进徽章行。路径里的 `commit/latest` 指最新提交这一维度，与镜像标签 `latest` 同名但无关。

徽章显示 `unknown` 时的排查顺序：

1. 这次构建是否成功，`cnbcool/annotations` 那一步有没有跑；
2. Commit → 元数据页面里这批 key 是否存在；
3. 构建日志里有没有「体积解析失败」那一行，它带着清单片段，能直接看出取到的是 index 还是镜像清单。

## 重跑同一 commit

`type: ADD` 对同一 commit 是覆盖语义：同名 key 换成新值，只保留最后一次构建的结果。所以元数据记录的是「这个提交最近一次构建产出什么」，不能当版本归档用；要长期锁定某个产物，按 `image_digest` 以 digest 形式拉取。

## 本地复现查询

不依赖流水线，用同一组命令核对元数据：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine

# 1. 多架构 index 的 digest
docker buildx imagetools inspect "${IMAGE}:latest" --format '{{.Manifest.Digest}}'

# 2. 该平台镜像清单的 digest（示例 amd64，换 arm64 只改 Architecture）
PLATFORM_DIGEST=$(docker buildx imagetools inspect "${IMAGE}:latest" --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')

# 3. 该镜像清单里的层体积合计（字节）
BYTES=$(docker buildx imagetools inspect "${IMAGE}@${PLATFORM_DIGEST}" --raw \
  | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | awk '{s+=$1} END{print s+0}')

# 4. 换算成 MB，与徽章值对照
awk -v b="${BYTES}" 'BEGIN{printf "%.1fMB\n", b/1048576}'
```

第 3 步必须用第 2 步得到的平台清单 digest；把 `PLATFORM_DIGEST` 换成单平台 tag 名去 `--raw`，返回里没有 `layers`（buildx attestation 让单平台 tag 也是 index），求和结果只有几 KB，不能当体积用。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [镜像与标签](images-and-tags.md)
- [故障排查](troubleshooting.md)
- [维护手册](maintenance.md)
