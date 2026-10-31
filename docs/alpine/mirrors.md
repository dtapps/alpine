# APK 源与网络策略

> 两个平台的源策略有意不同：CNB 构建在国内，把基座自带源的主机名替换为腾讯云；GitHub runner 在境外，直连官方 `dl-cdn.alpinelinux.org` 最快，因此不做任何换源。两边都保留基座自带的 `main` + `community` 两行，索引与包的签名仍由 Alpine 官方公钥校验。

## 为什么 CNB 换源、GitHub 不换

- CNB 构建在国内跑，官方源 `dl-cdn.alpinelinux.org` 在国内解析与下载都不稳定。`apk add` 卡在这里，表现为流水线超时，失败点却不在代码上，排查成本高。
- GitHub runner 在境外，与官方源之间的路径通常最短；再指向国内镜像反而可能绕远、更慢。所以 `.github/docker/Dockerfile.alpine` 里没有换源步骤，apk 直接用官方镜像自带的 `repositories`。
- 换源只改 `/etc/apk/repositories` 这一个文本文件，不改变包的来源身份：包仍由 Alpine 官方构建并签名，镜像站只承担分发。
- 收益是构建速度与稳定性，代价是信任面变大（仅 CNB 侧）——这件事在 [SECURITY](../../SECURITY.md) 里被列为已知取舍，最后一节展开。

## 两个平台的源配置

| 平台   | Dockerfile                         | 实际源                                  | 行数 |
|--------|------------------------------------|-----------------------------------------|------|
| CNB    | `.cnb/docker/Dockerfile.alpine`    | 腾讯云 `main` + `community`             | 2    |
| GitHub | `.github/docker/Dockerfile.alpine` | 官方 `main` + `community`（基座默认值） | 2    |

GitHub 侧没有任何写源命令：官方 `alpine` 镜像自带的 `/etc/apk/repositories` 已经包含 `main` 与 `community`，构建日志里的下载地址应始终是 `dl-cdn.alpinelinux.org`。

## 为什么用 sed 替换主机，而不是手写源列表

CNB 侧只做一次主机名替换：

```dockerfile
sed -i 's@dl-cdn.alpinelinux.org@mirrors.cloud.tencent.com@g' /etc/apk/repositories
```

- 基座的 `repositories` 是上游维护的，包含 `main` 与 `community` 两行，路径里的 `vX.Y` 已经写好。只换主机名，就不用在本仓库里重复维护版本路径与仓库列表。
- 上游哪天增删仓库（例如调整 community 的路径），镜像会自动跟随，不需要改 Dockerfile。
- 主机名匹配不上时 `sed` 不生效，`apk` 仍走官方源，构建不会失败——只是国内构建变慢。这比「匹配不上就写坏文件」安全。
- 不要用 `printf` 手写源列表：那等于把上游的仓库结构抄一份到本仓库，每次上游调整都要人工同步，还容易漏掉 `community` 或写错 `vX.Y`。

## 两个平台的源与顺序

CNB 侧只有一台源主机，两行都指向腾讯云：

| 顺序 | 源     | URL 前缀                            | 仓库                | 角色             |
|------|--------|-------------------------------------|---------------------|------------------|
| 1    | 腾讯云 | `https://mirrors.cloud.tencent.com` | `main`、`community` | 国内构建的唯一源 |

容器里看实际生成的内容：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest cat /etc/apk/repositories
```

```text
https://mirrors.cloud.tencent.com/alpine/v3.25/main
https://mirrors.cloud.tencent.com/alpine/v3.25/community
```

GitHub 侧是同样的两行，主机为 `dl-cdn.alpinelinux.org`。

`main` 与 `community` 都要留：`apk add` 只认包名、不指定仓库，少写哪个仓库就少一份索引，缺包时表现为「包不存在」而不是「源有问题」。本镜像预装的包虽然都在 `main`，但基座是给下游用的调试基座，保留 `community` 让下游可以直接装社区包。

## apk 的仓库尝试语义

- apk 没有优先级字段，`/etc/apk/repositories` 的**行序就是回退序**；每一行是一个独立仓库，`main` 与 `community` 各算一份索引。
- 每次 `apk add`，apk 为每个仓库取一份 `APKINDEX`，把多份索引合并成一张包视图。
- 单个源不可达只会打印 `WARNING` 并继续，用其余源照常解析；只有当所有源都取不到索引，或者所有源都没有目标包时，命令才失败。
- 两个平台都只有一台源主机（CNB 是腾讯云，GitHub 是官方），**没有跨站兜底**：主机不可达时构建直接失败，而不是悄悄换站。`main` 与 `community` 两行只解决「仓库缺行」，不解决「站点故障」。
- 同一个包在多个源里都有、版本相同时，先列出的源胜出；版本不同时取版本更高的那一份。所以「换源」不会让包悄悄降级。

## 验证某个源现在可用

索引 URL 形如 `https://<mirror>/alpine/v3.25/<branch>/<arch>/APKINDEX.tar.gz`，`<branch>` 是 `main` 或 `community`，`<arch>` 是 `x86_64` 或 `aarch64`。用镜像内的版本号替换示例里的 `3.25`：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest cat /etc/alpine-release
```

```bash
VER=3.25
for host in mirrors.cloud.tencent.com dl-cdn.alpinelinux.org; do
  for branch in main community; do
    printf '%-28s %-10s ' "$host" "$branch"
    curl -sSI -o /dev/null -w '%{http_code} %{time_total}s\n' \
      "https://${host}/alpine/v${VER}/${branch}/x86_64/APKINDEX.tar.gz"
  done
