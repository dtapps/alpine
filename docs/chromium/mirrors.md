# APK 源与网络策略

> 两个平台策略不同：CNB 侧 Chromium 层把基座源的主机名替换为腾讯云；GitHub runner 在境外，整层不换源，沿用基座（官方 `alpine`）自带的源。两边都保留 `main` + `community` 两行，索引与包的签名仍由 Alpine 官方公钥校验。

## 为什么 CNB 换源、GitHub 不换

- CNB 构建在国内跑，官方源 `dl-cdn.alpinelinux.org` 在国内解析与下载都不稳定。`apk add` 卡在这里，表现为流水线超时，失败点却不在代码上，排查成本高。本镜像要装的又是 Chromium 这种大包，源慢的代价比装几个小工具明显得多。
- GitHub runner 在境外，与官方源之间的路径通常最短；再指向国内镜像反而可能绕远、更慢。所以 `.github/docker/Dockerfile.chromium` 没有换源步骤。
- 换源只改 `/etc/apk/repositories` 这一个文本文件，不改变包的来源身份：包仍由 Alpine 官方构建并签名，镜像站只承担分发。
- 收益是构建速度与稳定性，代价是信任面变大（仅 CNB 侧）——这件事在 [SECURITY](../../SECURITY.md) 里被列为已知取舍，最后一节展开。

## 与基座的源配置有什么关系

CNB 基座（本仓库 Alpine 基础镜像）已经把主机名替换为腾讯云，`main` + `community` 两行都在。Chromium 的 STEP 1 再做一次同样的 `sed`：

- 基座已经换过源时，它是幂等的，不会改变文件。
- 本地不传 `CHROMIUM_BASE_IMAGE`、直接用官方 `alpine` 构建时，它把官方源换成腾讯云，和 CI 的拉包路径一致。

GitHub 侧没有这层动作：GitHub 基座从官方 `alpine` 继承的 `repositories` 本来就是 `main` + `community` 两行，直接 `apk add chromium` 即可。

## 为什么只留腾讯云一家（CNB）

早期版本写的是五个镜像站（cernet、腾讯云、阿里云、火山、官方）乘 `main`/`community` 共十行；现在 CNB 侧收敛成腾讯云一台主机、两行。

- **多站混用会撞依赖版本。** 各镜像站的同步进度并不一致，多行仓库最终会被 apk 合并成一张包视图，同一个包在不同站是不同快照时，apk 取版本更高的那一份。一次 `apk add` 里如果 `chromium` 来自 A 站的 `community`、某个 `so:` 依赖来自 B 站的 `main`，就可能拿到彼此不匹配的组合，表现为依赖求解失败或 `so:` 解析不到——而这种失败只在某个站刚同步完、另一个站还没同步的窗口期出现，最难复现。
- **行数就是索引请求数。** `main` 与 `community` 各算一个独立仓库，每个仓库都要拉一份 `APKINDEX`。收敛到一台主机两行后，构建起步阶段的请求数、重试等待与 `WARNING` 噪声一起下降。
- 单源也意味着没有跨站兜底：腾讯云不可达时构建直接失败，而不是悄悄换站。这是有意的取舍。

## STEP 1 为什么用 sed

```dockerfile
RUN sed -i 's@dl-cdn.alpinelinux.org@mirrors.cloud.tencent.com@g' /etc/apk/repositories
```

- 基座的 `repositories` 已经写好 `vX.Y` 与 `main` / `community` 两行，只换主机名就不用在本仓库重复维护版本路径与仓库列表。
- `chromium` 在 **community**，两行都必须留；`sed` 天然保留全部行，不会像手写列表那样漏掉一条。
- 主机名匹配不上时 `sed` 不生效，仍走官方源，构建不会失败。这比「匹配不上就写坏文件」安全。
- 前提是 `FROM` 引用的基座确实存在；`version` 传了不存在的版本，脚本在解析基座 digest 时就会失败，不会走到这一段。

顺带说明一个常被搞混的点：这里的版本号是 **Alpine 版本**，Chromium 的版本由该 Alpine 版本的软件包仓库决定，不受 `version` 入参控制。而且 `chromium` 在 **community** 仓库，Alpine 的 community 只维护到「下一个 stable 发布」，所以每个分支的 Chromium 会冻住——3.24 当前是 `155.0.8059.84-r0`（仓库里的包版本，带 apk 的 `-rN` 修订），老分支停在更早的主版本。

