PREFIX ?= $(HOME)/.local
VERSION := $(shell cat VERSION)
ARCH := $(shell uname -m)
BUILD := build
AUDIOLAB := tests/build/audiolab
COVERAGE_BINARY := tests/build/coverage/totalrecall
# Lowest line coverage, in percent, that make coverage accepts from the integration tests.
COVERAGE_MIN ?= 0
RELEASE := $(BUILD)/totalrecall-$(VERSION)-macos-$(ARCH).tar.gz
# Oldest macOS the tools run on; older versions refuse to launch them.
MACOS_MIN := 26.0
# speexdsp is built from source for MACOS_MIN and linked statically, so the binary runs without Homebrew.
SPEEXDSP_VERSION := 1.2.1
SPEEXDSP_SHA256 := 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d
SPEEXDSP_URL := https://ftp.osuosl.org/pub/xiph/releases/speex/speexdsp-$(SPEEXDSP_VERSION).tar.gz
# One folder per version and macOS minimum, so changing either builds it afresh.
SPEEXDSP := $(CURDIR)/$(BUILD)/speexdsp/$(SPEEXDSP_VERSION)-macos$(MACOS_MIN)
SHARED_SOURCES := $(shell find Sources/Shared -name '*.swift')
TOTALRECALL_SOURCES := $(shell find Sources/TotalRecall -name '*.swift') $(SHARED_SOURCES)
TRANSCRIBE_SOURCES := $(shell find Sources/Transcribe -name '*.swift') $(SHARED_SOURCES)
TOTALRECALL_INPUTS := $(TOTALRECALL_SOURCES) Sources/TotalRecall/bridging.h $(BUILD)/TotalRecall/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
TOTALRECALL_FLAGS := -O -wmo -target $(ARCH)-apple-macos$(MACOS_MIN) $(TOTALRECALL_SOURCES) \
	-import-objc-header Sources/TotalRecall/bridging.h \
	-Xcc -I$(SPEEXDSP)/include $(SPEEXDSP)/lib/libspeexdsp.a \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(BUILD)/TotalRecall/Info.plist

all: totalrecall transcribe

totalrecall: $(TOTALRECALL_INPUTS)
	swiftc $(TOTALRECALL_FLAGS) -o $@

# The same build, instrumented to count which lines run, for make coverage.
$(COVERAGE_BINARY): $(TOTALRECALL_INPUTS)
	mkdir -p $(dir $@)
	swiftc $(TOTALRECALL_FLAGS) -profile-generate -profile-coverage-mapping -o $@

transcribe: $(TRANSCRIBE_SOURCES) $(BUILD)/Transcribe/Info.plist
	swiftc -O -wmo -target $(ARCH)-apple-macos$(MACOS_MIN) -o $@ $(TRANSCRIBE_SOURCES) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(BUILD)/Transcribe/Info.plist

$(SPEEXDSP)/lib/libspeexdsp.a:
	mkdir -p $(SPEEXDSP)/src
	curl -fsSL -o $(SPEEXDSP)/src.tar.gz $(SPEEXDSP_URL)
	echo "$(SPEEXDSP_SHA256)  $(SPEEXDSP)/src.tar.gz" | shasum -a 256 -c -
	tar -xzf $(SPEEXDSP)/src.tar.gz -C $(SPEEXDSP)/src --strip-components 1
	cd $(SPEEXDSP)/src && ./configure --quiet --disable-shared --enable-static \
		--prefix=$(SPEEXDSP) CFLAGS="-O2 -mmacosx-version-min=$(MACOS_MIN)" && $(MAKE) --quiet install

# Each tool's Info.plist, with the version from VERSION.
$(BUILD)/%/Info.plist: Sources/%/Info.plist VERSION
	mkdir -p $(dir $@)
	cp $< $@
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $@

# Both tools and the README, as published by .github/workflows/release.yml.
release: $(RELEASE)

$(RELEASE): totalrecall transcribe README.md
	tar -czf $@ totalrecall transcribe README.md
	cd $(dir $@) && shasum -a 256 $(notdir $@) > $(notdir $@).sha256

$(AUDIOLAB): tests/audiolab/main.swift
	mkdir -p $(dir $@)
	swiftc -O -o $@ tests/audiolab/main.swift

# Integration tests; run a subset with: make test TESTS="records_mic_and_system_audio switches_to_slow_starting_input"
test: totalrecall $(AUDIOLAB)
	tests/run.sh $(TESTS)

# The integration tests against the instrumented build; fails below COVERAGE_MIN. Takes TESTS like make test.
coverage: $(COVERAGE_BINARY) $(AUDIOLAB)
	COVERAGE_MIN=$(COVERAGE_MIN) tests/coverage.sh $(CURDIR)/$(COVERAGE_BINARY) $(TESTS)

format:
	swift format --recursive --in-place Sources

lint:
	swift format lint --recursive --strict Sources

install: totalrecall transcribe
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/totalrecall $(PREFIX)/bin/totalrecall
	ln -sf $(CURDIR)/transcribe $(PREFIX)/bin/transcribe

clean:
	rm -f totalrecall transcribe $(AUDIOLAB) $(COVERAGE_BINARY)
	rm -rf $(BUILD)

.PHONY: all release test coverage format lint install clean
