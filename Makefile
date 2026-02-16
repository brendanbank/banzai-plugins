LOCALBASE?=	/usr/local
PAGER?=		less

.sinclude "Mk/defaults.mk"

_PLUGIN_DIRS!=	ls -1d */*/ 2>/dev/null | \
		while read _DIR; do \
			if [ -f "$${_DIR}Makefile" ]; then \
				echo "$${_DIR}"; \
			fi; \
		done

.for _DIR in ${_PLUGIN_DIRS}
_PLUGIN_${_DIR:S/\///g}=	${_DIR}
.endfor

list:
.for _DIR in ${_PLUGIN_DIRS}
	@echo ${_DIR:S/\/$//}
.endfor

lint:
.for _DIR in ${_PLUGIN_DIRS}
	@echo ">>> Linting ${_DIR:S/\/$//}"
	@cd ${.CURDIR}/${_DIR} && make lint
.endfor

style:
.for _DIR in ${_PLUGIN_DIRS}
	@echo ">>> Checking style ${_DIR:S/\/$//}"
	@cd ${.CURDIR}/${_DIR} && make style
.endfor

clean:
.for _DIR in ${_PLUGIN_DIRS}
	@cd ${.CURDIR}/${_DIR} && make clean
.endfor

setup:
	@git submodule update --init
	@for dir in Mk Keywords Templates Scripts; do \
		ln -sfn opnsense-plugins/$$dir $$dir; \
	done
	@echo "Symlinks created. Build infrastructure ready."

.PHONY: list lint style clean setup