done
```

上面一台主机对应 CNB 的实际源，下面一台对应 GitHub 的实际源。`200` 表示索引可取，耗时那一列可以直接看出线路慢不慢；`403` / `404` 多为路径或版本号写错；连不上或超时则是网络问题。

容器内验证走的正是镜像里的源配置，比在宿主机上测更贴近真实构建：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c 'apk update'
```

输出里每个 `fetch` 对应一个源，出现 `WARNING` 的那几行就是当前不可用的源。注意镜像本身构建时并不跑 `apk update`（`apk add --no-cache` 自带索引拉取），这条命令只是诊断手段，它写下的索引落在容器内、容器退出即消失。

## 源挂掉时怎么改

1. 先用上一节的 `curl` 循环区分「源挂了」和「整条网络不通」。
2. CNB：只改 `.cnb/docker/Dockerfile.alpine` 里 `sed` 的替换目标主机名。GitHub 侧没有源配置可改，先确认 runner 到官方源的网络与上游状态，不要为此临时加国内镜像。
3. 不要在 `printf` 里手写整份源列表：那会把上游的仓库结构复制进本仓库，增删仓库时容易漏改。
4. 本地验证：`docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .`（默认跟随上游 `latest`；想固定基座再加 `--build-arg ALPINE_VERSION=3.25.1`），再在容器里跑一次 `apk update` 确认没有新的 `WARNING`。
5. 跑 `make format-docker` 让 `dockerfmt` 统一格式，提交时在 PR 里写明「哪个源、什么症状、什么时候观测到」。
6. 腾讯云长期不可用时再讨论补源：增删源属于对外行为变更，[CONTRIBUTING](../../CONTRIBUTING.md) 要求说明理由；临时堆多个站只会把同步窗口期的拼包风险带回来。

## 供应链信任面

- 信任面：CNB 侧 = 上游 Alpine + 腾讯云；GitHub 侧 = 上游 Alpine + 官方源（同一主体）。已在 [SECURITY](../../SECURITY.md) 的「已知取舍」里写明。
- 镜像站能做的：返回索引与包、拒绝服务、返回旧快照（构建拿到的是过期版本的包）。
- 镜像站无法悄悄塞进一个恶意包：apk 用 `/etc/apk/keys/` 里的 Alpine 官方公钥校验仓库索引与每个 `.apk` 包的签名，签名不符直接拒绝安装。
- 因此换源主要影响**可用性**与**时效性**，不影响包内容的真实性；剩下的风险是构建指纹（源站能看到你请求了哪些包与版本）和「被喂旧索引导致镜像停留在旧包上」。
- 后一条正是「每天 00:05 重建一次」的意义之一：基座默认跟随 `latest`，定时任务每天重新解析并装包，上游的新补丁、新小版本当天就能进镜像；即便腾讯云短暂返回旧索引，被拖住的也只是一天，详见 [维护手册](maintenance.md)。
- 不要在源 URL 里放任何凭证：本仓库只引用公开镜像站与官方源，不存在私有源与鉴权参数。

## 为什么不再堆多个源

- 多个镜像站的同步进度并不一致，apk 会把所有仓库合并成一张包视图，同一个包在不同站是不同快照时取版本更高的那一份；一次 `apk add` 里 `main` 来自 A 站、依赖来自 B 站，就可能拿到彼此不匹配的组合。这种失败只在同步窗口期出现，最难复现。
- 行数就是索引请求数。`main` 与 `community` 各算一个独立仓库，每个仓库都要拉一份 `APKINDEX`；主机只留一台，脚本与日志都好核对。
- 代价是失去跨站兜底：腾讯云不可达时，CNB 构建会直接失败。这是有意的取舍——用「单站可检测的失败」换「不再有跨站拼包与慢索引」。
- GitHub 侧不换源同样是取舍：境外 runner 直连官方源通常最快，配置国内镜像可能反而更慢，所以官方源就是那一侧的「唯一源」。

## 相关文档

- [文档索引](index.md)
- [Dockerfile 解析](dockerfile.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
