import { defineConfig } from 'vitepress'
import { family } from './theme/family'

// Shared look and family links (theme/family.ts is identical on the Current, Ripple and Anchor sites)
const shared = family('anchor', '/Anchor/')

const guideSidebar = [
  {
    text: 'Guide',
    items: [
      { text: 'Getting started', link: '/guide/getting-started' },
      { text: 'Studio test options', link: '/guide/studio-testing' },
      { text: 'Trades and anti-dupe', link: '/guide/trades' },
      { text: 'Save formats', link: '/guide/save-formats' },
      { text: 'Migrating from ProfileStore', link: '/guide/migrating' },
      { text: 'Security', link: '/guide/security' },
      { text: 'Using with Ripple', link: '/guide/ripple' },
    ],
  },
  {
    text: 'More',
    items: [
      { text: 'API reference', link: '/reference/api' },
      { text: 'Benchmarks', link: '/benchmarks' },
      { text: 'Design spec', link: '/design/spec' },
    ],
  },
]

export default defineConfig({
  ...shared.config,

  lang: 'en-US',
  title: 'Anchor',
  description: 'Session-locked DataStore saving for Roblox: a drop-in upgrade of ProfileStore with dupe-proof trades and smaller saves.',

  themeConfig: {
    ...shared.themeConfig,

    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '^/guide/' },
      { text: 'Reference', link: '/reference/api', activeMatch: '^/reference/' },
      { text: 'Benchmarks', link: '/benchmarks' },
      shared.nav,
      {
        text: 'v0 (in development)',
        items: [
          { text: 'Releases', link: 'https://github.com/Acidgorgon/anchor/releases' },
          { text: 'Design spec', link: '/design/spec' },
          { text: 'Raw benchmark results', link: 'https://github.com/Acidgorgon/anchor/blob/main/bench/RESULTS.md' },
        ],
      },
    ],

    sidebar: {
      '/guide/': guideSidebar,
      '/benchmarks': guideSidebar,
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'API reference', link: '/reference/api' },
            { text: 'Design spec', link: '/design/spec' },
          ],
        },
        { text: 'Guide', items: [{ text: 'Getting started →', link: '/guide/getting-started' }] },
      ],
      '/design/': [
        {
          text: 'Design',
          items: [
            { text: 'Design spec', link: '/design/spec' },
            { text: 'API reference', link: '/reference/api' },
          ],
        },
        { text: 'Guide', items: [{ text: 'Getting started →', link: '/guide/getting-started' }] },
      ],
    },

    socialLinks: [{ icon: 'github', link: 'https://github.com/Acidgorgon/anchor' }],

    editLink: {
      pattern: 'https://github.com/Acidgorgon/anchor/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
  },
})
