# Heimkehr — build, package and release helpers
#
# Quick usage:
#   make build           Debug-Build (Xcode DerivedData)
#   make build-release   Release-Build (ad-hoc signed)
#   make package         ZIP das .app-Bundle nach dist/
#   make bump-patch      1.0.0 -> 1.0.1
#   make bump-minor      1.0.0 -> 1.1.0
#   make bump-major      1.0.0 -> 2.0.0
#   make release         bump-patch, build-release, package, tag, GitHub-Release
#   make cask-update     aktualisiert ~/git/homebrew-tap/Casks/heimkehr.rb
#   make clean           räumt build/ und dist/ auf

SHELL := /bin/bash

# ---- Projekt-Konfiguration ----
PROJECT        := Heimkehr.xcodeproj
SCHEME         := Heimkehr
APP_NAME       := Heimkehr
PBXPROJ        := $(PROJECT)/project.pbxproj
BUILD_DIR      := build
DIST_DIR       := dist
CONFIG_RELEASE := Release
CONFIG_DEBUG   := Debug

# Homebrew-Tap
TAP_DIR        := $(HOME)/git/homebrew-tap
CASK_FILE      := $(TAP_DIR)/Casks/heimkehr.rb
GITHUB_OWNER   := posalex
GITHUB_REPO    := Heimkehr

# Aktuelle Version aus der ersten MARKETING_VERSION-Zeile im pbxproj lesen
VERSION := $(shell awk -F '= ' '/MARKETING_VERSION/ {gsub(/;/,"",$$2); print $$2; exit}' $(PBXPROJ))

APP_BUNDLE  := $(BUILD_DIR)/Build/Products/$(CONFIG_RELEASE)/$(APP_NAME).app
ZIP_NAME    := $(APP_NAME)-$(VERSION).zip
ZIP_PATH    := $(DIST_DIR)/$(ZIP_NAME)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Heimkehr – Targets (current version: $(VERSION))"
	@echo ""
	@echo "  build           Debug-Build"
	@echo "  build-release   Release-Build (ad-hoc signiert)"
	@echo "  package         ZIP in $(DIST_DIR)/"
	@echo "  bump-patch      Patch-Version erhöhen"
	@echo "  bump-minor      Minor-Version erhöhen"
	@echo "  bump-major      Major-Version erhöhen"
	@echo "  tag             git tag v$(VERSION)"
	@echo "  release         bump-patch + build-release + package + tag + gh release"
	@echo "  cask-update     aktualisiert Cask-Datei im lokalen Tap"
	@echo "  clean           build/ und dist/ löschen"
	@echo "  version         gibt die aktuelle Version aus"

.PHONY: version
version:
	@echo $(VERSION)

# ---- Builds ----

.PHONY: build
build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG_DEBUG) \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build

.PHONY: build-release
build-release:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG_RELEASE) \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build

# ---- Package ----

.PHONY: package
package: build-release
	@mkdir -p $(DIST_DIR)
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
		echo "Error: $(APP_BUNDLE) not found"; exit 1; \
	fi
	@rm -f $(ZIP_PATH)
	cd $(dir $(APP_BUNDLE)) && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app $(abspath $(ZIP_PATH))
	@shasum -a 256 $(ZIP_PATH)

# ---- Version bump ----
#
# Wir editieren MARKETING_VERSION (SemVer, sichtbar im Finder) und
# CURRENT_PROJECT_VERSION (ganze Zahl, Apple-Build-Nummer).

define BUMP_VERSION_PY
import re, sys, pathlib
part = sys.argv[1]
path = pathlib.Path(sys.argv[2])
txt = path.read_text()
m = re.search(r"MARKETING_VERSION = ([0-9]+)\.([0-9]+)\.([0-9]+);", txt)
if not m:
    sys.exit("MARKETING_VERSION nicht gefunden")
maj, mn, pt = map(int, m.groups())
if part == "major": maj, mn, pt = maj + 1, 0, 0
elif part == "minor": mn, pt = mn + 1, 0
elif part == "patch": pt = pt + 1
else: sys.exit("unknown bump part")
new = f"{maj}.{mn}.{pt}"
txt = re.sub(r"MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;", f"MARKETING_VERSION = {new};", txt)
# Build-Nummer hochzählen
cm = re.search(r"CURRENT_PROJECT_VERSION = ([0-9]+);", txt)
if cm:
    n = int(cm.group(1)) + 1
    txt = re.sub(r"CURRENT_PROJECT_VERSION = [0-9]+;", f"CURRENT_PROJECT_VERSION = {n};", txt)
path.write_text(txt)
print(new)
endef
export BUMP_VERSION_PY

.PHONY: bump-patch bump-minor bump-major
bump-patch:
	@new=$$(python3 -c "$$BUMP_VERSION_PY" patch $(PBXPROJ)); \
		echo "Version: $(VERSION) -> $$new"
bump-minor:
	@new=$$(python3 -c "$$BUMP_VERSION_PY" minor $(PBXPROJ)); \
		echo "Version: $(VERSION) -> $$new"
bump-major:
	@new=$$(python3 -c "$$BUMP_VERSION_PY" major $(PBXPROJ)); \
		echo "Version: $(VERSION) -> $$new"

# ---- Git tag ----

.PHONY: tag
tag:
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "Tag v$(VERSION) existiert bereits"; exit 1; \
	fi
	git add $(PBXPROJ)
	git diff --cached --quiet || git commit -m "chore: bump version to $(VERSION)"
	git tag -a "v$(VERSION)" -m "Heimkehr $(VERSION)"
	@echo "Tag v$(VERSION) erstellt. 'git push --follow-tags' um zu pushen."

# ---- Cask im lokalen Tap aktualisieren ----

.PHONY: cask-update
cask-update: package
	@if [ ! -f "$(CASK_FILE)" ]; then \
		echo "Cask-Datei $(CASK_FILE) nicht gefunden. Erwartet im Tap $(TAP_DIR)."; \
		exit 1; \
	fi
	@SHA=$$(shasum -a 256 $(ZIP_PATH) | awk '{print $$1}'); \
		sed -i '' "s|version \".*\"|version \"$(VERSION)\"|" $(CASK_FILE); \
		sed -i '' "s|sha256 \".*\"|sha256 \"$$SHA\"|" $(CASK_FILE); \
		echo "$(CASK_FILE) auf Version $(VERSION) aktualisiert (sha256=$$SHA)"

# ---- Voll-Release ----

.PHONY: release
release: bump-patch build-release package tag
	@echo ""
	@echo "Release $(shell $(MAKE) -s version) lokal gebaut:"
	@echo "  ZIP: $(DIST_DIR)/$(APP_NAME)-$(shell $(MAKE) -s version).zip"
	@echo ""
	@echo "Jetzt ausführen:"
	@echo "  git push --follow-tags"
	@echo "  gh release create v$(shell $(MAKE) -s version) $(DIST_DIR)/$(APP_NAME)-$(shell $(MAKE) -s version).zip \\"
	@echo "    --title 'Heimkehr $(shell $(MAKE) -s version)' --notes 'Release $(shell $(MAKE) -s version)'"
	@echo "  make cask-update"

# ---- Aufräumen ----

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
