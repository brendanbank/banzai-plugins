# Makefile — Build server convenience targets for OPNsense VM images
#
# Run on the build server after checking out banzai-plugins.
# Wraps make -C $(TOOLSDIR) with the right variables.
#
# Configuration is read from /etc/opnsense-build-server.conf if it
# exists, or override on the command line:
#
#   make build SERIES=26.7 DEVICE=BANZAI
#   make status
#

CONF ?= /etc/opnsense-build-server.conf
-include $(CONF)

TOOLSDIR ?= /usr/tools
SERIES ?= 26.1
DEVICE ?= BANZAI
VM_FORMAT ?= qcow2

_MAKE = sudo make -C $(TOOLSDIR) DEVICE=$(DEVICE) BATCH=yes

.PHONY: help build base kernel ports core plugins vm status update clean

help:
	@echo "Usage: make <target> [SERIES=26.1] [DEVICE=BANZAI]"
	@echo ""
	@echo "Build targets:"
	@echo "  build       Full VM image build (base+kernel+ports+core+plugins+vm)"
	@echo "  base        Build FreeBSD base system"
	@echo "  kernel      Build FreeBSD kernel"
	@echo "  ports       Build ports/packages"
	@echo "  core        Build OPNsense core"
	@echo "  plugins     Build OPNsense plugins"
	@echo "  vm          Build VM image ($(VM_FORMAT))"
	@echo ""
	@echo "Other targets:"
	@echo "  status      Show build server state"
	@echo "  update      Pull latest code for all repos"
	@echo "  clean       Clean build artifacts"
	@echo ""
	@echo "Configuration: $(CONF)"
	@echo "  TOOLSDIR=$(TOOLSDIR)  SERIES=$(SERIES)  DEVICE=$(DEVICE)"

build:
	$(_MAKE) vm-$(VM_FORMAT)

base kernel ports core plugins:
	$(_MAKE) $@

vm:
	$(_MAKE) vm-$(VM_FORMAT)

status:
	@echo "==> Build server status"
	@echo "    TOOLSDIR=$(TOOLSDIR)  SERIES=$(SERIES)  DEVICE=$(DEVICE)"
	@echo ""
	@for dir in tools src core plugins ports; do \
		path="/usr/$${dir}"; \
		if [ -d "$${path}/.git" ]; then \
			branch=$$(sudo git -C "$${path}" rev-parse --abbrev-ref HEAD 2>/dev/null); \
			commit=$$(sudo git -C "$${path}" log --oneline -1 2>/dev/null); \
			echo "    $${dir}: $${branch} — $${commit}"; \
		else \
			echo "    $${dir}: NOT CLONED"; \
		fi; \
	done
	@echo ""
	@ls -lh /usr/local/opnsense/build/$(SERIES)/amd64/images/*.$(VM_FORMAT) 2>/dev/null \
		|| echo "    No build artifacts"
	@echo ""
	@df -h / | tail -1 | awk '{print "    Disk: " $$4 " available of " $$2}'
	@sysctl -n hw.physmem | awk '{printf "    RAM: %dGB\n", $$1/1073741824}'

update:
	$(_MAKE) update

clean:
	$(_MAKE) clean
