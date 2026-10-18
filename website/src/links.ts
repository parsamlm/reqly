// Where the site links to. The Mac's download is the latest release's Reqly.zip, which the release
// workflow adds to every Mac release, so the link stays the same from one version to the next.
const repo = 'https://github.com/parsamlm/reqly';

// Windows releases are never the latest release, which the Mac's updates read, so the site names
// the newest. Change it with each Windows release: both Windows links below follow it.
const windowsTag = 'windows-v1.0.0-beta.1';

export const links = {
	github: repo,
	mac: `${repo}/releases/latest/download/Reqly.zip`,
	// The newest Windows release's installer, and its release page, for its notes.
	windowsSetup: `${repo}/releases/download/${windowsTag}/Reqly.App-win-Setup.exe`,
	windows: `${repo}/releases/tag/${windowsTag}`,
	releases: `${repo}/releases`,
	issues: `${repo}/issues`,
	roadmap: `${repo}/blob/main/ROADMAP.md`,
	trademarks: `${repo}/blob/main/TRADEMARKS.md`,
	license: `${repo}/blob/main/LICENSE`,
	homebrew: 'brew install --cask parsamlm/reqly/reqly',
	docs: '/docs/',
	privacy: '/privacy/',
};
