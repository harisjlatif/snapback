APP_NAME   := Snapback
BUNDLE_ID  := com.snapback.Snapback
BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
INSTALL_DIR:= $(HOME)/Applications
AGENT      := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
UID        := $(shell id -u)
VERSION    ?= 0.0.0
DIST       := $(BUILD)/$(APP_NAME)-$(VERSION)

SWIFTC := xcrun swiftc -swift-version 5 -O

.PHONY: build test dist install uninstall restart log clean

build: $(APP)

ICNS := $(BUILD)/AppIcon.icns

$(ICNS): Resources/make-icon.swift
	rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	xcrun swift Resources/make-icon.swift $(BUILD)/icon_1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(BUILD)/icon_1024.png --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s * 2)); \
		sips -z $$d $$d $(BUILD)/icon_1024.png --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD)/AppIcon.iconset -o $(ICNS)

$(APP): Sources/*.swift Resources/Info.plist $(ICNS)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" $(APP)/Contents/Info.plist
	$(SWIFTC) Sources/*.swift -o $(APP)/Contents/MacOS/$(APP_NAME)
	codesign --force --sign - --identifier $(BUNDLE_ID) \
		-r='designated => identifier "$(BUNDLE_ID)"' $(APP)

test:
	mkdir -p $(BUILD)
	$(SWIFTC) Sources/Layout.swift Sources/HyperKey.swift Tests/main.swift -o $(BUILD)/tests
	$(BUILD)/tests

# Release zip: Snapback-<version>/{Snapback.app, install.sh}
dist: build
	rm -rf $(DIST) $(DIST).zip
	mkdir -p $(DIST)
	cp -R $(APP) $(DIST)/
	cp scripts/install.sh $(DIST)/
	cd $(BUILD) && ditto -c -k --norsrc --noextattr --noacl --keepParent $(APP_NAME)-$(VERSION) $(APP_NAME)-$(VERSION).zip

install: build
	scripts/install.sh $(APP)

uninstall:
	-launchctl bootout gui/$(UID)/$(BUNDLE_ID)
	-hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
	rm -f $(AGENT)
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app

restart:
	launchctl kickstart -k gui/$(UID)/$(BUNDLE_ID)

log:
	tail -f $(HOME)/Library/Logs/$(APP_NAME).log

clean:
	rm -rf $(BUILD)
