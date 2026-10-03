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
# Sparkle tools; build.sh extracts them with the framework.
SPARKLE_BIN ?= .sparkle/bin
RELEASE_URL := https://github.com/zl190/hijack/releases/download/v$(VERSION)/
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
# Order: run the tests, check that HEAD is the tag, check the draft tag, check the signing identity and the Sparkle public key,
# build, zip, write and sign the appcast, upload the assets, publish the release, bump the cask.
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
	@grep -q '^REPLACE-' assets/sparkle-public-key.txt && { \
		echo "assets/sparkle-public-key.txt is the placeholder. Run generate_keys and paste the public key."; exit 1; \
	} || true
	HIJACK_SIGN_ID="$(RELEASE_SIGN_ID)" ./build.sh
	ditto -c -k --keepParent $(APP) $(ZIP)
	# Sparkle: one archive per version in dist/ (older zips stay there, out of git). The appcast keeps one item,
	# the new release: older items would get this release's download URL, where their zips do not exist. generate_appcast reads
	# the .md next to the zip as release notes (embedded as Markdown; a link would point at a file that is never uploaded),
	# signs the archive with the EdDSA key from the keychain,
	# and writes dist/appcast.xml. The release asset keeps the name Hijack.zip (the cask URL), so the
	# enclosure URL is rewritten from Hijack-$(VERSION).zip to Hijack.zip.
	mkdir -p dist
	cp $(ZIP) dist/Hijack-$(VERSION).zip
	cp release-notes/v$(VERSION).md dist/Hijack-$(VERSION).md
	$(SPARKLE_BIN)/generate_appcast --embed-release-notes --maximum-versions 1 --download-url-prefix "$(RELEASE_URL)" dist
	@grep -q 'sparkle:edSignature=' dist/appcast.xml || { \
		echo "dist/appcast.xml has no EdDSA signature. Is the Sparkle key in the keychain?"; exit 1; \
	}
	sed -i '' 's|/Hijack-$(VERSION)\.zip"|/Hijack.zip"|' dist/appcast.xml
	gh release upload "v$(VERSION)" $(ZIP) dist/appcast.xml --clobber
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
