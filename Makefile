# Hijack maintainer tasks. Run `make <target>`. See docs/distribution-spec.md for the full spec.
.PHONY: build test install release diagrams clean

# SIGN_ID: the codesign identity. Empty means ad-hoc; build.sh signs ad-hoc when the identity is empty.
# build and install use SIGN_ID as given (empty by default, so a dev build stays ad-hoc).
# release uses RELEASE_SIGN_ID: SIGN_ID if set, else "Hijack Signing".
SIGN_ID ?=
RELEASE_SIGN_ID = $(if $(strip $(SIGN_ID)),$(SIGN_ID),Hijack Signing)

VERSION := $(shell cat VERSION)
APP     := build/Hijack.app
ZIP     := build/Hijack.zip
# TAP_DIR: path to the zl190/homebrew-tap checkout. Override for a different layout.
TAP_DIR ?= ../homebrew-tap

# Build build/Hijack.app. Ad-hoc unless SIGN_ID names a keychain identity.
build:
	HIJACK_SIGN_ID="$(SIGN_ID)" ./build.sh

# Run the HijackCore unit tests.
test:
	swift test

# Build, then install to /Applications and link the hijack command.
install: build
	pkill -x Hijack 2>/dev/null || true
	rm -rf /Applications/Hijack.app
	cp -R $(APP) /Applications/
	for try in 1 2 3; do open /Applications/Hijack.app && break; sleep 2; done
	if [ -d "$$HOME/.local/bin" ] && echo ":$$PATH:" | grep -q ":$$HOME/.local/bin:"; then \
		ln -sf /Applications/Hijack.app/Contents/MacOS/Hijack "$$HOME/.local/bin/hijack"; \
		echo "Linked the hijack command into ~/.local/bin"; \
	else \
		echo "For the hijack command: ln -s /Applications/Hijack.app/Contents/MacOS/Hijack <a directory on your PATH>/hijack"; \
	fi
	echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."

# Publish the GitHub release and bump the Homebrew cask. Run on the maintainer's Mac only.
# Order: run the tests, check that HEAD is the tag, check the draft tag, check the signing identity, build, zip, sign for Sparkle,
# write the appcast, upload the assets, publish the release, bump the cask.
release: test
	@git describe --tags --exact-match HEAD 2>/dev/null | grep -qx "v$(VERSION)" || { \
		echo "HEAD is not tagged v$(VERSION). Check out the tag before you release."; exit 1; \
	}
	@draft_tag="$$(gh release list --limit 20 --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName' | head -1)"; \
	if [ -z "$$draft_tag" ]; then \
		echo "No draft release found. VERSION is $(VERSION). Create a draft first: gh release create v$(VERSION) --draft"; \
		exit 1; \
	fi; \
	if [ "$$draft_tag" != "v$(VERSION)" ]; then \
		echo "VERSION is $(VERSION). The newest draft release tag is $$draft_tag. They must match."; \
		exit 1; \
	fi
	@gh release view "v$(VERSION)" --json isDraft -q '.isDraft' | grep -q true || { \
		echo "v$(VERSION) is not a draft release."; exit 1; \
	}
	@security find-certificate -c "$(RELEASE_SIGN_ID)" >/dev/null 2>&1 || { \
		echo "Signing identity '$(RELEASE_SIGN_ID)' is not in the keychain."; exit 1; \
	}
	HIJACK_SIGN_ID="$(RELEASE_SIGN_ID)" ./build.sh
	ditto -c -k --keepParent $(APP) $(ZIP)
	# T3: sign_update
	# T3: generate_appcast + upload appcast.xml
	gh release upload "v$(VERSION)" $(ZIP) --clobber
	gh release edit "v$(VERSION)" --draft=false
	@sha="$$(shasum -a 256 $(ZIP) | awk '{print $$1}')"; \
	sed -i '' -e "s/version \"[^\"]*\"/version \"$(VERSION)\"/" \
		-e "s/sha256 \"[^\"]*\"/sha256 \"$$sha\"/" "$(TAP_DIR)/Casks/hijack.rb"; \
	if command -v brew >/dev/null 2>&1; then \
		brew audit --cask --strict --online zl190/tap/hijack || exit 1; \
	fi; \
	cd "$(TAP_DIR)" && git add Casks/hijack.rb && \
	(git diff --cached --quiet || git commit -m "hijack $(VERSION)") && git push

# Regenerate the diagrams in docs/diagrams from the code and the tests.
diagrams:
	scripts/diagrams.sh

# Remove build output.
clean:
	rm -rf build dist
