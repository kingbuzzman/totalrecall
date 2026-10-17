PREFIX ?= $(HOME)/.local
SPEEXDSP := $(shell brew --prefix speexdsp)
AUDIOLAB := tests/build/audiolab
SOURCES := $(shell find Sources -name '*.swift')

totalrecall: $(SOURCES) Sources/bridging.h Info.plist
	swiftc -O -wmo -o $@ $(SOURCES) \
		-import-objc-header Sources/bridging.h \
		-Xcc -I$(SPEEXDSP)/include -L$(SPEEXDSP)/lib -lspeexdsp \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

$(AUDIOLAB): tests/audiolab/main.swift
	mkdir -p $(dir $@)
	swiftc -O -o $@ tests/audiolab/main.swift

# Integration tests; run a subset with: make test TESTS="records_mic_and_system_audio switches_to_slow_starting_input"
test: totalrecall $(AUDIOLAB)
	tests/run.sh $(TESTS)

format:
	swift format --recursive --in-place Sources

lint:
	swift format lint --recursive --strict Sources

install: totalrecall
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/totalrecall $(PREFIX)/bin/totalrecall

clean:
	rm -f totalrecall $(AUDIOLAB)

.PHONY: test format lint install clean
