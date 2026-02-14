# Release Checklist for cctop v0.3.0

## One-Time Setup (before first release)

### 1. Create the Homebrew tap repo

Go to https://github.com/new and create `homebrew-cctop` (public repo).

```bash
# Initialize with the Casks directory
git clone git@github.com:st0012/homebrew-cctop.git /tmp/homebrew-cctop
cd /tmp/homebrew-cctop
mkdir Casks
echo "# homebrew-cctop" > README.md
echo "Homebrew tap for [cctop](https://github.com/st0012/cctop)." >> README.md
echo "" >> README.md
echo '```bash' >> README.md
echo "brew tap st0012/cctop" >> README.md
echo "brew install --cask cctop" >> README.md
echo '```' >> README.md
git add . && git commit -m "Initial tap setup" && git push
```

### 2. Create a GitHub Personal Access Token

1. Go to https://github.com/settings/tokens?type=beta (fine-grained tokens)
2. Create a new token:
   - Name: `cctop-tap-updater`
   - Repository access: Only select repositories > `st0012/homebrew-cctop`
   - Permissions: Contents (Read and write)
3. Copy the token

### 3. Add the token as a repo secret

1. Go to https://github.com/st0012/cctop/settings/secrets/actions
2. Click "New repository secret"
3. Name: `TAP_GITHUB_TOKEN`
4. Value: paste the token from step 2
5. Click "Add secret"

## Release Steps

### 1. Merge the branch

```bash
git checkout master
git merge <branch-name>
git push origin master
```

### 2. Tag and push

```bash
git tag v0.3.0
git push origin v0.3.0
```

### 3. Wait for CI

The tag push triggers `.github/workflows/release.yml` which will:
- Build arm64 and x86_64 zips
- Create a GitHub Release with both zips
- Auto-update the Homebrew tap with correct SHA256 hashes

Monitor at: https://github.com/st0012/cctop/actions

### 4. Verify the release

```bash
# Check the GitHub Release page
gh release view v0.3.0

# Test Homebrew install (after CI completes)
brew tap st0012/cctop
brew install --cask cctop

# Verify the app launches
open /Applications/cctop.app

# Verify the hook binary is in the app bundle
ls -la /Applications/cctop.app/Contents/MacOS/cctop-hook

# Verify opencode plugin version matches the release
grep '"version"' plugins/opencode/package.json
```

### 5. Test the opencode plugin install

```bash
# Install via curl (same as user-facing instructions)
mkdir -p ~/.config/opencode/plugins/cctop
curl -sL https://raw.githubusercontent.com/st0012/cctop/master/plugins/opencode/plugin.js \
  -o ~/.config/opencode/plugins/cctop/plugin.js

# Start an opencode session and verify a session file appears
ls ~/.cctop/sessions/

# Verify the session includes source: "opencode"
cat ~/.cctop/sessions/*.json | jq '.source'
```

### 6. If anything goes wrong

```bash
# Delete the tag and release to re-do
gh release delete v0.3.0 --yes
git tag -d v0.3.0
git push origin :refs/tags/v0.3.0

# Fix the issue, then re-tag
git tag v0.3.0
git push origin v0.3.0
```
