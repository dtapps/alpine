

# 格式化
format: format-yaml format-markdown format-shell format-docker

# 格式化 YAML 文件
.PHONY: format-yaml
format-yaml:
	@echo "[Format] 格式化配置文件 (YAML)…"
	@yamlfmt -conf .yamlfmt \
		".cnb" \
		".cnb.yml" || { echo "❌ yamlfmt 格式化失败"; exit 1; }
	@echo "[Format] YAML 格式化完成（yamlfmt）。"

# 格式化 Markdown 文件
.PHONY: format-markdown
format-markdown:
	@echo "[Format] 格式化文档 (Markdown)…"
	@for f in $(shell find . -type f -name '*.md' \
		-not -path './.git/*' \
		-not -path './.vscode/*' \
		-not -path './.idea/*' \
		-not -path './.codebuddy/*' \
		-not -path './.trae/*' \
		-not -path './.mimocode/*'); do \
		[ -f "$$f" ] || continue; \
		markdownfmt -w "$$f" || { echo "❌ markdownfmt 格式化失败: $$f"; exit 1; }; \
	done
	@echo "[Format] Markdown 格式化完成（markdownfmt）。"

# 格式化 Shell 脚本
.PHONY: format-shell
format-shell:
	@echo "[Format] 格式化脚本 (Shell)…"
	@shfmt -w -i 2 -ci -bn -s -ln bash .cnb/scripts/ || { echo "❌ shfmt 格式化失败"; exit 1; }
	@echo "[Format] Shell 格式化完成（shfmt）。"

# 格式化 Dockerfile 文件
.PHONY: format-docker
format-docker:
	@echo "[Format] 格式化 Dockerfile..."
	@find .cnb -type f -name "Dockerfile*" -exec dockerfmt -w {} + || { echo "❌ dockerfmt 格式化失败"; exit 1; }
	@echo "[Format] Dockerfile 格式化完成（dockerfmt）。"
