// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// The docs' Mac and Windows tabs (<Tabs syncKey="os">) open on the visitor's system. While
// Starlight keeps no choice for them yet, this sets one from the system, before the tabs draw;
// choosing a tab changes it. It tells the systems apart as the head script in
// src/layouts/Site.astro does. Anyone else gets the Mac tab, which comes first.
const presetSystemTab = `(function () {
	try {
		var key = 'starlight-synced-tabs__os';
		if (localStorage.getItem(key)) return;
		var n = navigator;
		var ua = n.userAgent || '';
		var platform = (n.userAgentData && n.userAgentData.platform) || n.platform || '';
		if (/Xbox/.test(ua)) return;
		if (/^Win/i.test(platform) || (!platform && /Windows NT/.test(ua))) localStorage.setItem(key, 'Windows');
		else if ((/^Mac/i.test(platform) || (!platform && /Macintosh/.test(ua))) && !(n.maxTouchPoints > 1))
			localStorage.setItem(key, 'Mac');
	} catch (e) {}
})();`;

// Without scripts, Starlight shows only each tab set's first panel, and a tab is a link to its
// panel. This shows the panel a tab points to, so the Windows steps can still be read.
const noScriptTabs = `<style>starlight-tabs > [role='tabpanel']:target { display: block; } starlight-tabs:has(> [role='tabpanel']:target) > [role='tabpanel']:not(:target) { display: none; }</style>`;

// reqly.net: a home page and a privacy page of its own, and the docs, which Starlight builds
// from the Markdown in src/content/docs/docs.
export default defineConfig({
	site: 'https://reqly.net',
	integrations: [
		starlight({
			title: 'Reqly',
			description: 'See what your apps send and receive, on the Mac and on Windows.',
			head: [
				{ tag: 'script', content: presetSystemTab },
				{ tag: 'noscript', content: noScriptTabs },
			],
			logo: {
				light: './src/assets/lockup-on-light.svg',
				dark: './src/assets/lockup-on-dark.svg',
				alt: 'Reqly',
				replacesTitle: true,
			},
			favicon: '/favicon.svg',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/parsamlm/reqly' }],
			customCss: ['./src/styles/brand.css', './src/styles/docs.css'],
			credits: false,
			sidebar: [
				'docs',
				{
					label: 'Getting started',
					items: ['docs/install', 'docs/first-capture', 'docs/https'],
				},
				{
					label: 'Using Reqly',
					items: [
						'docs/requests',
						'docs/phones',
						'docs/simulators',
						'docs/rules',
						'docs/scripts',
						'docs/sending',
						'docs/protocols',
						'docs/connections',
						'docs/sessions',
						'docs/settings',
					],
				},
				{
					label: 'Help',
					items: ['docs/troubleshooting', 'docs/shortcuts', 'docs/uninstall'],
				},
			],
		}),
	],
});