## 两行源

| 顺序 | 源     | URL 前缀                            | 角色                      |
|------|--------|-------------------------------------|---------------------------|
| 1    | 腾讯云 | `https://mirrors.cloud.tencent.com` | `main` + `community` 同源 |

同一主机两行（`.../alpine/vX.Y/main` 与 `.../alpine/vX.Y/community`）写入 `/etc/apk/repositories`。`main` 与 `community` 都要留：`apk add` 只认包名、不指定仓库，少写哪个仓库就少一份索引，缺包时表现为「包不存在」而不是「源有问题」。

容器里看实际生成的内容：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest cat /etc/apk/repositories
```

实际就是两行（以 `3.24` 为例）：

```text
https://mirrors.cloud.tencent.com/alpine/v3.24/main
https://mirrors.cloud.tencent.com/alpine/v3.24/community
```

GitHub 侧的实际内容由官方镜像决定，主机是 `dl-cdn.alpinelinux.org`，同样是 `main` + `community` 两行。

## 不需要单独的 apk update 层

早期版本的 Dockerfile 在写源同一个 `RUN` 末尾还有一条 `apk update --no-cache`，理由是「换完源立刻验证可达」。现在删掉了，因为 `apk add` 自带索引拉取：

- `apk add --no-cache` 会为每个仓库拉一份 `APKINDEX`，源不可达在装包层立刻暴露，日志里既有 `WARNING` 也有缺包名。专门跑一次 `apk update` 不改变装包层的任何行为。
- `--no-cache` 让索引用完即弃、不落盘，所以那条 `apk update` 在镜像里什么也没留下，紧接着的 `apk add` 还要再拉一遍。它唯一产物是一行日志，代价是每次构建多下一份全量索引、多等一轮网络请求。
- 结论：源可达性由装包层顺带验证，不必为它单独埋一条命令。判断方式见下文「验证某个源现在可用」。

## apk 的仓库尝试语义

- apk 没有优先级字段，`/etc/apk/repositories` 的**行序就是回退序**；每一行是一个独立仓库，`main` 与 `community` 各算一份索引。
- 每次 `apk add`（以及任何需要索引的子命令），apk 为每个仓库取一份 `APKINDEX`，把多份索引合并成一张包视图。
- 单个源不可达只会打印 `WARNING` 并继续，用其余源照常解析；只有当所有源都取不到索引，或者所有源都没有目标包时，命令才失败。
- 现在两个平台都只有一台源主机（CNB 是腾讯云，GitHub 是官方），**没有跨站兜底**：主机不可达时构建直接失败。`main` 与 `community` 两行只解决「仓库缺行」，不解决「站点故障」。
- 同一个包在多个源里都有、版本相同时，先列出的源胜出；版本不同时取版本更高的那一份。所以「换源」不会让包悄悄降级。也正是这条规则，让「多站混用」在同步窗口期变得危险，见上文。

## 验证某个源现在可用

索引 URL 形如 `https://<mirror>/alpine/v3.24/<branch>/<arch>/APKINDEX.tar.gz`，`<branch>` 是 `main` 或 `community`，`<arch>` 是 `x86_64` 或 `aarch64`。先用镜像里的实际版本号替换示例里的 `3.24`：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest cat /etc/alpine-release
```

下面的循环用 `curl`。镜像里已经继承基座的 `curl`，所以宿主机或容器内都能跑；下面按宿主机写，容器内把命令前加 `docker run --rm <image> sh -c '…'` 即可：

```bash
VER=3.24
for host in mirrors.cloud.tencent.com dl-cdn.alpinelinux.org; do
  for branch in main community; do
    printf '%-28s %-10s ' "$host" "$branch"
    curl -sSI -o /dev/null -w '%{http_code} %{time_total}s\n' \
      "https://${host}/alpine/v${VER}/${branch}/x86_64/APKINDEX.tar.gz"
  done
