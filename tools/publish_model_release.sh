#!/bin/bash
# 发布整句 n-gram 模型到 GitHub Release。
#
# 模型不入版本库：GitHub 禁止向公开 fork 上传新 LFS 对象，且免费 LFS 配额
# （1GB 存储）装不下历次重训版本；Release 附件单文件上限 2GB、无配额限制。
# 每次用 tools/ngram/fast_train 重训后跑一遍本脚本，产出带日期 tag 的 Release。
#
# 用法：
#   tools/publish_model_release.sh
# 变量一律用 ${VAR} 花括号展开：macOS 自带 bash 3.2 在 UTF-8 下解析
# 紧跟全角标点的 $VAR 时会把多字节首字节并入变量名（SIZE: unbound variable）
set -euo pipefail

BIN="Fire/Resources/sentence-ngram-mobile.bin"
TAG="ngram-model-$(date +%Y%m%d-%H%M)"
# 本仓库是 qwertyyb/Fire 的 fork：gh 在多 remote 下默认解析到上游，
# 必须显式指定 --repo，否则 Release 会（试图）发到 qwertyyb/Fire
REPO="hertz-hwang/Fire"

if [ ! -f "${BIN}" ]; then
    echo "未找到模型文件：${BIN}（可从 Release 下载历史版本放回该路径）" >&2
    exit 1
fi

SIZE=$(du -h "${BIN}" | cut -f1 | tr -d ' ')
SHA=$(shasum -a 256 "${BIN}" | cut -d' ' -f1)

gh release create "${TAG}" "${BIN}" --repo "${REPO}" \
    --title "整句 N-gram 模型 ${TAG}" \
    --notes "sentence-ngram-mobile.bin（${SIZE}）

- sha256: \`${SHA}\`
- 训练工具：tools/ngram/fast_train.cpp（语料目录 tools/ngram/corpus/）
- 安装：下载后放回 Fire/Resources/sentence-ngram-mobile.bin"

echo "已发布 Release ${TAG}（${SIZE}，sha256 ${SHA}）"
