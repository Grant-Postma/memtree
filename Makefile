# memtree: a live treemap of what your Mac is doing.
#
#   make run        build and run from the terminal
#   make install    memtree.app into ~/Applications, plus ~/.local/bin/memtree
#   make uninstall  remove exactly what install put there

APPS ?= $(HOME)/Applications
BINDIR ?= $(HOME)/.local/bin
BUNDLE = .build/bundle/memtree.app
VERSION = 0.1.0
# Named like disktree's downloads: aarch64 for Apple Silicon.
ARCH := $(subst arm64,aarch64,$(shell uname -m))
ZIP = .build/bundle/memtree-$(VERSION)-$(ARCH)-macos.zip

.PHONY: help build run test bundle zip install uninstall record clean

help:
	@echo "memtree"
	@echo
	@echo "  make build       release build"
	@echo "  make run         build and run"
	@echo "  make test        layout tests"
	@echo "  make bundle      build $(BUNDLE)"
	@echo "  make zip         the release zip and its .sha256"
	@echo "  make record      assets/memtree.mp4, .gif and screenshot.png"
	@echo "  make install     install to $(APPS) and link $(BINDIR)/memtree"
	@echo "  make uninstall   remove what install put there"

build:
	swift build -c release

run: build
	.build/release/memtree

test:
	swift test

# Rebuilt whole rather than copied over: a stale file inside a signed bundle
# breaks its signature.
bundle: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	cp .build/release/memtree "$(BUNDLE)/Contents/MacOS/memtree"
	sed -e 's|@VERSION@|$(VERSION)|' packaging/Info.plist.in > "$(BUNDLE)/Contents/Info.plist"
	plutil -lint "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign - "$(BUNDLE)"
	codesign --verify --strict "$(BUNDLE)"

# ditto zips the way Finder does, keeping the signature's extended attributes.
zip: bundle
	rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "$(ZIP)"
	cd "$(dir $(ZIP))" && shasum -a 256 "$(notdir $(ZIP))" > "$(notdir $(ZIP)).sha256"
	@echo "$(ZIP)"

install: bundle
	install -d "$(APPS)" "$(BINDIR)"
	rm -rf "$(APPS)/memtree.app"
	ditto "$(BUNDLE)" "$(APPS)/memtree.app"
	ln -sf "$(APPS)/memtree.app/Contents/MacOS/memtree" "$(BINDIR)/memtree"
	@echo
	@echo "installed:"
	@echo "  $(APPS)/memtree.app"
	@echo "  $(BINDIR)/memtree -> the app's binary"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) \
	    echo; echo "note: $(BINDIR) is not on PATH in this shell";; esac

uninstall:
	rm -rf "$(APPS)/memtree.app"
	@if [ -L "$(BINDIR)/memtree" ]; then rm -f "$(BINDIR)/memtree"; fi
	@echo "removed"

# The README clip: 17 seconds of this machine, with scripts/demo-ramp.py
# giving the map 2 GB to make room for.
record: build
	/usr/bin/python3 scripts/demo-ramp.py & \
	.build/release/memtree --record assets/memtree.mp4 --gif assets/memtree.gif \
	    --png assets/screenshot.png --seconds 17; wait

clean:
	rm -rf .build
