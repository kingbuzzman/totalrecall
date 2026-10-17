PREFIX ?= $(HOME)/.local
VERSION := $(shell cat VERSION)
ARCH := $(shell uname -m)
# Everything a build makes goes in BUILD, so make clean deletes just that: the tools (bin), SwiftPM's builds (swiftpm and
# swiftpm-coverage), speexdsp, the Info.plists, the release tarball, the test results and the coverage report.
BUILD := build
BIN := $(BUILD)/bin
TOOLS := $(BIN)/totalrecall $(BIN)/transcribe
# Every swift command takes it, so SwiftPM builds in BUILD rather than its default .build.
SWIFTPM := --scratch-path $(BUILD)/swiftpm
RELEASE := $(BUILD)/totalrecall-$(VERSION)-macos-$(ARCH).tar.gz
# Oldest macOS the tools run on, as in Package.swift; older versions refuse to launch them.
MACOS_MIN := 26.0
# speexdsp is built from source for MACOS_MIN and linked statically, so the binary runs without Homebrew.
SPEEXDSP_VERSION := 1.2.1
SPEEXDSP_SHA256 := 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d
SPEEXDSP_URL := https://ftp.osuosl.org/pub/xiph/releases/speex/speexdsp-$(SPEEXDSP_VERSION).tar.gz
# One folder per version, macOS minimum and build recipe, so changing any of them builds it afresh. Bump SPEEXDSP_RECIPE
# when changing how it is built, or CI reuses its cached copy.
SPEEXDSP_RECIPE := 2
SPEEXDSP := $(CURDIR)/$(BUILD)/speexdsp/$(SPEEXDSP_VERSION)-macos$(MACOS_MIN)-r$(SPEEXDSP_RECIPE)
SPEEXDSP_CFLAGS := -O2 -mmacosx-version-min=$(MACOS_MIN)
# Where Package.swift's CSpeexDSP finds it.
export PKG_CONFIG_PATH := $(SPEEXDSP)/lib/pkgconfig
SOURCES := Package.swift $(shell find Sources -type f)
INFO_PLIST = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(CURDIR)/$(BUILD)/$(1)/Info.plist
# One build of the tools and the tests, instrumented for coverage. The tests need -enable-testing, and the tools must
# come from the same build for their coverage to add up with the tests'. Both tools get totalrecall's Info.plist, which
# only matters for their version.
COVERAGE_FLAGS := -c release --scratch-path $(BUILD)/swiftpm-coverage -Xswiftc -enable-testing \
	-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping $(call INFO_PLIST,TotalRecall)
# Lowest line coverage, in percent, that make coverage accepts.
COVERAGE_MIN ?= 75
COVERAGE_REPORT := $(BUILD)/coverage
# Every build goes through it: a single warning, from any tool, fails the build.
STRICT := scripts/no-warnings.sh
# Runs the tests under a pseudo-terminal, so their progress is printed as it happens: into a pipe, such as CI's log, it
# is buffered, and a run that hangs shows nothing of the tests since the last flush.
UNBUFFERED := script -q /dev/null

all: $(TOOLS)

# make totalrecall or make transcribe builds just that one.
totalrecall transcribe: %: $(BIN)/%

# Each tool from the release build, copied into BIN.
$(BIN)/totalrecall: $(SOURCES) $(BUILD)/TotalRecall/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
	$(STRICT) swift build $(SWIFTPM) -c release --product totalrecall $(call INFO_PLIST,TotalRecall)
	mkdir -p $(BIN)
	cp "$$(swift build $(SWIFTPM) -c release --show-bin-path)/totalrecall" $@

# transcribe does not use speexdsp, but SwiftPM looks for its pkg-config file while loading the package, and warns when
# it is missing; under make -j, that would race speexdsp's build.
$(BIN)/transcribe: $(SOURCES) $(BUILD)/Transcribe/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
	$(STRICT) swift build $(SWIFTPM) -c release --product transcribe $(call INFO_PLIST,Transcribe)
	mkdir -p $(BIN)
	cp "$$(swift build $(SWIFTPM) -c release --show-bin-path)/transcribe" $@

