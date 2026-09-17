# OpenSSH 构建工具 —— 便捷入口(完整选项见 ./build.sh --help)
DEFAULT_VERSION ?= 10.5p1
VERSION ?= $(DEFAULT_VERSION)

.PHONY: help deb rpm fetch list-versions clean distclean

help:
	@echo "可用目标:"
	@echo "  make deb                  构建 deb + 彩排验证(默认版本 $(DEFAULT_VERSION))"
	@echo "  make rpm                  构建 rpm + 彩排验证"
	@echo "  make fetch                预下载物料到 downloads/(之后可离线构建)"
	@echo "  make list-versions        列出可用版本"
	@echo "  make VERSION=10.5p1 deb   指定版本构建"
	@echo "  make clean                清理构建缓存 work/"
	@echo "  make distclean            另清理产物 out/(不含 out/archive 历史归档)"

deb:
	./build.sh deb --version $(VERSION)

rpm:
	./build.sh rpm --version $(VERSION)

fetch:
	./build.sh fetch --version $(VERSION)

list-versions:
	./build.sh --list-versions

clean:
	rm -rf work/

distclean: clean
	rm -rf out/deb out/rpm
