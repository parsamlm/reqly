// Where the site links to. The download link works once each release carries a Reqly.zip,
// which the release workflow adds, and stays the same from one version to the next.
const repo = 'https://github.com/parsamlm/reqly';

export const links = {
	github: repo,
	download: `${repo}/releases/latest/download/Reqly.zip`,
	releases: `${repo}/releases`,
	issues: `${repo}/issues`,
	roadmap: `${repo}/blob/main/ROADMAP.md`,
	trademarks: `${repo}/blob/main/TRADEMARKS.md`,
	license: `${repo}/blob/main/LICENSE`,
	homebrew: 'brew install --cask parsamlm/reqly/reqly',
	docs: '/docs/',
	privacy: '/privacy/',
};