# Only the library, its headers and its pkg-config file, with warnings as errors: speexdsp's own test programs have
# warnings of their own. lt_cv_apple_cc_single_mod=no skips libtool's check of -single_module, which ld warns is obsolete.
$(SPEEXDSP)/lib/libspeexdsp.a:
	mkdir -p $(SPEEXDSP)/src
	curl -fsSL -o $(SPEEXDSP)/src.tar.gz $(SPEEXDSP_URL)
	echo "$(SPEEXDSP_SHA256)  $(SPEEXDSP)/src.tar.gz" | shasum -a 256 -c -
	tar -xzf $(SPEEXDSP)/src.tar.gz -C $(SPEEXDSP)/src --strip-components 1
	$(STRICT) sh -c 'cd $(SPEEXDSP)/src \
		&& ./configure --quiet --disable-shared --enable-static --prefix=$(SPEEXDSP) \
			CFLAGS="$(SPEEXDSP_CFLAGS)" lt_cv_apple_cc_single_mod=no \
		&& $(MAKE) --quiet -C libspeexdsp CFLAGS="$(SPEEXDSP_CFLAGS) -Werror" install-libLTLIBRARIES \
		&& $(MAKE) --quiet -C include install && $(MAKE) --quiet install-pkgconfigDATA'

# Each tool's Info.plist, with the version from VERSION.
$(BUILD)/%/Info.plist: Sources/%/Info.plist VERSION
	mkdir -p $(dir $@)
	cp $< $@
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $@

# Both tools and the README, as published by .github/workflows/release.yml.
release: $(RELEASE)

$(RELEASE): $(TOOLS) README.md
	tar -czf $@ -C $(BIN) totalrecall transcribe -C $(CURDIR) README.md
	cd $(dir $@) && shasum -a 256 $(notdir $@) > $(notdir $@).sha256

# Unit and end-to-end tests, the latter against the release builds; run a subset with: make test TESTS=RecorderTests
# Tests that need the BlackHole test devices are skipped without them, except on CI.
test: $(TOOLS) $(SPEEXDSP)/lib/libspeexdsp.a
	$(STRICT) swift build $(SWIFTPM) --build-tests
	$(UNBUFFERED) swift test $(SWIFTPM) --skip-build $(if $(TESTS),--filter '$(TESTS)') </dev/null

# The tests again, on the build instrumented for coverage; fails below COVERAGE_MIN. Takes TESTS like make test.
coverage: coverage-build
	COVERAGE_MIN=$(COVERAGE_MIN) COVERAGE_REPORT=$(COVERAGE_REPORT) scripts/coverage.sh "$$($(MAKE) -s coverage-bin)" \
		$(UNBUFFERED) swift test --skip-build $(COVERAGE_FLAGS) $(if $(TESTS),--filter '$(TESTS)') </dev/null

coverage-build: $(SOURCES) $(BUILD)/TotalRecall/Info.plist $(SPEEXDSP)/lib/libspeexdsp.a
	$(STRICT) swift build --build-tests $(COVERAGE_FLAGS)

# Where coverage-build puts the tools, which CI grants the audio permissions to.
coverage-bin:
	@swift build $(COVERAGE_FLAGS) --show-bin-path

format:
	swift format --recursive --in-place Package.swift Sources Tests

lint:
	swift format lint --recursive --strict Package.swift Sources Tests

install: $(TOOLS)
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/$(BIN)/totalrecall $(PREFIX)/bin/totalrecall
	ln -sf $(CURDIR)/$(BIN)/transcribe $(PREFIX)/bin/transcribe

clean:
	rm -rf $(BUILD)

.PHONY: all totalrecall transcribe release test coverage coverage-build coverage-bin format lint install clean
