# 格式化与本地工具链

> `make format` 把 YAML、Markdown、Shell、Dockerfile 四类文件收敛到同一套规则；规则本身写在 `Makefile` 与 `.yamlfmt` 里，这里逐项解释每个参数为什么这么定。

## 一条命令与四个子目标

| 目标                   | 工具         | 作用范围                                                                               | 关键参数                                                               |
|------------------------|--------------|----------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| `make format`          | 依次调用四个 | 全部                                                                                   | 依赖 `format-yaml`、`format-markdown`、`format-shell`、`format-docker` |
| `make format-yaml`     | yamlfmt      | `.cnb` 整个目录与 `.cnb.yml`                                                           | `-conf .yamlfmt`                                                       |
| `make format-markdown` | markdownfmt  | 仓库内所有 `*.md`，排除 `.git`、`.vscode`、`.idea`、`.codebuddy`、`.trae`、`.mimocode` | `-w`                                                                   |
| `make format-shell`    | shfmt        | `.cnb/scripts/`                                                                        | `-w -i 2 -ci -bn -s -ln bash`                                          |
| `make format-docker`   | dockerfmt    | `.cnb` 下所有 `Dockerfile*`                                                            | `-w`                                                                   |

`format` 只是四个目标的依赖集合，`make` 按依赖顺序串行执行并在第一个失败处停下，所以一次只会看到一个失败点：

```bash
make format          # 全部
make format-yaml     # 只处理 YAML
make format-shell    # 只处理 shell 脚本
```

范围之所以这么定：仓库里需要格式化的只有 `.cnb/` 下的流水线与脚本、根目录的 `.cnb.yml`，以及散落在根目录和 `docs/` 的 Markdown。Markdown 用 `find` 全仓扫描并排除编辑器目录，是为了新加的文档自动纳入，不用回来改 `Makefile`。

## 安装

```bash
brew install shfmt yamlfmt markdownfmt dockerfmt
# go install 也可以，模块路径与仓库里用到的一致
go install mvdan.cc/sh/v3/cmd/shfmt@latest
go install github.com/google/yamlfmt/cmd/yamlfmt@latest
```

```bash
command -v yamlfmt markdownfmt shfmt dockerfmt
yamlfmt --version
```

四个都在 PATH 里才跑 `make format`。`markdownfmt` 与 `dockerfmt` 没有 `--version` 参数，存在性用 `command -v` 判断；`yamlfmt`、`shfmt` 支持 `--version`，出现 `command not found` 就是没装。

## `.yamlfmt` 逐项

```yaml
formatter:
  type: basic
  indent: 2
  max_line_length: 120
  force_quote_style: single
  retain_line_breaks: true
  retain_line_breaks_single: true
```

| 配置项                      | 值     | 效果                                          |
|-----------------------------|--------|-----------------------------------------------|
| `formatter.type`            | basic  | 保留注释与键顺序的基本格式化，不做 AST 级重排 |
| `indent`                    | 2      | 两空格缩进                                    |
| `max_line_length`           | 120    | 超过 120 字符的标量在此处折行，续行带缩进     |
| `force_quote_style`         | single | 字符串统一单引号，原有的双引号会被改写        |
| `retain_line_breaks`        | true   | 保留原文件的空行分组，多个连续空行收敛为一个  |
| `retain_line_breaks_single` | true   | 单个空行也原样保留                            |

这套规则解释了仓库里为什么到处是单引号：`'**':`、`'crontab: 5 0 * * *':` 这类键在 YAML 里本来就离不开引号（`**` 以 `*` 开头会被当成别名，`crontab: 5 0 * * *` 含「冒号加空格」），规则只决定用哪一种引号。统一之后 diff 里不会出现「引号风格抖动」。`retain_line_breaks*` 两条一起开，是为了让注释分组保持原样——流水线配置里注释承担了说明职责，被合并成一坨就失去可读性。

## shfmt 参数逐项

| 参数       | 含义                                                    |
|------------|---------------------------------------------------------|
| `-w`       | 就地写回文件，不加则只把结果打到 stdout                 |
| `-i 2`     | 缩进 2 个空格                                           |
| `-ci`      | `switch` / `case` 分支相对 `switch` 缩进                |
| `-bn`      | 换行时把二元运算符放到行首（binary ops at line break）  |
| `-s`       | 简化可简化的写法，例如去掉多余的 `${}` 与 `$(( ))` 括号 |
| `-ln bash` | 按 bash 方言解析                                        |

`-ln bash` 看起来与脚本的 shebang（`#!/bin/sh`）不一致，这是有意的：脚本里用了 `local`、`$(...)`、`${DIGEST#sha256:}` 这些写法，其中 `local` 不属于 POSIX，`posix` 方言会因此报错或改写，反而把代码打乱。代价是风格一致性以 bash 为准，所以新增 shell 脚本也不要依赖纯 POSIX 不支持的特性。

## markdownfmt 行为

