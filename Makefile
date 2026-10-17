PREFIX ?= $(HOME)/.local
SPEEXDSP := $(shell brew --prefix speexdsp)
AUDIOLAB := tests/build/audiolab
SHARED_SOURCES := $(shell find Sources/Shared -name '*.swift')
TOTALRECALL_SOURCES := $(shell find Sources/TotalRecall -name '*.swift') $(SHARED_SOURCES)
TRANSCRIBE_SOURCES := $(shell find Sources/Transcribe -name '*.swift') $(SHARED_SOURCES)

all: totalrecall transcribe

totalrecall: $(TOTALRECALL_SOURCES) Sources/TotalRecall/bridging.h Sources/TotalRecall/Info.plist
	swiftc -O -wmo -o $@ $(TOTALRECALL_SOURCES) \
		-import-objc-header Sources/TotalRecall/bridging.h \
		-Xcc -I$(SPEEXDSP)/include -L$(SPEEXDSP)/lib -lspeexdsp \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/TotalRecall/Info.plist

# Needs macOS 26 or later (on-device SpeechAnalyzer).
transcribe: $(TRANSCRIBE_SOURCES) Sources/Transcribe/Info.plist
	swiftc -O -wmo -o $@ $(TRANSCRIBE_SOURCES) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Transcribe/Info.plist

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

install: totalrecall transcribe
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/totalrecall $(PREFIX)/bin/totalrecall
	ln -sf $(CURDIR)/transcribe $(PREFIX)/bin/transcribe

clean:
	rm -f totalrecall transcribe $(AUDIOLAB)

.PHONY: all test format lint install clean
