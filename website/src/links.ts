// Where the site links to. The download link works once each release carries a Reqly.zip,
// which the release workflow adds, and stays the same from one version to the next.
const repo = 'https://github.com/parsamlm/reqly';

export const links = {
	github: repo,
	download: `${repo}/releases/latest/download/Reqly.zip`,
	// Windows releases are never the latest release, which the Mac's updates read, so this names
	// the newest: change it with each Windows release.
	windows: `${repo}/releases/tag/windows-v1.0.0-beta.1`,
	releases: `${repo}/releases`,
	issues: `${repo}/issues`,
	roadmap: `${repo}/blob/main/ROADMAP.md`,
	trademarks: `${repo}/blob/main/TRADEMARKS.md`,
	license: `${repo}/blob/main/LICENSE`,
	homebrew: 'brew install --cask parsamlm/reqly/reqly',
	docs: '/docs/',
	privacy: '/privacy/',
};
