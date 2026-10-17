PREFIX ?= $(HOME)/.local
VERSION := $(shell cat VERSION)
ARCH := $(shell uname -m)
BUILD := build
RELEASE := $(BUILD)/totalrecall-$(VERSION)-macos-$(ARCH).tar.gz
# Oldest macOS the tools run on, as in Package.swift; older versions refuse to launch them.
MACOS_MIN := 26.0
# speexdsp is built from source for MACOS_MIN and linked statically, so the binary runs without Homebrew.
SPEEXDSP_VERSION := 1.2.1
SPEEXDSP_SHA256 := 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d
SPEEXDSP_URL := https://ftp.osuosl.org/pub/xiph/releases/speex/speexdsp-$(SPEEXDSP_VERSION).tar.gz
# One folder per version and macOS minimum, so changing either builds it afresh.
SPEEXDSP := $(CURDIR)/$(BUILD)/speexdsp/$(SPEEXDSP_VERSION)-macos$(MACOS_MIN)
# Where Package.swift's CSpeexDSP finds it.
export PKG_CONFIG_PATH := $(SPEEXDSP)/lib/pkgconfig
SOURCES := Package.swift $(shell find Sources -type f)
INFO_PLIST = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(CURDIR)/$(BUILD)/$(1)/Info.plist
# One build of the tools and the tests, instrumented for coverage. The tests need -enable-testing, and the tools must
# come from the same build for their coverage to add up with the tests'. Both tools get totalrecall's Info.plist, which
# only matters for their version.
COVERAGE_FLAGS := -c release --build-path .build/coverage -Xswiftc -enable-testing \
	-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping $(call INFO_PLIST,TotalRecall)
# Lowest line coverage, in percent, that make coverage accepts.
COVERAGE_MIN ?= 75

all: totalrecall transcribe

totalrecall: $(SOURCES) $(BUILD)/TotalRecall/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
	swift build -c release --product $@ $(call INFO_PLIST,TotalRecall)
	cp "$$(swift build -c release --show-bin-path)/$@" $@

transcribe: $(SOURCES) $(BUILD)/Transcribe/Info.plist
	swift build -c release --product $@ $(call INFO_PLIST,Transcribe)
	cp "$$(swift build -c release --show-bin-path)/$@" $@

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

# Unit and end-to-end tests, the latter against the release builds; run a subset with: make test TESTS=RecorderTests
# Tests that need the BlackHole test devices are skipped without them, except on CI.
test: totalrecall transcribe $(SPEEXDSP)/lib/libspeexdsp.a
	swift test $(if $(TESTS),--filter '$(TESTS)')

# The tests again, on the build instrumented for coverage; fails below COVERAGE_MIN. Takes TESTS like make test.
coverage: coverage-build
	COVERAGE_MIN=$(COVERAGE_MIN) scripts/coverage.sh "$$($(MAKE) -s coverage-bin)" \
		swift test --skip-build $(COVERAGE_FLAGS) $(if $(TESTS),--filter '$(TESTS)')

coverage-build: $(SOURCES) $(BUILD)/TotalRecall/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
	swift build --build-tests $(COVERAGE_FLAGS)

# Where coverage-build puts the tools, which CI grants the audio permissions to.
coverage-bin:
	@swift build $(COVERAGE_FLAGS) --show-bin-path

format:
	swift format --recursive --in-place Package.swift Sources Tests

lint:
	swift format lint --recursive --strict Package.swift Sources Tests

install: totalrecall transcribe
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/totalrecall $(PREFIX)/bin/totalrecall
	ln -sf $(CURDIR)/transcribe $(PREFIX)/bin/transcribe

clean:
	rm -f totalrecall transcribe
	rm -rf $(BUILD) .build

.PHONY: all release test coverage coverage-build coverage-bin format lint install clean
