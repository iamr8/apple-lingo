# SubOverlay build. `make app` assembles build/SubOverlay.app.

ADAPTER_REPO   := https://github.com/ungive/mediaremote-adapter
ADAPTER_COMMIT := e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6  # v0.7.7
ADAPTER_SRC    := Vendor/mediaremote-adapter
ADAPTER_OUT    := build/adapter
FRAMEWORK      := $(ADAPTER_OUT)/MediaRemoteAdapter.framework
TEST_CLIENT    := $(ADAPTER_OUT)/MediaRemoteAdapterTestClient
ARCH           := arm64
MIN_OS         := 15.0

APP      := build/SubOverlay.app
BIN      := .build/release/SubOverlay
# A real identity keeps macOS privacy grants across builds; ad hoc ("-") asks again each build.
SIGN_ID  ?= $(or $(shell security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $$2; exit}'),$(shell security find-identity -v -p codesigning | awk '/"Apple Development/ {print $$2; exit}'),-)

.PHONY: deps build app sign run test clean

deps: $(FRAMEWORK) $(TEST_CLIENT)

$(ADAPTER_SRC):
	git clone -q $(ADAPTER_REPO) $(ADAPTER_SRC)

$(FRAMEWORK): | $(ADAPTER_SRC)
	git -C $(ADAPTER_SRC) checkout -q $(ADAPTER_COMMIT)
	rm -rf $(FRAMEWORK)
	mkdir -p $(FRAMEWORK)/Versions/A/Resources
	clang -arch $(ARCH) -mmacosx-version-min=$(MIN_OS) -dynamiclib -fobjc-arc -fvisibility=default \
		-I$(ADAPTER_SRC)/include -I$(ADAPTER_SRC)/src \
		-install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
		-framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
		$(wildcard $(ADAPTER_SRC)/src/adapter/*.m) $(ADAPTER_SRC)/src/private/MediaRemote.m \
		$(wildcard $(ADAPTER_SRC)/src/utility/*.m) \
		-o $(FRAMEWORK)/Versions/A/MediaRemoteAdapter
	cp Resources/AdapterFramework-Info.plist $(FRAMEWORK)/Versions/A/Resources/Info.plist
	ln -sfh A $(FRAMEWORK)/Versions/Current
	ln -sfh Versions/Current/MediaRemoteAdapter $(FRAMEWORK)/MediaRemoteAdapter
	ln -sfh Versions/Current/Resources $(FRAMEWORK)/Resources

$(TEST_CLIENT): | $(ADAPTER_SRC)
	mkdir -p $(ADAPTER_OUT)
	clang -arch $(ARCH) -mmacosx-version-min=$(MIN_OS) -fobjc-arc -I$(ADAPTER_SRC)/src/test \
		-framework Foundation -framework MediaPlayer \
		$(ADAPTER_SRC)/src/test/main.m $(ADAPTER_SRC)/src/test/NowPlayingTest.m \
		-o $(TEST_CLIENT)

build:
	swift build -c release

test:
	swift test

app: deps build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Frameworks $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/SubOverlay
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp -R .build/release/KeyboardShortcuts_KeyboardShortcuts.bundle $(APP)/Contents/Resources/
	cp -R $(FRAMEWORK) $(APP)/Contents/Frameworks/
	cp $(TEST_CLIENT) $(APP)/Contents/Helpers/
	cp $(ADAPTER_SRC)/bin/mediaremote-adapter.pl $(APP)/Contents/Resources/
	cp LICENSE.md THIRD_PARTY_NOTICES.md $(APP)/Contents/Resources/
	$(MAKE) sign

sign:
	codesign --force --sign $(SIGN_ID) --options runtime $(APP)/Contents/Frameworks/MediaRemoteAdapter.framework
	codesign --force --sign $(SIGN_ID) --options runtime $(APP)/Contents/Helpers/MediaRemoteAdapterTestClient
	codesign --force --sign $(SIGN_ID) --options runtime $(APP)
	codesign --verify --deep --strict $(APP)

run: app
	open $(APP)

clean:
	rm -rf build .build
