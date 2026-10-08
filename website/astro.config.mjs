// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// reqly.net: a home page and a privacy page of its own, and the docs, which Starlight builds
// from the Markdown in src/content/docs/docs.
export default defineConfig({
	site: 'https://reqly.net',
	integrations: [
		starlight({
			title: 'Reqly',
			description: 'See what your apps send and receive.',
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