done
```

上面一台主机对应 CNB 的实际源，下面一台对应 GitHub 的实际源。`200` 表示索引可取，耗时那一列可以直接看出线路快慢；`403` / `404` 多为路径或版本号写错；连不上或超时则是网络问题。

容器内的验证走的是镜像里的源配置，比在宿主机上测更贴近真实构建。除了 `curl`，也可以用镜像里必有的 `apk` 做「只解析、不安装」：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest \
  sh -c 'apk add --no-cache --simulate tini'
```

`--simulate` 让它只打印将要装的包、不真正写入，但索引请求照发：输出里出现 `WARNING` 的那几行就是当前不可达的源；想让结果更直白，去掉 `--simulate` 真的装一次 `tini`（23 KiB）也行。这也是「源验证不必单开一层」的直接依据——它和构建时的装包路径完全一样。

## 源挂掉时怎么改

1. 先用上一节的 `curl` 循环（宿主机或容器内均可）区分「某个源挂了」和「整条网络不通」。
2. CNB：只改 `.cnb/docker/Dockerfile.chromium` STEP 1 里 `sed` 的替换目标主机名。GitHub 侧没有源配置可改，先确认 runner 到官方源的网络与上游状态，不要为此临时加国内镜像。
3. 不要在 `printf` 里手写整份源列表：那会把上游的仓库结构复制进本仓库，增删仓库时容易漏改。
4. 本地验证：`docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .`，再按上一节跑一次 `apk add --no-cache --simulate tini`，确认没有新的 `WARNING`。
5. 跑 `make format-docker` 让 `dockerfmt` 统一格式，提交时在 PR 里写明「哪个源、什么症状、什么时候观测到」。
6. 腾讯云长期不可用时再讨论补源：增删源属于对外行为变更，[CONTRIBUTING](../../CONTRIBUTING.md) 要求说明理由；临时堆多个站只会把同步窗口期的拼包风险带回来。

## 供应链信任面

- 信任面：CNB 侧 = 上游 Alpine（基座镜像 + 包）+ 腾讯云；GitHub 侧 = 上游 Alpine + 官方源（同一主体）。已在 [SECURITY](../../SECURITY.md) 的「已知取舍」里写明。
- 镜像站能做的：返回索引与包、拒绝服务、返回旧快照（构建拿到的是过期版本的包）。
- 镜像站无法悄悄塞进一个恶意包：apk 用 `/etc/apk/keys/` 里的 Alpine 官方公钥校验仓库索引与每个 `.apk` 包的签名，签名不符直接拒绝安装。
- 因此换源主要影响**可用性**与**时效性**，不影响包内容的真实性；剩下的风险是构建指纹（源站能看到你请求了哪些包与版本）和「被喂旧索引导致镜像停留在旧包上」。
- 后一条正是每天 `01:05`（Asia/Shanghai，基座 `00:05` 先重建）重建的意义之一：固定节奏重跑，旧索引最多影响一天，详见[维护手册](maintenance.md)。定时任务与手动按钮产出的标签集合相同：`<alpine 版本>` 与单平台标签每次都被覆盖，`<minor>` / `latest` 在基座对齐后自动跟随。
- 补丁要真进镜像，还得防住「缓存命中导致不重装」：CNB 侧不启用跨轮次缓存，每轮重新装包；GitHub 侧用 `CACHE_BUST` 每天击穿 Actions 缓存。机制见[CI 流水线](ci-pipeline.md)的「构建参数与缓存策略」。
- 不要在源 URL 里放任何凭证：本仓库只引用公开镜像站与官方源，不存在私有源与鉴权参数。

## 为什么不再堆多个源

- 多个镜像站的同步进度不一致，apk 会把所有仓库合并成一张包视图；一次装包里 `chromium` 与它的 `so:` 依赖来自不同快照时，就可能拿到彼此不匹配的组合，失败只在同步窗口期出现，最难复现。
- 行数就是索引请求数；收敛到一台主机两行后，起步阶段的请求、重试等待与日志噪声一起减少。
- 代价是失去跨站兜底：腾讯云不可达时 CNB 构建直接失败。这是有意取舍——用「单站可检测的失败」换「不再有跨站拼包与慢索引」。
- GitHub 侧是同一逻辑的另一面：境外 runner 直连官方源最快，官方源就是那一侧的唯一来源；配置国内镜像只会增加绕路与慢请求。

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
