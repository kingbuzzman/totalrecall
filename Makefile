PREFIX ?= $(HOME)/.local
SPEEXDSP := $(shell brew --prefix speexdsp)

totalrecall: Sources/main.swift Sources/bridging.h Info.plist
	swiftc -O -o $@ Sources/main.swift \
		-import-objc-header Sources/bridging.h \
		-Xcc -I$(SPEEXDSP)/include -L$(SPEEXDSP)/lib -lspeexdsp \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

install: totalrecall
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/totalrecall $(PREFIX)/bin/totalrecall

clean:
	rm -f totalrecall

.PHONY: install clean