`make format-markdown` 跑的是 `markdownfmt -w`，逐文件写回。它的实际行为（对照输出即可验证）：

- 表格按每列最长单元格重算宽度，分隔行跟着变长；这是最常见的 diff 来源。
- 连续多个空行收敛为一个，标题、段落、列表、代码块之间补空行。
- Setext 标题（`===` / `---` 下划线）转成 ATX（`#`）。
- 四空格缩进的代码块转成围栏代码块，围栏内的内容一个字都不动。
- 列表符号保持原样（`*` 不会改成 `-`），有序列表的 `1)` 写法也保留。
- 长段落不折行；行尾两个空格构成的硬换行会保留。

所以「我以为只是加了一行」却出现整表重排，是因为列宽被重算；把表格改动单独成一次提交，评审时才看得清内容变化。

## dockerfmt 作用范围

范围是 `find .cnb -type f -name "Dockerfile*"`，当前只命中 `.cnb/docker/Dockerfile.alpine`。它处理的是 Dockerfile 的排布（指令与参数之间的空格、续行对齐、指令名大小写），不改指令顺序，也不改 `RUN` 里的命令内容——体积相关的清理步骤顺序仍然是人的责任。

根目录并不在范围内，因此不要把 Dockerfile 挪到根目录：`-f .cnb/docker/Dockerfile.alpine` 是唯一入口，挪走等于同时跳出 `format-docker` 的覆盖。

## CI 不校验格式

流水线里没有 format check 任务，即 `.cnb/workflows/` 下没有任何「跑格式化并检查 diff」的步骤。这是一处明确取舍：

- 格式不是这个仓库的产物质量指标。镜像能不能构建、漏洞有没有修，才是流水线该拦的东西；多一个必跑任务，每个 PR 都要为它付出一次排队时间。
- 规则与参数口径都写在仓库里（`.yamlfmt` 进版本库、shfmt 参数写在 `Makefile`），本地跑出的结果与别人一致，不需要靠 CI 兜底；实际安装的工具版本不锁定，升级工具后以 `make format` 的结果为准。
- 代价是执行靠自觉。漏跑就会把格式 diff 混进功能 diff，成本转移给 reviewer。

团队约定落到操作上只有三条：提交前跑 `make format`；PR 描述里不解释格式 diff；reviewer 看到纯格式改动只回一句「跑下 format」，不逐行讨论。完整检查清单在 [CONTRIBUTING](../../CONTRIBUTING.md)。

## 常见格式化 diff 噪音

| 现象                 | 原因                                | 规避方式                                 |
|----------------------|-------------------------------------|------------------------------------------|
| 整张表格每一行都变了 | markdownfmt 按最长单元格重算列宽    | 表格改动单独提交，不要与正文混在一起     |
| 到处多出空行         | 标题、列表、代码块前后被补空行      | 手写时就留空行，与格式化结果一致         |
| 双引号全变单引号     | `force_quote_style: single`         | YAML 里直接写单引号                      |
| 一行长配置被折成两行 | `max_line_length: 120`              | 把长说明写成行尾注释之外的行，或主动断开 |
| 多个空行只剩一个     | `retain_line_breaks` 只保留一组空行 | 只用单个空行分组                         |

## 编辑器保存时格式化

仓库不提供 `.editorconfig` 或编辑器配置，所以「保存即格式化」需要自己挂到这四个工具上，且参数必须与 `Makefile` 逐字一致，否则编辑器每次保存都会产出与 `make format` 相反的结果：

```text
yamlfmt      -conf .yamlfmt
markdownfmt  -w
shfmt        -w -i 2 -ci -bn -s -ln bash
dockerfmt    -w
```

最稳的做法是不接钩子，提交前手动跑一次 `make format`；接了钩子就必须对齐缩进宽度（编辑器默认 4 空格缩进会与 `-i 2` 直接打架）和 YAML 规则文件路径。

## 把新文件类型纳入 Makefile

新增一类文件时，按现有四个目标的形状补一个：

1. 目标名用 `format-<类型>`，并加 `.PHONY` 声明。
2. 用 `find` 或显式路径圈定范围，把不该处理的目录排除掉（参考 `format-markdown` 的 `-not -path` 写法）。
3. 命令末尾接 `|| { echo "…失败"; exit 1; }`，与现有目标一致——失败必须让 `make` 停下来，不能静默通过。
4. 把新目标加进 `format:` 的依赖列表，否则 `make format` 不会调用它。
5. 同步 [CONTRIBUTING](../../CONTRIBUTING.md) 的工具清单与上面的工具表。

模板形状（`<...>` 处替换成实际的工具与路径）：

```text
format-<类型>:
	@echo "[Format] …"
	@<tool> -w <路径> || { echo "[Format] <类型> 格式化失败"; exit 1; }
```

改完用 dry-run 确认目标确实被串进依赖链，再执行一次看输出：

```bash
make -n format
```

## 相关文档

- [CONTRIBUTING](../../CONTRIBUTING.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [文档索引](index.md)
